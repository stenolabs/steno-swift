import Foundation
import StenoDomain

public struct DiarizationAlignmentSegment: Codable, Equatable, Sendable {
    public let clusterID: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(clusterID: String, start: TimeInterval, end: TimeInterval) {
        self.clusterID = clusterID
        self.start = start
        self.end = end
    }
}

public enum TranscriptDiarizationAligner {
    public static let longSentenceThreshold: TimeInterval = 5
    public static let placementTolerance: TimeInterval = 1
    public static let mergeGap: TimeInterval = 0.3

    public static func normalizedSegments(
        _ segments: [DiarizationAlignmentSegment]
    ) -> [DiarizationAlignmentSegment] {
        let ordered = segments.enumerated().sorted { lhs, rhs in
            if lhs.element.start == rhs.element.start {
                return lhs.offset < rhs.offset
            }
            return lhs.element.start < rhs.element.start
        }.map(\.element)
        let initiallyMerged = mergeCloseSegments(ordered)

        var clamped: [DiarizationAlignmentSegment] = []
        var runningEnd: TimeInterval?
        for segment in initiallyMerged {
            var start = segment.start
            if let runningEnd,
               start < runningEnd,
               runningEnd < segment.end {
                start = runningEnd
            }
            clamped.append(DiarizationAlignmentSegment(
                clusterID: segment.clusterID,
                start: start,
                end: segment.end
            ))
            runningEnd = max(runningEnd ?? segment.end, segment.end)
        }
        let reordered = clamped.enumerated().sorted { lhs, rhs in
            if lhs.element.start == rhs.element.start {
                return lhs.offset < rhs.offset
            }
            return lhs.element.start < rhs.element.start
        }.map(\.element)
        return mergeCloseSegments(reordered)
    }

    public static func align(
        _ output: TranscriptOutput,
        to diarizationSegments: [DiarizationAlignmentSegment],
        runID: RunID
    ) -> [TranscriptTurn] {
        let diarizationSegments = normalizedSegments(diarizationSegments)
        return output.blocks.enumerated().flatMap { offset, block in
            alignedPieces(
                for: block,
                diarizationSegments: diarizationSegments,
                runID: runID
            ).enumerated().map { pieceOffset, turn in
                (block.start, offset, pieceOffset, turn)
            }
        }.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }.map(\.3)
    }

    private static func alignedPieces(
        for block: TranscriptionBlock,
        diarizationSegments: [DiarizationAlignmentSegment],
        runID: RunID
    ) -> [TranscriptTurn] {
        let duration = max(0, block.end - block.start)
        let overlappingClusters = Set(diarizationSegments.compactMap { segment in
            segment.start < block.end && segment.end > block.start
                ? segment.clusterID
                : nil
        })
        if duration >= longSentenceThreshold,
           !block.words.isEmpty,
           wordTimingsCoverText(in: block),
           overlappingClusters.count > 1 {
            let split = wordLevelPieces(
                for: block,
                diarizationSegments: diarizationSegments,
                runID: runID
            )
            if !split.isEmpty { return split }
        }

        guard let nearest = nearestSegment(
            start: block.start,
            end: block.end,
            in: diarizationSegments
        ) else {
            return [turn(
                speaker: .channel(block.channel.speakerLabel),
                segment: transcriptSegment(from: block)
            )]
        }
        return [turn(
            speaker: .cluster(runID: runID, clusterID: nearest.clusterID),
            segment: transcriptSegment(from: block)
        )]
    }

    private static func wordTimingsCoverText(
        in block: TranscriptionBlock
    ) -> Bool {
        func withoutWhitespace(_ text: String) -> String {
            text.filter { !$0.isWhitespace }
        }
        return withoutWhitespace(block.words.map(\.text).joined())
            == withoutWhitespace(block.text)
    }

    private static func wordLevelPieces(
        for block: TranscriptionBlock,
        diarizationSegments: [DiarizationAlignmentSegment],
        runID: RunID
    ) -> [TranscriptTurn] {
        var result: [TranscriptTurn] = []
        var runClusterID: String?
        var runWords: [TranscriptWord] = []

        func flush() {
            guard let runClusterID, !runWords.isEmpty else { return }
            let segment = TranscriptSegment(
                text: runWords.map(\.text).joined(separator: " "),
                start: runWords.map(\.start).min() ?? block.start,
                end: runWords.map(\.end).max() ?? block.end,
                words: runWords
            )
            result.append(turn(
                speaker: .cluster(runID: runID, clusterID: runClusterID),
                segment: segment
            ))
            runWords = []
        }

        for word in block.words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let transcriptWord = normalizedWord(word, within: block)
            guard let nearest = nearestSegment(
                start: transcriptWord.start,
                end: transcriptWord.end,
                in: diarizationSegments
            ) else {
                runWords.append(transcriptWord)
                continue
            }
            if let runClusterID, runClusterID != nearest.clusterID {
                flush()
            }
            runClusterID = nearest.clusterID
            runWords.append(transcriptWord)
        }
        flush()
        return result
    }

    private static func nearestSegment(
        start: TimeInterval,
        end: TimeInterval,
        in segments: [DiarizationAlignmentSegment]
    ) -> DiarizationAlignmentSegment? {
        let midpoint = (start + end) / 2
        var best: DiarizationAlignmentSegment?
        var bestDistance = TimeInterval.infinity
        for segment in segments {
            if segment.start <= midpoint, midpoint <= segment.end {
                return segment
            }
            let distance = midpoint < segment.start
                ? segment.start - midpoint
                : midpoint - segment.end
            if distance < bestDistance {
                best = segment
                bestDistance = distance
            }
        }
        return bestDistance <= placementTolerance ? best : nil
    }

    private static func mergeCloseSegments(
        _ segments: [DiarizationAlignmentSegment]
    ) -> [DiarizationAlignmentSegment] {
        var merged: [DiarizationAlignmentSegment] = []
        for segment in segments {
            if let last = merged.last,
               last.clusterID == segment.clusterID,
               segment.start - last.end <= mergeGap {
                merged[merged.count - 1] = DiarizationAlignmentSegment(
                    clusterID: last.clusterID,
                    start: last.start,
                    end: max(last.end, segment.end)
                )
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func transcriptSegment(
        from block: TranscriptionBlock
    ) -> TranscriptSegment {
        let start = max(0, block.start.isFinite ? block.start : 0)
        let end = max(start, block.end.isFinite ? block.end : start)
        return TranscriptSegment(
            text: block.text,
            start: start,
            end: end,
            words: block.words.map { normalizedWord($0, within: block) }
        )
    }

    private static func normalizedWord(
        _ word: TranscriptionWord,
        within block: TranscriptionBlock
    ) -> TranscriptWord {
        let blockStart = max(0, block.start.isFinite ? block.start : 0)
        let blockEnd = max(blockStart, block.end.isFinite ? block.end : blockStart)
        let start = min(blockEnd, max(blockStart, word.start.isFinite ? word.start : blockStart))
        let end = min(blockEnd, max(start, word.end.isFinite ? word.end : start))
        return TranscriptWord(text: word.text, start: start, end: end)
    }

    private static func turn(
        speaker: SpeakerReference,
        segment: TranscriptSegment
    ) -> TranscriptTurn {
        TranscriptTurn(
            speaker: speaker,
            start: segment.start,
            end: segment.end,
            segments: [segment]
        )
    }
}
