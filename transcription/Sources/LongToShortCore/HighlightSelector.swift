import Foundation

/// Finalizes highlight selection: enforces length bounds, dedupes overlaps,
/// ranks by score, and cuts at the natural elbow in the score distribution.
///
/// No hardcoded clip count. No hardcoded clip length beyond the platform
/// ceiling. The number of clips is whatever clears the bar.
public enum HighlightSelector {
    public static let minClipSeconds: TimeInterval = 20
    public static let maxClipSeconds: TimeInterval = Windower.maxClipSeconds
    private static let overlapMergeThreshold = 0.5  // fraction of the shorter clip that must overlap to count as duplicate

    public static func select(from resolved: [ResolvedCandidate], words: [TranscriptWord]) -> [Highlight] {
        let extended = resolved.map { extendToMinLength($0, words: words) }
        let bounded = extended.filter { $0.durationSeconds <= maxClipSeconds }

        let deduped = dedupe(bounded)
        let selected = elbowCutoff(deduped)

        return selected
            .sorted { $0.start < $1.start }
            .enumerated()
            .map { i, c in
                Highlight(
                    id: "c\(String(format: "%02d", i + 1))",
                    momentType: c.momentType,
                    score: c.score,
                    reasoning: c.raw.reasoning,
                    start: c.start,
                    end: c.end
                )
            }
    }

    /// If a clip is shorter than minClipSeconds, extend its end forward to the
    /// next sentence-ending punctuation, capped at maxClipSeconds.
    private static func extendToMinLength(_ candidate: ResolvedCandidate, words: [TranscriptWord]) -> ResolvedCandidate {
        guard candidate.durationSeconds < minClipSeconds else { return candidate }

        var endIdx = candidate.endWordIdx
        let startTime = candidate.start

        var i = endIdx + 1
        while i < words.count {
            let w = words[i]
            let duration = w.end - startTime
            if duration > maxClipSeconds { break }
            let endsSentence = w.text.reversed().first.map { ".?!".contains($0) } ?? false
            endIdx = i
            if endsSentence && duration >= minClipSeconds { break }
            i += 1
        }

        var updated = candidate
        updated.endWordIdx = endIdx
        updated.end = words[endIdx].end
        updated.extended = true
        return updated
    }

    private static func overlapFraction(_ a: ResolvedCandidate, _ b: ResolvedCandidate) -> Double {
        let latestStart = max(a.start, b.start)
        let earliestEnd = min(a.end, b.end)
        let overlap = max(0, earliestEnd - latestStart)
        let shorter = min(a.durationSeconds, b.durationSeconds)
        return shorter > 0 ? overlap / shorter : 0
    }

    /// Keeps the higher-scoring candidate whenever two overlap significantly.
    private static func dedupe(_ candidates: [ResolvedCandidate]) -> [ResolvedCandidate] {
        var kept: [ResolvedCandidate] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            if kept.contains(where: { overlapFraction(c, $0) > overlapMergeThreshold }) { continue }
            kept.append(c)
        }
        return kept
    }

    /// Sorts by score descending, keeps everything up to the biggest score gap.
    private static func elbowCutoff(_ candidates: [ResolvedCandidate]) -> [ResolvedCandidate] {
        let ranked = candidates.sorted { $0.score > $1.score }
        guard ranked.count > 1 else { return ranked }

        var biggestGap = -1
        var cutIdx = ranked.count - 1
        for i in 0..<(ranked.count - 1) {
            let gap = ranked[i].score - ranked[i + 1].score
            if gap > biggestGap {
                biggestGap = gap
                cutIdx = i
            }
        }

        return Array(ranked[0...cutIdx])
    }
}
