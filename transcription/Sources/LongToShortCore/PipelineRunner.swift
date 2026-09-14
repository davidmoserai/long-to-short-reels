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

    public struct PreparedResult: Sendable {
        public let transcript: Transcript
        public let highlights: [Highlight]
        public let sourceURL: URL
    }

    public static func prepare(
        inputPath: String,
        apiKey: String,
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> PreparedResult {
        let sourceURL = URL(fileURLWithPath: inputPath)

        let checkpoint: PipelineCheckpoint
        let transcript: Transcript
        if let saved = PipelineCheckpointStore.load(for: sourceURL) {
            checkpoint = saved
            transcript = saved.transcript
            onStage(.transcribing("Using saved transcript and previous progress..."))
        } else {
            onStage(.transcribing("Starting..."))
            transcript = try await Transcriber.transcribe(inputPath: inputPath) { status in
                onStage(.transcribing(status))
            }
            checkpoint = try PipelineCheckpointStore.create(transcript: transcript, source: sourceURL)
            try PipelineCheckpointStore.save(checkpoint, for: sourceURL)
        }
        let checkpointWriter = PipelineCheckpointWriter(checkpoint: checkpoint, source: sourceURL)

        let windows = Windower.buildWindows(for: transcript)
        let cachedScores = checkpointWriter.cachedScores(for: ClaudeScorer.defaultModel)

        let rawCandidates: [RawCandidate]
        if windows.allSatisfy({ cachedScores[$0.windowId] != nil }) {
            onStage(.scoring(completed: windows.count, total: windows.count))
            rawCandidates = cachedScores.values.flatMap { $0 }
        } else {
            onStage(.scoring(completed: cachedScores.count, total: windows.count))
            rawCandidates = try await ClaudeScorer.scoreAllWindows(
                windows,
                apiKey: apiKey,
                cachedResults: cachedScores,
                onProgress: { completed, total in
                    onStage(.scoring(completed: completed, total: total))
                },
                onWindowScored: { windowID, candidates in
                    checkpointWriter.recordScores(candidates, for: windowID)
                }
            )
        }

        let highlights: [Highlight]
        if let savedHighlights = checkpointWriter.cachedHighlights(for: ClaudeScorer.defaultModel) {
            highlights = savedHighlights
            onStage(.selecting)
        } else {
            onStage(.selecting)
            let resolved = TimestampResolver.resolve(rawCandidates, transcript: transcript)
            highlights = HighlightSelector.select(from: resolved, words: transcript.words)
            checkpointWriter.recordHighlights(highlights)
        }

        guard !highlights.isEmpty else {
            throw NSError(
                domain: "PipelineRunner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No highlight-worthy moments found in \(sourceURL.lastPathComponent)"])
        }

        return PreparedResult(transcript: transcript, highlights: highlights, sourceURL: sourceURL)
    }

    public static func export(
        _ highlights: [Highlight],
        sourceURL: URL,
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> URL {
        onStage(.cutting(completed: 0, total: highlights.count))
        let outputDir = try await ClipCutter.cutAll(highlights, source: sourceURL) {
            completed, total in
            onStage(.cutting(completed: completed, total: total))
        }

        onStage(.done(clipCount: highlights.count, outputDir: outputDir))

        return outputDir
    }
}
