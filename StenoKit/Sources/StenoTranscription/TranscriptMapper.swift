import Foundation
import StenoDomain

public enum TranscriptMapper {
    public static func revision(
        from output: TranscriptOutput,
        meetingID: MeetingID,
        origin: TranscriptOrigin,
        createdAt: Date = Date()
    ) -> TranscriptRevision {
        revision(
            from: [output],
            meetingID: meetingID,
            origin: origin,
            createdAt: createdAt
        )
    }

    public static func revision(
        from outputs: [TranscriptOutput],
        meetingID: MeetingID,
        origin: TranscriptOrigin,
        createdAt: Date = Date()
    ) -> TranscriptRevision {
        let groupedBlocks = TranscriptionChannel.allCases.flatMap { channel in
            contiguousGroups(
                outputs.flatMap(\.blocks).filter { $0.channel == channel }
            )
        }
        let orderedGroups = groupedBlocks.enumerated().sorted { left, right in
            let leftStart = finiteNonnegative(left.element[0].start)
            let rightStart = finiteNonnegative(right.element[0].start)
            if leftStart == rightStart {
                return left.offset < right.offset
            }
            return leftStart < rightStart
        }.map(\.element)

        return TranscriptRevision(
            meetingID: meetingID,
            createdAt: createdAt,
            origin: origin,
            turns: orderedGroups.map(turn(from:))
        )
    }

    private static func contiguousGroups(
        _ blocks: [TranscriptionBlock]
    ) -> [[TranscriptionBlock]] {
        let ordered = blocks.enumerated().sorted { left, right in
            let leftStart = finiteNonnegative(left.element.start)
            let rightStart = finiteNonnegative(right.element.start)
            if leftStart == rightStart {
                return left.offset < right.offset
            }
            return leftStart < rightStart
        }.map(\.element)
        var groups: [[TranscriptionBlock]] = []
        // Das Gruppenende ist das laufende Maximum aller Blockenden, nicht das
        // Ende des zuletzt angehängten Blocks: ein umschließender Block muss
        // auch spätere Blöcke transitiv verbinden.
        var currentGroupEnd: TimeInterval = 0
        for block in ordered {
            let blockStart = finiteNonnegative(block.start)
            if !groups.isEmpty, blockStart <= currentGroupEnd {
                groups[groups.count - 1].append(block)
                currentGroupEnd = max(currentGroupEnd, normalizedEnd(of: block))
            } else {
                groups.append([block])
                currentGroupEnd = normalizedEnd(of: block)
            }
        }
        return groups
    }

    private static func turn(from blocks: [TranscriptionBlock]) -> TranscriptTurn {
        precondition(!blocks.isEmpty)
        let segments = blocks.map(segment(from:))
        let start = segments.map(\.start).min() ?? 0
        let end = segments.map(\.end).max() ?? start
        let channel = blocks[0].channel
        return TranscriptTurn(
            speaker: .channel(channel.speakerLabel),
            start: start,
            end: end,
            segments: segments
        )
    }

    private static func segment(
        from block: TranscriptionBlock
    ) -> TranscriptSegment {
        let start = finiteNonnegative(block.start)
        let end = normalizedEnd(of: block)
        let words = block.words.map { word in
            let wordStart = min(end, max(start, finiteNonnegative(word.start)))
            let proposedWordEnd = word.end.isFinite ? word.end : wordStart
            let wordEnd = min(end, max(wordStart, proposedWordEnd))
            return TranscriptWord(
                text: word.text,
                start: wordStart,
                end: wordEnd
            )
        }
        return TranscriptSegment(
            text: block.text,
            start: start,
            end: end,
            words: words
        )
    }

    private static func normalizedEnd(
        of block: TranscriptionBlock
    ) -> TimeInterval {
        let start = finiteNonnegative(block.start)
        return max(start, block.end.isFinite ? block.end : start)
    }

    private static func finiteNonnegative(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}
