import Foundation
import FluidAudio

@main
struct TranscribeCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: transcribe <input-media-file> <output.json>")
            exit(1)
        }
        let inputPath = args[1]
        let outputPath = args[2]

        do {
            let audioURL = try extractAudioIfNeeded(from: inputPath)

            print("Loading ASR models (Parakeet TDT v2, English)...")
            let asrModels = try await AsrModels.downloadAndLoad(version: .v2)
            let asrManager = AsrManager(config: .default)
            try await asrManager.loadModels(asrModels)

            print("Transcribing \(inputPath)...")
            var decoderState = try TdtDecoderState()
            let asrResult = try await asrManager.transcribe(audioURL, decoderState: &decoderState)
            print("Transcription done in \(String(format: "%.1f", asrResult.processingTime))s (RTFx: \(String(format: "%.0f", asrResult.rtfx)))")

            print("Loading diarization models...")
            let diarizerModels = try await DiarizerModels.downloadIfNeeded()
            let diarizer = DiarizerManager()
            diarizer.initialize(models: diarizerModels)

            print("Resampling audio for diarization...")
            let samples = try AudioConverter().resampleAudioFile(audioURL)

            print("Diarizing speakers...")
            let diarResult = try diarizer.performCompleteDiarization(samples)
            let speakerIds = Set(diarResult.segments.map(\.speakerId)).sorted()
            print("Found \(speakerIds.count) speaker(s): \(speakerIds.joined(separator: ", "))")

            let wordTimings = mergeTokensIntoWords(asrResult.tokenTimings ?? [])
            let words = wordTimings.map { w -> TranscriptWord in
                let midpoint = (w.startTime + w.endTime) / 2
                return TranscriptWord(
                    text: w.word,
                    start: w.startTime,
                    end: w.endTime,
                    confidence: w.confidence,
                    speaker: speaker(at: midpoint, in: diarResult.segments)
                )
            }

            let output = Transcript(
                sourceFile: inputPath,
                durationSeconds: asrResult.duration,
                fullText: asrResult.text,
                speakerCount: speakerIds.count,
                speakers: speakerIds,
                words: words
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(output)
            try data.write(to: URL(fileURLWithPath: outputPath))
            print("Wrote transcript to \(outputPath)")

        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    /// Extracts a 16kHz mono WAV from any media file via ffmpeg, unless the input is already a WAV.
    static func extractAudioIfNeeded(from inputPath: String) throws -> URL {
        let inputURL = URL(fileURLWithPath: inputPath)
        if inputURL.pathExtension.lowercased() == "wav" {
            return inputURL
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        print("Extracting audio to \(tempURL.path)...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-y", "-i", inputPath,
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
            tempURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "transcribe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed with status \(process.terminationStatus)"])
        }
        return tempURL
    }

    /// Finds the speaker whose segment covers `time`, falling back to the nearest segment.
    static func speaker(at time: TimeInterval, in segments: [TimedSpeakerSegment]) -> String {
        let t = Float(time)
        if let match = segments.first(where: { t >= $0.startTimeSeconds && t <= $0.endTimeSeconds }) {
            return match.speakerId
        }
        var best: TimedSpeakerSegment?
        var bestDistance = Float.greatestFiniteMagnitude
        for segment in segments {
            let distance = min(abs(segment.startTimeSeconds - t), abs(segment.endTimeSeconds - t))
            if distance < bestDistance {
                bestDistance = distance
                best = segment
            }
        }
        return best?.speakerId ?? "unknown"
    }

    /// Merges token-level timings into word-level timings by detecting whitespace token boundaries.
    static func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [WordTiming] {
        guard !tokenTimings.isEmpty else { return [] }

        var wordTimings: [WordTiming] = []
        var currentWord = ""
        var currentStartTime: TimeInterval?
        var currentEndTime: TimeInterval = 0
        var currentConfidences: [Float] = []

        for timing in tokenTimings {
            let token = timing.token
            if token.hasPrefix(" ") || token.hasPrefix("\n") || token.hasPrefix("\t") {
                if !currentWord.isEmpty, let startTime = currentStartTime {
                    wordTimings.append(
                        WordTiming(
                            word: currentWord, startTime: startTime, endTime: currentEndTime,
                            confidence: averageConfidence(currentConfidences)))
                }
                currentWord = token.trimmingCharacters(in: .whitespacesAndNewlines)
                currentStartTime = timing.startTime
                currentEndTime = timing.endTime
                currentConfidences = [timing.confidence]
            } else {
                if currentStartTime == nil {
                    currentStartTime = timing.startTime
                }
                currentWord += token
                currentEndTime = timing.endTime
                currentConfidences.append(timing.confidence)
            }
        }

        if !currentWord.isEmpty, let startTime = currentStartTime {
            wordTimings.append(
                WordTiming(
                    word: currentWord, startTime: startTime, endTime: currentEndTime,
                    confidence: averageConfidence(currentConfidences)))
        }

        return wordTimings
    }

    static func averageConfidence(_ confidences: [Float]) -> Float {
        confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Float(confidences.count)
    }
}

struct WordTiming {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}

struct TranscriptWord: Codable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
    let speaker: String
}

struct Transcript: Codable {
    let sourceFile: String
    let durationSeconds: TimeInterval
    let fullText: String
    let speakerCount: Int
    let speakers: [String]
    let words: [TranscriptWord]
}
