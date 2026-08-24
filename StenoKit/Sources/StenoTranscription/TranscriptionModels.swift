import Foundation

public enum TranscriptionChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case system

    public var speakerLabel: String {
        switch self {
        case .microphone:
            "Ich"
        case .system:
            "Andere"
        }
    }
}

public struct TranscriptionWord: Codable, Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TranscriptionBlock: Codable, Equatable, Sendable {
    public let channel: TranscriptionChannel
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let words: [TranscriptionWord]

    public init(
        channel: TranscriptionChannel,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        words: [TranscriptionWord]
    ) {
        self.channel = channel
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

public struct TranscriptOutput: Codable, Equatable, Sendable {
    public let localeIdentifier: String
    public let blocks: [TranscriptionBlock]

    public init(localeIdentifier: String, blocks: [TranscriptionBlock]) {
        self.localeIdentifier = localeIdentifier
        self.blocks = blocks
    }

    public func shifted(by offset: TimeInterval) -> TranscriptOutput {
        let offset = max(0, offset)
        return TranscriptOutput(
            localeIdentifier: localeIdentifier,
            blocks: blocks.map { block in
                TranscriptionBlock(
                    channel: block.channel,
                    text: block.text,
                    start: block.start + offset,
                    end: block.end + offset,
                    words: block.words.map { word in
                        TranscriptionWord(
                            text: word.text,
                            start: word.start + offset,
                            end: word.end + offset
                        )
                    }
                )
            }
        )
    }
}

public enum TranscriptionEvent: Equatable, Sendable {
    case volatile(TranscriptOutput)
    case final(TranscriptOutput)

    public func shifted(by offset: TimeInterval) -> TranscriptionEvent {
        switch self {
        case let .volatile(output):
            .volatile(output.shifted(by: offset))
        case let .final(output):
            .final(output.shifted(by: offset))
        }
    }
}
