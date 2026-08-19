import Foundation
import StenoDomain
import Testing
@testable import StenoTranscription

@Suite("Transcript diarization alignment")
struct TranscriptDiarizationAlignerTests {
    @Test("assigns a sentence to the diarization segment containing its midpoint")
    func assignsByMidpoint() {
        let runID = RunID()
        let output = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [block(text: "Hallo Welt", start: 0, end: 2)]
        )

        let turns = TranscriptDiarizationAligner.align(
            output,
            to: [
                DiarizationAlignmentSegment(clusterID: "A", start: 0, end: 1.25),
                DiarizationAlignmentSegment(clusterID: "B", start: 1.5, end: 3),
            ],
            runID: runID
        )

        #expect(turns.count == 1)
        #expect(turns[0].speaker == .cluster(runID: runID, clusterID: "A"))
        #expect(turns[0].segments.map(\.text) == ["Hallo Welt"])
    }

    @Test("splits a long multi-speaker sentence by word timestamps and rejoins equal runs")
    func splitsLongSentenceByWords() {
        let runID = RunID()
        let output = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Eins zwei drei vier",
                    start: 0,
                    end: 6,
                    words: [
                        TranscriptionWord(text: "Eins", start: 0, end: 0.8),
                        TranscriptionWord(text: "zwei", start: 1, end: 2),
                        TranscriptionWord(text: "drei", start: 3, end: 4),
                        TranscriptionWord(text: "vier", start: 5, end: 6),
                    ]
                ),
            ]
        )

        let turns = TranscriptDiarizationAligner.align(
            output,
            to: [
                DiarizationAlignmentSegment(clusterID: "A", start: 0, end: 2.4),
                DiarizationAlignmentSegment(clusterID: "B", start: 2.6, end: 6),
            ],
            runID: runID
        )

        #expect(turns.map(\.speaker) == [
            .cluster(runID: runID, clusterID: "A"),
            .cluster(runID: runID, clusterID: "B"),
        ])
        #expect(turns.flatMap(\.segments).map(\.text) == ["Eins zwei", "drei vier"])
        #expect(turns.flatMap(\.segments).map { $0.words.map(\.text) } == [
            ["Eins", "zwei"],
            ["drei", "vier"],
        ])
    }

    @Test("keeps the complete sentence when word timestamps cover only part of its text")
    func preservesPartiallyTimedSentence() {
        let runID = RunID()
        let output = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Eins zwei drei vier",
                    start: 0,
                    end: 6,
                    words: [
                        TranscriptionWord(text: "Eins", start: 0, end: 1),
                        TranscriptionWord(text: "zwei", start: 1, end: 2),
                    ]
                ),
            ]
        )

        let turns = TranscriptDiarizationAligner.align(
            output,
            to: [
                DiarizationAlignmentSegment(clusterID: "A", start: 0, end: 2.5),
                DiarizationAlignmentSegment(clusterID: "B", start: 2.5, end: 6),
            ],
            runID: runID
        )

        #expect(turns.count == 1)
        #expect(turns[0].speaker == .cluster(runID: runID, clusterID: "B"))
        #expect(turns[0].segments.map(\.text) == ["Eins zwei drei vier"])
    }

    @Test("keeps an unplaceable sentence under its channel label")
    func keepsUnplaceableSentence() {
        let output = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [block(text: "Nicht verlieren", start: 0, end: 1)]
        )

        let turns = TranscriptDiarizationAligner.align(
            output,
            to: [DiarizationAlignmentSegment(clusterID: "A", start: 2, end: 3)],
            runID: RunID()
        )

        #expect(turns.count == 1)
        #expect(turns[0].speaker == .channel("Ich"))
        #expect(turns[0].segments.map(\.text) == ["Nicht verlieren"])
    }

    @Test("merges close equal segments before clamping overlaps and merging again")
    func normalizesMergeAndClamp() {
        let normalized = TranscriptDiarizationAligner.normalizedSegments([
            DiarizationAlignmentSegment(clusterID: "A", start: 0, end: 1),
            DiarizationAlignmentSegment(clusterID: "A", start: 1.2, end: 2),
            DiarizationAlignmentSegment(clusterID: "B", start: 1.5, end: 3),
            DiarizationAlignmentSegment(clusterID: "B", start: 3.2, end: 4),
        ])

        #expect(normalized == [
            DiarizationAlignmentSegment(clusterID: "A", start: 0, end: 2),
            DiarizationAlignmentSegment(clusterID: "B", start: 2, end: 4),
        ])
    }

    @Test("does not delete a segment fully nested in an earlier overlap")
    func preservesFullyNestedSegment() {
        let normalized = TranscriptDiarizationAligner.normalizedSegments([
            DiarizationAlignmentSegment(clusterID: "A", start: 0, end: 4),
            DiarizationAlignmentSegment(clusterID: "B", start: 1, end: 2),
        ])

        #expect(normalized == [
            DiarizationAlignmentSegment(clusterID: "A", start: 0, end: 4),
            DiarizationAlignmentSegment(clusterID: "B", start: 1, end: 2),
        ])
    }

    private func block(
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptionBlock {
        TranscriptionBlock(
            channel: .microphone,
            text: text,
            start: start,
            end: end,
            words: [TranscriptionWord(text: text, start: start, end: end)]
        )
    }
}
