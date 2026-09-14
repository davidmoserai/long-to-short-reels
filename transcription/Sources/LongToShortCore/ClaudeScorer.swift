import Foundation

/// Scores transcript windows for highlight-worthy moments using the Claude API.
///
/// The model never sets timing -- it proposes candidates as verbatim quote
/// anchors (first/last few words of the moment). Exact timestamps are
/// recovered separately by `TimestampResolver` matching those quotes back
/// into the known word-level transcript. This keeps timing deterministic
/// and never trusts the model for numbers.
///
/// The rubric/instructions are sent as a cached system block so repeated
/// calls across a single episode's windows only pay full price once.
public enum ClaudeScorer {
    public static let defaultModel = "claude-sonnet-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"

    public struct ScoringError: LocalizedError, CustomStringConvertible {
        public let description: String

        public var errorDescription: String? { description }
    }

    private struct ScoredWindow: Sendable {
        let id: Int
        let candidates: [RawCandidate]
    }

    /// Score every window, with bounded concurrency. The cached system
    /// prompt is identical across all calls, so parallelism doesn't hurt
    /// the cache hit rate -- Anthropic caches by prefix hash, not by order.
    public static func scoreAllWindows(
        _ windows: [TranscriptWindow],
        apiKey: String,
        model: String = defaultModel,
        maxConcurrent: Int = 4,
        cachedResults: [Int: [RawCandidate]] = [:],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        onWindowScored: (@Sendable (Int, [RawCandidate]) -> Void)? = nil
    ) async throws -> [RawCandidate] {
        var results = cachedResults.values.flatMap { $0 }
        var completed = cachedResults.count
        let remainingWindows = windows.filter { cachedResults[$0.windowId] == nil }

        onProgress?(completed, windows.count)

        try await withThrowingTaskGroup(of: ScoredWindow.self) { group in
            var iterator = remainingWindows.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let window = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    ScoredWindow(
                        id: window.windowId,
                        candidates: try await scoreWindow(window, apiKey: apiKey, model: model)
                    )
                }
            }

            for _ in 0..<maxConcurrent { addNext() }

            while inFlight > 0 {
                if let scored = try await group.next() {
                    inFlight -= 1
                    completed += 1
                    onProgress?(completed, windows.count)
                    onWindowScored?(scored.id, scored.candidates)
                    results.append(contentsOf: scored.candidates)
                    addNext()
                }
            }
        }

        return results
    }

    public static func scoreWindow(
        _ window: TranscriptWindow, apiKey: String, model: String = defaultModel
    ) async throws -> [RawCandidate] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": [
                [
                    "type": "text",
                    "text": rubricPrompt,
                    "cache_control": ["type": "ephemeral"],
                ]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": "Transcript window (\(Int(window.startTime / 60))–\(Int(window.endTime / 60)) min):\n\n\(window.text)",
                ]
            ],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": Self.makeCandidateSchema(),
                ]
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ScoringError(description: "No HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<unreadable response>"
            let message = (try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data))?.error.message
            throw ScoringError(description: "Anthropic request failed (\(http.statusCode)): \(message ?? bodyText)")
        }

        let envelope = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        if envelope.stop_reason == "max_tokens" {
            throw ScoringError(description: "Response truncated (hit max_tokens) for window \(window.windowId)")
        }

        guard let text = envelope.content.first(where: { $0.type == "text" })?.text,
            let textData = text.data(using: .utf8)
        else {
            throw ScoringError(description: "No text content in response for window \(window.windowId)")
        }

        let parsed = try JSONDecoder().decode(CandidatesResponse.self, from: textData)
        return parsed.candidates
    }

    // MARK: - Request/response wire types

    private struct AnthropicResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
        let content: [ContentBlock]
        let stop_reason: String?
        let usage: Usage?
    }

    private struct AnthropicErrorResponse: Decodable {
        struct ErrorBody: Decodable {
            let message: String
        }

        let error: ErrorBody
    }

    private struct CandidatesResponse: Decodable {
        let candidates: [RawCandidate]
    }

    // MARK: - JSON schema (must satisfy Claude's structured-output subset:
    // every object needs additionalProperties: false and a full required list)

    private static func makeCandidateSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "candidates": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "quoteStart": ["type": "string"],
                            "quoteEnd": ["type": "string"],
                            "momentType": [
                                "type": "string",
                                "enum": MomentType.allCases.map(\.rawValue),
                            ],
                            "score": ["type": "integer"],
                            "reasoning": ["type": "string"],
                        ],
                        "required": ["quoteStart", "quoteEnd", "momentType", "score", "reasoning"],
                        "additionalProperties": false,
                    ] as [String: Any],
                ] as [String: Any]
            ],
            "required": ["candidates"],
            "additionalProperties": false,
        ]
    }

    // MARK: - Rubric (cached system prompt)

    private static let rubricPrompt = """
        You are finding short-form clip candidates in a transcript window from a long \
        podcast/debate video, for turning into vertical Reels/Shorts/TikToks (YouTube \
        Shorts, Instagram Reels, TikTok). This transcript window is one overlapping slice \
        of a much longer episode -- treat it as a self-contained excerpt and don't worry \
        about what came before or after it in the full episode.

        For each candidate moment you find, propose it as a JSON object with:
        - quoteStart: the first ~6-10 words of the moment, copied VERBATIM from the transcript
        - quoteEnd: the last ~6-10 words of the moment, copied VERBATIM from the transcript
        - momentType: one of "disagreement", "counterintuitive-claim", "specific-number", \
        "practical-answer", "insight", "reaction", "vulnerability"
        - score: 0-100 virality score
        - reasoning: one sentence explaining the score

        Do NOT invent timestamps. Do NOT paraphrase the quotes -- they must be exact \
        substrings of the transcript text so they can be matched back to it programmatically \
        by exact word sequence. If you can't find the exact words, don't propose that \
        candidate. Minor filler words ("um", "like", "you know") should be included if they \
        fall inside the quoted span, since the match is done on literal substrings.

        Cut-point judgment (this is what quoteStart/quoteEnd should express, since these \
        become the actual clip boundaries):
        - Start later than instinct suggests. Most good moments are preceded by 3-5 seconds \
        of throat-clearing ("yeah, no, I think, well, the thing about that is..."). \
        quoteStart should be the first word that actually carries meaning, not the run-up.
        - End on the landing, not after it. The point usually arrives, then the speaker \
        keeps going for a few more seconds, softening it or adding a caveat. quoteEnd should \
        be the words where the thought actually resolves -- a punchline, a period, a clear \
        conclusion -- not the trailing hedge after it.
        - Do not cut before a payoff to fake a cliffhanger. It reads as a broken clip, not \
        suspense, and viewers bounce immediately.

        Scoring rubric, in rough order of reliability (highest-value types first). These are \
        illustrative examples of what strong instances of each type sound like, not moments \
        that necessarily appear in this specific transcript:
        1. Disagreement -- two people landing on opposite sides of something. Self-explanatory \
        in 3 seconds, doesn't need to know who anyone is. Highest comment rate of any type, \
        because viewers want to pick a side. Example shape: "I actually think you're wrong \
        about that -- here's why."
        2. Counterintuitive claim -- states the opposite of received wisdom, then justifies \
        it. Example shape: "Posting every day is the worst thing you can do for a new channel."
        3. Specific number or concrete detail -- specificity beats vagueness every time. \
        "We lost about eleven grand a month" travels further than "we were struggling \
        financially" because a stranger can't fact-check vague claims but can react to a \
        precise one.
        4. Story with a turn -- a compressed anecdote with a setup, a complication, and a \
        resolution. Worth a slightly longer clip (60-90s) since the narrative itself does the \
        retention work.
        5. Practical answer -- a direct, usable answer to a question a stranger genuinely has. \
        Highest save/share rate of any type, since people bookmark it to use later.
        6. Genuine reaction -- real laughter, surprise, or discomfort, big enough to read \
        instantly on its own. Weakest type alone since it depends most on surrounding context, \
        but strong when paired with what triggered it.
        7. Vulnerability -- a surprising emotional or tonal shift, e.g. a brash speaker \
        admitting doubt or fear. Flag if it touches sensitive subject matter (trauma, illness, \
        legal jeopardy) so it can get extra editorial review before publishing.

        The "stranger test" is the master filter for every type above: if someone who has \
        never heard this episode would need one sentence of your explanation to understand \
        why the moment matters, it is not a clip. Skip moments that only make sense with \
        context from elsewhere in the episode.

        Always skip: introductions, sponsor reads, sign-offs, "as I mentioned earlier" \
        callbacks, and technical/audio troubleshooting chatter.

        Skip content that is hate speech, harassment, or targets someone's identity, \
        orientation, or protected characteristics as an insult -- score it low (under 40) even \
        if it has shock value, since it carries real platform-policy risk (strikes, demonetization) \
        and should not be recommended for publishing regardless of how "viral" it might look.

        Return every genuine candidate you find in this window, even if there are many -- do \
        not artificially limit yourself to a small number. A later pass will rank and filter \
        candidates across the whole episode together, so your only job here is high-recall \
        discovery within this window, not making the final publishing decision.
        """
}
