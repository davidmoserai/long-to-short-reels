import Foundation

/// Orchestrates the full pipeline for one video: transcribe -> window ->
/// score (Claude) -> resolve timestamps -> select -> cut clips.
public enum PipelineRunner {
    public enum Stage: Sendable, Equatable {
        case transcribing(String)
        case scoring(completed: Int, total: Int)
        case selecting
        case cutting(completed: Int, total: Int)
        case done(clipCount: Int, outputDir: URL)
        case failed(String)
    }

    public struct Result: Sendable {
        public let transcript: Transcript
        public let highlights: [Highlight]
        public let outputDir: URL
    }

    public static func run(
        inputPath: String,
        apiKey: String,
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> Result {
        let sourceURL = URL(fileURLWithPath: inputPath)

        onStage(.transcribing("Starting..."))
        let transcript = try await Transcriber.transcribe(inputPath: inputPath) { status in
            onStage(.transcribing(status))
        }

        let windows = Windower.buildWindows(for: transcript)

        onStage(.scoring(completed: 0, total: windows.count))
        let rawCandidates = try await ClaudeScorer.scoreAllWindows(
            windows, apiKey: apiKey
        ) { completed, total in
            onStage(.scoring(completed: completed, total: total))
        }

        onStage(.selecting)
        let resolved = TimestampResolver.resolve(rawCandidates, transcript: transcript)
        let highlights = HighlightSelector.select(from: resolved, words: transcript.words)

        guard !highlights.isEmpty else {
            throw NSError(
                domain: "PipelineRunner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No highlight-worthy moments found in \(sourceURL.lastPathComponent)"])
        }

        onStage(.cutting(completed: 0, total: highlights.count))
        let outputDir = try await ClipCutter.cutAll(highlights, source: sourceURL) {
            completed, total in
            onStage(.cutting(completed: completed, total: total))
        }

        onStage(.done(clipCount: highlights.count, outputDir: outputDir))

        return Result(transcript: transcript, highlights: highlights, outputDir: outputDir)
    }
}
