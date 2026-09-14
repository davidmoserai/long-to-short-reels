import Foundation
import XCTest
@testable import LongToShortCore

final class PipelineCheckpointTests: XCTestCase {
    func testCheckpointPersistsProgressAndInvalidatesChangedSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = directory.appendingPathComponent("source.mp4")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: source)

        let transcript = Transcript(
            sourceFile: source.path,
            durationSeconds: 10,
            fullText: "A transcript",
            speakerCount: 1,
            speakers: ["speaker_0"],
            words: []
        )
        let checkpoint = try PipelineCheckpointStore.create(transcript: transcript, source: source)
        let writer = PipelineCheckpointWriter(checkpoint: checkpoint, source: source)
        _ = writer.cachedScores(for: "test-model")
        writer.recordScores([
            RawCandidate(
                quoteStart: "A", quoteEnd: "transcript", momentType: .insight,
                score: 80, reasoning: "Useful point"
            )
        ], for: 0)

        let loaded = try XCTUnwrap(PipelineCheckpointStore.load(for: source))
        XCTAssertEqual(loaded.scoredWindows[0]?.count, 1)
        XCTAssertEqual(loaded.scorerModel, "test-model")

        try Data([0, 1]).write(to: source)
        XCTAssertNil(PipelineCheckpointStore.load(for: source))
    }
}
