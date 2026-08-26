import Foundation
import StenoDomain
import StenoLibrary
@testable import StenoPipeline
import Testing

@Suite("Appended meeting timeline")
struct AppendedTimelineTests {
    private let meetingID = MeetingID()

    private func asset(
        kind: MediaAsset.Kind,
        sequence: Int,
        duration: TimeInterval
    ) -> MediaAsset {
        MediaAsset(
            meetingID: meetingID,
            kind: kind,
            sampleRate: 48_000,
            duration: duration,
            provenanceKey: RecordedTrackProvenanceKey.make(
                meetingID: meetingID,
                kind: kind,
                sequence: sequence
            ),
            fileName: UUID().uuidString
        )
    }

    private func importedAsset(duration: TimeInterval) -> MediaAsset {
        MediaAsset(
            meetingID: meetingID,
            kind: .imported,
            sampleRate: 48_000,
            duration: duration,
            provenanceKey: "legacy:some-stem",
            fileName: UUID().uuidString
        )
    }

    @Test("empty input yields zero timeline")
    func emptyInputYieldsZero() {
        #expect(AppendedTimeline.timelineEnd(of: []) == 0)
        #expect(AppendedTimeline.offsets(for: []).isEmpty)
        #expect(AppendedTimeline.processingOrder([]).isEmpty)
    }

    @Test("tracks of one session share time zero")
    func oneSessionSharesZero() {
        let microphone = asset(kind: .micTrack, sequence: 1, duration: 10)
        let system = asset(kind: .systemTrack, sequence: 1, duration: 8)
        let assets = [microphone, system]

        let offsets = AppendedTimeline.offsets(for: assets)
        #expect(offsets[microphone.id] == 0)
        #expect(offsets[system.id] == 0)
        // Mikro und System laufen parallel: das Sitzungsende ist das Maximum.
        #expect(AppendedTimeline.timelineEnd(of: assets) == 10)
    }

    @Test("a later session continues after the longest existing end")
    func laterSessionContinuesAfterLongestEnd() {
        let firstMicrophone = asset(kind: .micTrack, sequence: 1, duration: 10)
        let firstSystem = asset(kind: .systemTrack, sequence: 1, duration: 4)
        let secondMicrophone = asset(kind: .micTrack, sequence: 2, duration: 5)
        let secondSystem = asset(kind: .systemTrack, sequence: 2, duration: 7)
        let thirdMicrophone = asset(kind: .micTrack, sequence: 3, duration: 2)
        let assets = [
            secondSystem,
            firstSystem,
            thirdMicrophone,
            secondMicrophone,
            firstMicrophone,
        ]

        let offsets = AppendedTimeline.offsets(for: assets)
        #expect(offsets[firstMicrophone.id] == 0)
        #expect(offsets[firstSystem.id] == 0)
        #expect(offsets[secondMicrophone.id] == 10)
        #expect(offsets[secondSystem.id] == 10)
        #expect(offsets[thirdMicrophone.id] == 17)
        #expect(AppendedTimeline.timelineEnd(of: assets) == 19)

        // Verarbeitung in chronologischer Reihenfolge, Mikro vor System.
        #expect(
            AppendedTimeline.processingOrder(assets).map(\.id)
                == [
                    firstMicrophone.id,
                    firstSystem.id,
                    secondMicrophone.id,
                    secondSystem.id,
                    thirdMicrophone.id,
                ]
        )
    }

    @Test("unparsable keys form a single first session at zero")
    func unparsableKeysStayAtZero() {
        let imported = importedAsset(duration: 6)
        let legacyMicrophone = MediaAsset(
            meetingID: meetingID,
            kind: .micTrack,
            sampleRate: 48_000,
            duration: 4,
            provenanceKey: "sha256:\(String(repeating: "c", count: 64))",
            fileName: UUID().uuidString
        )
        let assets = [imported, legacyMicrophone]
        let offsets = AppendedTimeline.offsets(for: assets)
        #expect(offsets[imported.id] == 0)
        #expect(offsets[legacyMicrophone.id] == 0)
        #expect(AppendedTimeline.timelineEnd(of: assets) == 6)
    }

    @Test("negative durations do not move the timeline backwards")
    func negativeDurationsAreClamped() {
        let broken = asset(kind: .micTrack, sequence: 1, duration: -5)
        let appended = asset(kind: .micTrack, sequence: 2, duration: 3)
        let offsets = AppendedTimeline.offsets(for: [broken, appended])
        #expect(offsets[broken.id] == 0)
        #expect(offsets[appended.id] == 0)
        #expect(AppendedTimeline.timelineEnd(of: [broken, appended]) == 3)
    }
}
