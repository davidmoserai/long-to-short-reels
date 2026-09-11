import Foundation
import LongToShortCore

// Dev/validation tool: runs the Claude scoring engine against an already-transcribed
// JSON transcript and prints the resulting highlights, so the scoring pipeline can be
// checked against a known-good manual baseline before it's wired into the app.
//
// Usage: ANTHROPIC_API_KEY=sk-... swift run score-test <transcript.json>

@main
struct ScoreTest {
    static func main() async {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
            print("Set ANTHROPIC_API_KEY in your environment first.")
            exit(1)
        }
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: ANTHROPIC_API_KEY=sk-... swift run score-test <transcript.json>")
            exit(1)
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            let transcript = try JSONDecoder().decode(Transcript.self, from: data)

            let windows = Windower.buildWindows(for: transcript)
            print("Built \(windows.count) windows. Scoring with Claude Sonnet 5 (this calls the real API)...")

            let start = Date()
            let rawCandidates = try await ClaudeScorer.scoreAllWindows(windows, apiKey: apiKey) { completed, total in
                print("  scored \(completed)/\(total) windows")
            }
            let elapsed = Date().timeIntervalSince(start)
            print("Got \(rawCandidates.count) raw candidates in \(String(format: "%.1f", elapsed))s")

            let resolved = TimestampResolver.resolve(rawCandidates, transcript: transcript)
            print("Resolved \(resolved.count)/\(rawCandidates.count) candidates to exact timestamps")

            let highlights = HighlightSelector.select(from: resolved, words: transcript.words)
            print("\nSelected \(highlights.count) highlights:\n")

            for h in highlights {
                print(
                    String(
                        format: "  %@ [%@] score=%d  %.2f-%.2f min (%.0fs)",
                        h.id, h.momentType.rawValue, h.score, h.start / 60, h.end / 60, h.durationSeconds))
                print("      \(h.reasoning)")
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
