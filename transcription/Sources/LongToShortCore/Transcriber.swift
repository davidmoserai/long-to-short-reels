import Foundation
import FluidAudio

/// Transcribes and diarizes a media file into a word-level `Transcript`.
///
/// Parakeet TDT v2 (English) for ASR, FluidAudio's offline DiarizerManager
/// for speaker labeling (no assumed speaker count).
public enum Transcriber {
    public struct TranscribeError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func transcribe(
        inputPath: String,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> Transcript {
        // FluidAudio's AudioConverter/AsrManager read via AVAudioFile, which on
        // macOS 26 decodes audio tracks directly out of video containers -- no
        // separate ffmpeg extraction step needed.
        let audioURL = URL(fileURLWithPath: inputPath)

        onStatus?("Loading ASR models (Parakeet TDT v2, English)...")
        let asrModels = try await AsrModels.downloadAndLoad(version: .v2)
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(asrModels)

        onStatus?("Transcribing...")
        var decoderState = try TdtDecoderState()
        let asrResult = try await asrManager.transcribe(audioURL, decoderState: &decoderState)

        onStatus?("Loading diarization models...")
        let diarizerModels = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager()
        diarizer.initialize(models: diarizerModels)

        onStatus?("Diarizing speakers...")
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        let diarResult = try diarizer.performCompleteDiarization(samples)
        let speakerIds = Set(diarResult.segments.map(\.speakerId)).sorted()

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

        return Transcript(
            sourceFile: inputPath,
            durationSeconds: asrResult.duration,
            fullText: asrResult.text,
            speakerCount: speakerIds.count,
            speakers: speakerIds,
            words: words
        )
    }

    private static func speaker(at time: TimeInterval, in segments: [TimedSpeakerSegment]) -> String {
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

    private static func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [WordTiming] {
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

    private static func averageConfidence(_ confidences: [Float]) -> Float {
        confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Float(confidences.count)
    }
}

private struct WordTiming {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}
