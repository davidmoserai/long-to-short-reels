import Foundation

/// Recovers exact word-level start/end timestamps for Claude-proposed candidates.
///
/// The model never sets timing directly -- it proposes verbatim quote anchors
/// and we search the known transcript for the best-matching word sequence.
/// This is deterministic and never trusts the model for numbers.
public enum TimestampResolver {
    public static let maxClipSeconds: TimeInterval = Windower.maxClipSeconds
    private static let searchWindowWords = 1200  // generous cap on how far quoteEnd can be from quoteStart

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }

    private static func tokenize(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Similarity ratio between two equal-length token windows, analogous to
    /// difflib's SequenceMatcher.ratio() via a longest-common-subsequence approximation.
    private static func ratio(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        let lcs = dp[a.count][b.count]
        return Double(2 * lcs) / Double(a.count + b.count)
    }

    private static func findBestMatch(
        query: [String], in wordTokens: [String], from searchFrom: Int, to searchTo: Int
    ) -> (index: Int?, ratio: Double) {
        guard !query.isEmpty else { return (nil, 0) }
        let n = query.count
        let upperBound = min(searchTo, wordTokens.count)
        guard searchFrom < upperBound else { return (nil, 0) }

        var bestIdx: Int?
        var bestRatio = 0.0

        var i = searchFrom
        while i <= upperBound - n {
            let window = Array(wordTokens[i..<(i + n)])
            let r = ratio(query, window)
            if r > bestRatio {
                bestRatio = r
                bestIdx = i
            }
            if r > 0.995 { break }
            i += 1
        }

        return (bestIdx, bestRatio)
    }

    public static func resolve(
        _ candidates: [RawCandidate], transcript: Transcript
    ) -> [ResolvedCandidate] {
        let words = transcript.words
        let wordTokens = words.map { normalize($0.text) }

        var resolved: [ResolvedCandidate] = []

        for candidate in candidates {
            let startQuery = tokenize(candidate.quoteStart)
            let endQuery = tokenize(candidate.quoteEnd)

            let (startIdx, startRatio) = findBestMatch(
                query: startQuery, in: wordTokens, from: 0, to: wordTokens.count)
            guard let startIdx else { continue }

            let (endIdx, endRatio) = findBestMatch(
                query: endQuery, in: wordTokens, from: startIdx, to: startIdx + searchWindowWords)
            guard let endIdx else { continue }

            let endWordIdx = min(endIdx + endQuery.count - 1, words.count - 1)
            let startTime = words[startIdx].start
            let endTime = words[endWordIdx].end
            let confidence = min(startRatio, endRatio)

            // Reject weak matches outright -- better to drop a candidate than cut the wrong clip.
            guard confidence > 0.7 else { continue }

            resolved.append(
                ResolvedCandidate(
                    raw: candidate,
                    startWordIdx: startIdx,
                    endWordIdx: endWordIdx,
                    start: startTime,
                    end: endTime,
                    matchConfidence: confidence
                )
            )
        }

        return resolved
    }
}
