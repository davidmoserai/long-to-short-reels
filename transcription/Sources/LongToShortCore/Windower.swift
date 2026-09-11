import Foundation

/// Splits a word-level transcript into overlapping windows for highlight discovery.
///
/// Overlap is tied to `maxClipSeconds` so no candidate moment can straddle a
/// window boundary invisibly to both windows.
public enum Windower {
    public static let maxClipSeconds: TimeInterval = 180  // platform ceiling (YouTube Shorts hard cap)
    public static let overlapSeconds: TimeInterval = maxClipSeconds
    public static let windowSeconds: TimeInterval = 600  // 10 min
    public static let strideSeconds: TimeInterval = windowSeconds - overlapSeconds  // 7 min

    public static func buildWindows(for transcript: Transcript) -> [TranscriptWindow] {
        let words = transcript.words
        let duration = transcript.durationSeconds

        var windows: [TranscriptWindow] = []
        var windowStart: TimeInterval = 0
        var windowId = 0

        while windowStart < duration {
            let windowEnd = min(windowStart + windowSeconds, duration)

            let windowWords = words.enumerated().filter { _, w in
                w.start < windowEnd && w.end > windowStart
            }

            if !windowWords.isEmpty {
                let firstIdx = windowWords.first!.offset
                let lastIdx = windowWords.last!.offset
                let text = formatWindowText(windowWords.map(\.element))
                windows.append(
                    TranscriptWindow(
                        windowId: windowId,
                        startTime: windowStart,
                        endTime: windowEnd,
                        wordStartIdx: firstIdx,
                        wordEndIdx: lastIdx,
                        text: text
                    )
                )
                windowId += 1
            }

            if windowEnd >= duration { break }
            windowStart += strideSeconds
        }

        return windows
    }

    private static func formatWindowText(_ words: [TranscriptWord]) -> String {
        var lines: [String] = []
        var currentSpeaker: String?
        var currentLine: [String] = []

        for w in words {
            if w.speaker != currentSpeaker {
                if !currentLine.isEmpty {
                    lines.append("[Speaker \(currentSpeaker ?? "?")]: \(currentLine.joined(separator: " "))")
                }
                currentSpeaker = w.speaker
                currentLine = []
            }
            currentLine.append(w.text)
        }
        if !currentLine.isEmpty {
            lines.append("[Speaker \(currentSpeaker ?? "?")]: \(currentLine.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }
}
