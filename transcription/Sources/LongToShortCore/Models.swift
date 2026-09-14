import Foundation

// MARK: - Transcript

public struct TranscriptWord: Codable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let confidence: Float
    public let speaker: String

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float, speaker: String) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speaker = speaker
    }
}

public struct Transcript: Codable, Sendable {
    public let sourceFile: String
    public let durationSeconds: TimeInterval
    public let fullText: String
    public let speakerCount: Int
    public let speakers: [String]
    public let words: [TranscriptWord]

    public init(
        sourceFile: String, durationSeconds: TimeInterval, fullText: String,
        speakerCount: Int, speakers: [String], words: [TranscriptWord]
    ) {
        self.sourceFile = sourceFile
        self.durationSeconds = durationSeconds
        self.fullText = fullText
        self.speakerCount = speakerCount
        self.speakers = speakers
        self.words = words
    }
}

// MARK: - Windowing

public struct TranscriptWindow: Sendable {
    public let windowId: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let wordStartIdx: Int
    public let wordEndIdx: Int
    public let text: String
}

// MARK: - Highlight candidates

public enum MomentType: String, Codable, Sendable, CaseIterable {
    case disagreement
    case counterintuitiveClaim = "counterintuitive-claim"
    case specificNumber = "specific-number"
    case practicalAnswer = "practical-answer"
    case insight
    case reaction
    case vulnerability
}

/// Raw candidate proposed by Claude: verbatim quote anchors, never timestamps.
public struct RawCandidate: Codable, Sendable {
    public let quoteStart: String
    public let quoteEnd: String
    public let momentType: MomentType
    public let score: Int
    public let reasoning: String

    public init(quoteStart: String, quoteEnd: String, momentType: MomentType, score: Int, reasoning: String) {
        self.quoteStart = quoteStart
        self.quoteEnd = quoteEnd
        self.momentType = momentType
        self.score = score
        self.reasoning = reasoning
    }
}

/// A candidate with its quote anchors resolved to exact word-level timestamps.
public struct ResolvedCandidate: Sendable {
    public let raw: RawCandidate
    public let startWordIdx: Int
    public var endWordIdx: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public let matchConfidence: Double
    public var extended: Bool = false

    public var durationSeconds: TimeInterval { end - start }
    public var score: Int { raw.score }
    public var momentType: MomentType { raw.momentType }
}

/// A final, selected highlight ready to be cut.
public struct Highlight: Codable, Sendable {
    public let id: String
    public let momentType: MomentType
    public let score: Int
    public let reasoning: String
    public let start: TimeInterval
    public let end: TimeInterval
    public var durationSeconds: TimeInterval { end - start }
}
