import Foundation
import StenoAudioCore
import StenoTranscription
import Testing
@testable import steno_macos

@Suite("macOS live transcript feed")
struct MacLiveTranscriptFeedIntegrationTests {
    @Test @MainActor
    func cumulativeFinalsArePublishedOnceAndNewestFirst() {
        let model = AppModel()
        let first = block("first", start: 0, end: 1)
        let second = block("second", start: 1, end: 2)

        model.applyLiveEvent(.final(output([first])), track: .microphone)
        model.applyLiveEvent(
            .final(output([first, second])),
            track: .microphone
        )

        #expect(model.liveTranscriptRows.map(\.block.text) == ["second", "first"])
    }

    @Test @MainActor
    func onlyTheCurrentVolatileBlockIsPublished() {
        let model = AppModel()
        let final = block("final", start: 0, end: 1)
        let current = block("current", start: 1, end: 2)

        model.applyLiveEvent(
            .volatile(output([final, current])),
            track: .microphone
        )

        #expect(model.liveTranscriptRows.map(\.block.text) == ["final", "current"])
        #expect(model.liveTranscriptRows.map(\.kind) == [.final, .volatile])
    }

    private func block(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptionBlock {
        TranscriptionBlock(
            channel: .microphone,
            text: text,
            start: start,
            end: end,
            words: []
        )
    }

    private func output(_ blocks: [TranscriptionBlock]) -> TranscriptOutput {
        TranscriptOutput(localeIdentifier: "de-DE", blocks: blocks)
    }
}
