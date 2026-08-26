import Foundation

/// Projects cumulative transcription snapshots into a newest-first live feed.
///
/// `LiveTranscriptionSession` deliberately emits cumulative snapshots so a
/// consumer can recover when its buffered event stream drops an intermediate
/// update. This type owns the projection into final and volatile rows without
/// changing that loss-tolerant contract.
///
/// When both channels' blocks merge here, cross-channel bleed deduplication
/// (`CrossChannelBleedFilter`) flags echoed duplicates instead of deleting
/// them: an echo row stays visible but carries `excludedFromReports`, matching
/// the voice-evidence exclusion philosophy that source text is marked, never
/// destroyed.
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
        /// True when this row repeats content already carried by the other
        /// channel (cross-channel bleed echo). The row stays in `rows` —
        /// nothing is deleted from the live feed — but report, notes-prompt,
        /// and query consumers must skip it. The mic channel always wins;
        /// system-channel duplicates are the ones flagged.
        public let excludedFromReports: Bool

        public var id: ID {
            ID(
                kind: kind,
                channel: block.channel,
                start: block.start,
                end: block.end,
                text: block.text
            )
        }

        fileprivate init(
            kind: Kind,
            block: TranscriptionBlock,
            excludedFromReports: Bool = false
        ) {
            self.kind = kind
            self.block = block
            self.excludedFromReports = excludedFromReports
        }
    }

    /// Cross-channel bleed evaluation applied every time rows merge across
    /// channels. Defaults to the documented parity thresholds; configuration
    /// deliberately does not participate in `Equatable`, which compares only
    /// the projected transcript state.
    public var bleedFilter = CrossChannelBleedFilter()
    private struct ChannelState: Equatable, Sendable {
        var finalBlocks: [TranscriptionBlock] = []
        var volatileBlock: TranscriptionBlock?
    }

    private var states: [TranscriptionChannel: ChannelState] = [:]

    /// The stored `states` is private, which would make the implicit
    /// memberwise initializer internal; iOS consumers construct empty feeds.
    public init(bleedFilter: CrossChannelBleedFilter = CrossChannelBleedFilter()) {
        self.bleedFilter = bleedFilter
    }


    public var rows: [Row] {
        let finalBlocks = states.values
            .flatMap(\.finalBlocks)
            .filter(Self.isVisible)
        let volatileBlocks = states.values
            .compactMap(\.volatileBlock)
            .filter(Self.isVisible)
        // Bleed evaluation runs over the merged view so a system-channel echo
        // is flagged as soon as the matching mic content exists in either the
        // volatile or the finalised lane. Rows are marked, never removed.
        let echoBlocks = bleedFilter
            .matches(in: finalBlocks + volatileBlocks)
            .map(\.echo)

        func makeRow(kind: Row.Kind, block: TranscriptionBlock) -> Row {
            Row(
                kind: kind,
                block: block,
                excludedFromReports: echoBlocks.contains { $0 == block }
            )
        }
        let finalRows = finalBlocks
            .sorted(by: Self.isNewer)
            .map { makeRow(kind: .final, block: $0) }
        let volatileRows = volatileBlocks
            .sorted(by: Self.isNewer)
            .map { makeRow(kind: .volatile, block: $0) }

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

    /// `bleedFilter` configuration is presentation tuning and intentionally
    /// excluded from equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.states == rhs.states
    }
}
