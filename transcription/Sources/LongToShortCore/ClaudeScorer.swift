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

    public struct ScoringError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Score every window, with bounded concurrency. The cached system
    /// prompt is identical across all calls, so parallelism doesn't hurt
    /// the cache hit rate -- Anthropic caches by prefix hash, not by order.
    public static func scoreAllWindows(
        _ windows: [TranscriptWindow],
        apiKey: String,
        model: String = defaultModel,
        maxConcurrent: Int = 4,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [RawCandidate] {
        var results: [RawCandidate] = []
        var completed = 0

        try await withThrowingTaskGroup(of: [RawCandidate].self) { group in
            var iterator = windows.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let window = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    try await scoreWindow(window, apiKey: apiKey, model: model)
                }
            }

            for _ in 0..<maxConcurrent { addNext() }

            while inFlight > 0 {
                if let candidates = try await group.next() {
                    inFlight -= 1
                    completed += 1
                    onProgress?(completed, windows.count)
                    results.append(contentsOf: candidates)
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
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
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
            let bodyText = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw ScoringError(description: "HTTP \(http.statusCode): \(bodyText)")
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
        podcast/debate video, for turning into vertical Reels/Shorts/TikToks.

        For each candidate moment you find, propose it as a JSON object with:
        - quoteStart: the first ~6-10 words of the moment, copied VERBATIM from the transcript
        - quoteEnd: the last ~6-10 words of the moment, copied VERBATIM from the transcript
        - momentType: one of "disagreement", "counterintuitive-claim", "specific-number", \
        "practical-answer", "insight", "reaction", "vulnerability"
        - score: 0-100 virality score
        - reasoning: one sentence explaining the score

        Do NOT invent timestamps. Do NOT paraphrase the quotes -- they must be exact \
        substrings of the transcript text so they can be matched back to it programmatically. \
        If you can't find the exact words, don't propose that candidate.

        Scoring rubric, in rough order of reliability:
        1. Disagreement -- two people landing on opposite sides. Self-explanatory in 3 \
        seconds, doesn't need to know who anyone is. Highest comment rate.
        2. Counterintuitive claim -- states the opposite of received wisdom, then justifies it.
        3. Specific number/detail -- concrete beats vague every time.
        4. Story with a turn -- compressed anecdote, setup -> complication -> resolution.
        5. Practical answer -- direct, usable answer to a question people actually have.
        6. Genuine reaction -- real laughter/surprise/discomfort, weakest alone since it \
        needs context.
        7. Vulnerability -- a surprising emotional/tonal shift; flag if sensitive subject matter.

        The "stranger test" is the master filter: if someone who's never heard the episode \
        would need one sentence of your explanation, it's not a clip. Skip moments that need \
        prior context to land.

        Skip: intros, sponsor reads, sign-offs, anything referencing "earlier in the episode."

        Skip content that is hate speech, harassment, or targets someone's identity/orientation \
        as an insult -- score it low (under 40) even if it has shock value, since it carries real \
        platform-policy risk and shouldn't be recommended for publishing.

        Return every genuine candidate you find in this window, even if there are many. A later \
        pass will rank and filter across the whole episode -- your job here is recall, not the \
        final cut.
        """
}
