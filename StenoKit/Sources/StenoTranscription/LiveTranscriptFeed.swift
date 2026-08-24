import Foundation

/// Projects cumulative transcription snapshots into a newest-first live feed.
///
/// `LiveTranscriptionSession` deliberately emits cumulative snapshots so a
/// consumer can recover when its buffered event stream drops an intermediate
/// update. This type owns the projection into final and volatile rows without
/// changing that loss-tolerant contract.
public struct LiveTranscriptFeed: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public enum Kind: String, Equatable, Hashable, Sendable {
            case final
            case volatile
        }

        public struct ID: Equatable, Hashable, Sendable {
            fileprivate let kind: Kind
            fileprivate let channel: TranscriptionChannel
            fileprivate let start: TimeInterval
            fileprivate let end: TimeInterval
            fileprivate let text: String
        }

        public let kind: Kind
        public let block: TranscriptionBlock

        public var id: ID {
            ID(
                kind: kind,
                channel: block.channel,
                start: block.start,
                end: block.end,
                text: block.text
            )
        }

        fileprivate init(kind: Kind, block: TranscriptionBlock) {
            self.kind = kind
            self.block = block
        }
    }

    private struct ChannelState: Equatable, Sendable {
        var finalBlocks: [TranscriptionBlock] = []
        var volatileBlock: TranscriptionBlock?
    }

    private var states: [TranscriptionChannel: ChannelState] = [:]

    public init() {}

    public var rows: [Row] {
        let finalRows = states.values
            .flatMap(\.finalBlocks)
            .filter(Self.isVisible)
            .sorted(by: Self.isNewer)
            .map { Row(kind: .final, block: $0) }
        let volatileRows = states.values
            .compactMap(\.volatileBlock)
            .filter(Self.isVisible)
            .sorted(by: Self.isNewer)
            .map { Row(kind: .volatile, block: $0) }

        guard let newestFinal = finalRows.first else {
            return volatileRows
        }
        return [newestFinal] + volatileRows + finalRows.dropFirst()
    }

    public var isEmpty: Bool {
        rows.isEmpty
    }

    public mutating func apply(
        _ event: TranscriptionEvent,
        for channel: TranscriptionChannel
    ) {
        var state = states[channel, default: ChannelState()]

        switch event {
        case let .final(output):
            state.finalBlocks = output.blocks
            state.volatileBlock = nil

        case let .volatile(output):
            if output.blocks.isEmpty {
                state.volatileBlock = nil
            } else {
                state.finalBlocks = Array(output.blocks.dropLast())
                state.volatileBlock = output.blocks.last
            }
        }

        states[channel] = state
    }

    public mutating func clearVolatile() {
        for channel in Array(states.keys) {
            states[channel]?.volatileBlock = nil
        }
    }

    /// Drops the volatile row of a single channel.
    ///
    /// A capture gap ends the live session of one track only. The finalised
    /// rows of that track stay visible, and the other track keeps recognising.
    public mutating func clearVolatile(for channel: TranscriptionChannel) {
        states[channel]?.volatileBlock = nil
    }

    private static func isVisible(_ block: TranscriptionBlock) -> Bool {
        !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isNewer(
        _ lhs: TranscriptionBlock,
        than rhs: TranscriptionBlock
    ) -> Bool {
        if lhs.end != rhs.end {
            return lhs.end > rhs.end
        }
        if lhs.start != rhs.start {
            return lhs.start > rhs.start
        }
        if lhs.channel != rhs.channel {
            return lhs.channel.rawValue < rhs.channel.rawValue
        }
        return lhs.text < rhs.text
    }
}
