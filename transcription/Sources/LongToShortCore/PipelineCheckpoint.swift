import Foundation

struct PipelineCheckpoint: Codable {
    let sourceSize: Int64
    let sourceModifiedAt: Date
    let transcript: Transcript
    var scorerModel: String?
    var scoredWindows: [Int: [RawCandidate]]
    var highlights: [Highlight]?
}

enum PipelineCheckpointStore {
    private static let filename = ".long-to-short-checkpoint.json"

    static func load(for source: URL) -> PipelineCheckpoint? {
        let checkpointURL = checkpointURL(for: source)
        guard
            let data = try? Data(contentsOf: checkpointURL),
            let checkpoint = try? JSONDecoder().decode(PipelineCheckpoint.self, from: data),
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
            let size = attributes[.size] as? NSNumber,
            let modifiedAt = attributes[.modificationDate] as? Date,
            checkpoint.sourceSize == size.int64Value,
            abs(checkpoint.sourceModifiedAt.timeIntervalSince(modifiedAt)) < 0.001
        else {
            return nil
        }
        return checkpoint
    }

    static func create(transcript: Transcript, source: URL) throws -> PipelineCheckpoint {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard
            let size = attributes[.size] as? NSNumber,
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            throw NSError(
                domain: "PipelineCheckpointStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not read source video metadata"]
            )
        }
        return PipelineCheckpoint(
            sourceSize: size.int64Value,
            sourceModifiedAt: modifiedAt,
            transcript: transcript,
            scorerModel: nil,
            scoredWindows: [:],
            highlights: nil
        )
    }

    static func save(_ checkpoint: PipelineCheckpoint, for source: URL) throws {
        let checkpointURL = checkpointURL(for: source)
        try FileManager.default.createDirectory(
            at: checkpointURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
    }

    private static func checkpointURL(for source: URL) -> URL {
        ClipCutter.outputDirectory(for: source).appendingPathComponent(filename)
    }
}

final class PipelineCheckpointWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let source: URL
    private var checkpoint: PipelineCheckpoint

    init(checkpoint: PipelineCheckpoint, source: URL) {
        self.checkpoint = checkpoint
        self.source = source
    }

    func cachedScores(for model: String) -> [Int: [RawCandidate]] {
        lock.lock()
        defer { lock.unlock() }

        guard checkpoint.scorerModel == model else {
            checkpoint.scorerModel = model
            checkpoint.scoredWindows = [:]
            checkpoint.highlights = nil
            save()
            return [:]
        }
        return checkpoint.scoredWindows
    }

    func recordScores(_ candidates: [RawCandidate], for windowID: Int) {
        lock.lock()
        defer { lock.unlock() }
        checkpoint.scoredWindows[windowID] = candidates
        save()
    }

    func cachedHighlights(for model: String) -> [Highlight]? {
        lock.lock()
        defer { lock.unlock() }
        return checkpoint.scorerModel == model ? checkpoint.highlights : nil
    }

    func recordHighlights(_ highlights: [Highlight]) {
        lock.lock()
        defer { lock.unlock() }
        checkpoint.highlights = highlights
        save()
    }

    private func save() {
        try? PipelineCheckpointStore.save(checkpoint, for: source)
    }
}
