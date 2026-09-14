import Foundation
import AVFoundation

/// Cuts selected highlights out of the source video into standalone clip files.
///
/// Pure AVFoundation -- no bundled ffmpeg, no licensing question at all.
/// Hardware-accelerated H.264 encoding happens automatically under the hood
/// via VideoToolbox on Apple Silicon.
public enum ClipCutter {
    private static let padSeconds: TimeInterval = 0.3  // small breathing room so cuts don't feel abrupt

    public struct CutError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func cutClip(source: URL, start: TimeInterval, end: TimeInterval, output: URL) async throws {
        let startPadded = max(0, start - padSeconds)
        let duration = (end - start) + 2 * padSeconds

        let asset = AVURLAsset(url: source)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw CutError(description: "Could not create export session for \(source.lastPathComponent)")
        }

        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startPadded, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        let temporaryOutput = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mp4")

        do {
            try await exportSession.export(to: temporaryOutput, as: .mp4)
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.moveItem(at: temporaryOutput, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporaryOutput)
            throw CutError(description: "Export failed for \(output.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static func outputDirectory(for source: URL) -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent().appendingPathComponent("\(baseName)_clips")
    }

    /// Cuts every highlight, writing into a subfolder named after the source file.
    @discardableResult
    public static func cutAll(
        _ highlights: [Highlight], source: URL,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> URL {
        let outputDir = outputDirectory(for: source)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        for (i, h) in highlights.enumerated() {
            let filename = "\(String(format: "%02d", i + 1))_\(h.id)_\(h.momentType.rawValue)_score\(h.score).mp4"
            let outputPath = outputDir.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: outputPath.path) {
                try await cutClip(source: source, start: h.start, end: h.end, output: outputPath)
            }
            onProgress?(i + 1, highlights.count)
        }

        return outputDir
    }
}
