import Foundation
import StenoDomain
import StenoIdentity
@testable import StenoPipeline
import Testing

@Suite("Speaker sample selection")
struct SpeakerSampleSelectorTests {
    private func turn(
        runID: RunID,
        clusterID: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) -> TranscriptTurn {
        TranscriptTurn(
            speaker: .cluster(
                runID: runID,
                clusterID: clusterID
            ),
            start: start,
            end: end,
            segments: [TranscriptSegment(text: text, start: start, end: end, words: [])]
        )
    }

    private func makeCluster(
        runID: RunID,
        id: String,
        channel: String = "systemTrack",
        mergedFrom: [String] = []
    ) -> IdentityCluster {
        IdentityCluster(
            meetingID: MeetingID(),
            runID: runID,
            channel: channel,
            clusterID: id,
            recordingType: .remote,
            embedding: [1, 0],
            speechDurationSeconds: 60,
            segmentCount: 5,
            mergedFrom: mergedFrom
        )
    }

    private func revision(turns: [TranscriptTurn]) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: turns
        )
    }

    @Test("best sample first, then chronological; caps at 20s and five")
    func selectionRules() {
        let runID = RunID()
        let turns = [
            turn(runID: runID, clusterID: "system/a/S0", start: 0, end: 1, text: "kurz"),
            turn(runID: runID, clusterID: "system/a/S0", start: 10, end: 40,
                 text: "dieser lange Turn hat mit Abstand die meisten Wörter von allen hier"),
            turn(runID: runID, clusterID: "system/a/S0", start: 50, end: 55, text: "mittel eins mit sechs Wörtern insgesamt"),
            turn(runID: runID, clusterID: "system/a/S0", start: 60, end: 66, text: "mittel zwei mit sechs Wörtern insgesamt"),
            turn(runID: runID, clusterID: "system/a/S0", start: 70, end: 73, text: "mittel drei mit sechs Wörtern insgesamt"),
            turn(runID: runID, clusterID: "system/a/S0", start: 80, end: 84, text: "mittel vier mit sechs Wörtern insgesamt"),
            turn(runID: runID, clusterID: "system/a/S0", start: 90, end: 93, text: "mittel fünf mit sechs Wörtern insgesamt"),
            turn(runID: runID, clusterID: "system/b/S1", start: 100, end: 110, text: "fremder Cluster mit vielen eigenen Wörtern"),
        ]
        let samples = SpeakerSampleSelector.samples(
            for: makeCluster(runID: runID, id: "a/S0"),
            revision: revision(turns: turns),
            resolutions: []
        )
        #expect(samples.count == 5)
        // Element 0 ist die beste (wortreichste) Probe, der Rest chronologisch.
        #expect(samples[0].turnStart == 10)
        #expect(samples[0].clipEnd == 30)
        let rest = samples.dropFirst().map(\.turnStart)
        #expect(rest == rest.sorted())
        #expect(!samples.contains { $0.text == "kurz" })
        #expect(!samples.contains { $0.text.contains("fremder Cluster") })
    }

    @Test("a long but word-poor turn loses against shorter word-rich turns")
    func chimeArtifactDemoted() {
        // Synthetischer Regressionsfall: Turn bei 00:00 war durch einen
        // Beitrittston über 2 s lang, trug aber nur zwei Wörter (und die
        // vom falschen Sprecher). Er darf nicht die Inline-Probe sein und
        // fliegt raus, sobald fünf bessere existieren.
        let runID = RunID()
        var turns = [turn(
            runID: runID,
            clusterID: "system/a/S0",
            start: 0,
            end: 3,
            text: "Test Person A"
        )]
        for index in 0..<3 {
            let start = TimeInterval(10 + index * 10)
            turns.append(turn(
                runID: runID,
                clusterID: "system/a/S0",
                start: start,
                end: start + 5,
                text: "eine ordentlich lange Passage mit deutlich mehr als sechs Wörtern"
            ))
        }
        let samples = SpeakerSampleSelector.samples(
            for: makeCluster(runID: runID, id: "a/S0"),
            revision: revision(turns: turns),
            resolutions: []
        )
        // Nur 3 vollwertige Proben existieren: die Liste bleibt bei 3,
        // statt mit dem Störschnipsel aufgefüllt zu werden.
        #expect(samples.count == 3)
        #expect(!samples.contains { $0.text == "Test Person A" })
    }

    @Test("merged fragments and resolutions contribute their turns")
    func manyToOneMembers() {
        let runID = RunID()
        let turns = [
            turn(runID: runID, clusterID: "system/a/S0", start: 0, end: 5, text: "primär"),
            turn(runID: runID, clusterID: "system/a/S2", start: 10, end: 15, text: "gemergtes Fragment"),
            turn(runID: runID, clusterID: "system/a/S3", start: 20, end: 25, text: "über Resolution"),
        ]
        let samples = SpeakerSampleSelector.samples(
            for: makeCluster(runID: runID, id: "a/S0", mergedFrom: ["a/S2"]),
            revision: revision(turns: turns),
            resolutions: [IdentityClusterResolution(
                channel: "systemTrack",
                sourceClusterID: "a/S3",
                primaryClusterID: "a/S0"
            )]
        )
        #expect(Set(samples.map(\.text))
            == ["primär", "gemergtes Fragment", "über Resolution"])
    }

    @Test("short turns appear only when nothing better exists")
    func fallbackToShort() {
        let runID = RunID()
        let turns = [turn(
            runID: runID,
            clusterID: "system/a/S0",
            start: 0,
            end: 1,
            text: "nur kurz"
        )]
        let samples = SpeakerSampleSelector.samples(
            for: makeCluster(runID: runID, id: "a/S0"),
            revision: revision(turns: turns),
            resolutions: []
        )
        #expect(samples.map(\.text) == ["nur kurz"])
    }

    @Test("same cluster ID across channels keeps samples separate")
    func sameClusterIDAcrossChannelsKeepsSamplesSeparate() {
        let runID = RunID()
        let turns = [
            turn(
                runID: runID,
                clusterID: "mic/SPEAKER_0",
                start: 0,
                end: 4,
                text: "dies ist ausschliesslich die Mikrofonprobe hier"
            ),
            turn(
                runID: runID,
                clusterID: "system/SPEAKER_0",
                start: 10,
                end: 14,
                text: "dies ist ausschliesslich die Systemtonprobe hier"
            ),
        ]
        let revision = revision(turns: turns)

        let microphoneSamples = SpeakerSampleSelector.samples(
            for: makeCluster(
                runID: runID,
                id: "SPEAKER_0",
                channel: MediaAsset.Kind.micTrack.rawValue
            ),
            revision: revision,
            resolutions: []
        )
        let systemSamples = SpeakerSampleSelector.samples(
            for: makeCluster(
                runID: runID,
                id: "SPEAKER_0",
                channel: MediaAsset.Kind.systemTrack.rawValue
            ),
            revision: revision,
            resolutions: []
        )

        #expect(microphoneSamples.map(\.text) == [
            "dies ist ausschliesslich die Mikrofonprobe hier",
        ])
        #expect(systemSamples.map(\.text) == [
            "dies ist ausschliesslich die Systemtonprobe hier",
        ])
    }

    @Test("bare cluster reference is rejected when its channel is ambiguous")
    func bareClusterReferenceIsRejectedWhenItsChannelIsAmbiguous() {
        let runID = RunID()
        let revision = revision(turns: [
            turn(
                runID: runID,
                clusterID: "SPEAKER_0",
                start: 0,
                end: 4,
                text: "diese kanalose Probe darf niemandem zugeordnet werden"
            ),
        ])
        let microphoneCluster = makeCluster(
            runID: runID,
            id: "SPEAKER_0",
            channel: MediaAsset.Kind.micTrack.rawValue
        )
        let systemCluster = makeCluster(
            runID: runID,
            id: "SPEAKER_0",
            channel: MediaAsset.Kind.systemTrack.rawValue
        )

        let microphoneSamples = SpeakerSampleSelector.samples(
            for: microphoneCluster,
            revision: revision,
            resolutions: []
        )
        let systemSamples = SpeakerSampleSelector.samples(
            for: systemCluster,
            revision: revision,
            resolutions: []
        )

        #expect(microphoneSamples.isEmpty)
        #expect(systemSamples.isEmpty)
    }

    @Test("known channel namespace cannot override the cluster channel")
    func knownChannelNamespaceCannotOverrideClusterChannel() {
        let runID = RunID()
        let clusterID = "mic/SPEAKER_0"
        let revision = revision(turns: [
            turn(
                runID: runID,
                clusterID: clusterID,
                start: 0,
                end: 4,
                text: "diese Mikrofonprobe darf nicht der Systemspur gehoeren"
            ),
        ])

        let samples = SpeakerSampleSelector.samples(
            for: makeCluster(
                runID: runID,
                id: clusterID,
                channel: MediaAsset.Kind.systemTrack.rawValue
            ),
            revision: revision,
            resolutions: []
        )

        #expect(samples.isEmpty)
    }

    @Test("media asset namespace includes primary, merge and resolution members")
    func mediaAssetNamespaceIncludesAllMembers() {
        let runID = RunID()
        let assetID = MediaAssetID(
            rawValue: UUID(uuidString: "01983333-7333-8333-8333-333333333333")!
        )
        let namespace = assetID.description
        let primaryID = "\(namespace)/SPEAKER_0"
        let mergedID = "\(namespace)/SPEAKER_1"
        let resolvedID = "\(namespace)/SPEAKER_2"
        let revision = revision(turns: [
            turn(
                runID: runID,
                clusterID: primaryID,
                start: 0,
                end: 4,
                text: "primaerer UUID Namespace Turn mit genug Woertern"
            ),
            turn(
                runID: runID,
                clusterID: mergedID,
                start: 10,
                end: 14,
                text: "gemergter UUID Namespace Turn mit genug Woertern"
            ),
            turn(
                runID: runID,
                clusterID: resolvedID,
                start: 20,
                end: 24,
                text: "aufgeloester UUID Namespace Turn mit genug Woertern"
            ),
        ])
        let cluster = makeCluster(
            runID: runID,
            id: primaryID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            mergedFrom: [mergedID]
        )

        let samples = SpeakerSampleSelector.samples(
            for: cluster,
            revision: revision,
            resolutions: [IdentityClusterResolution(
                channel: MediaAsset.Kind.systemTrack.rawValue,
                sourceClusterID: resolvedID,
                primaryClusterID: primaryID
            )]
        )

        #expect(Set(samples.map(\.text)) == [
            "primaerer UUID Namespace Turn mit genug Woertern",
            "gemergter UUID Namespace Turn mit genug Woertern",
            "aufgeloester UUID Namespace Turn mit genug Woertern",
        ])
    }

    @Test("media asset namespace rejects a turn from another run")
    func mediaAssetNamespaceRejectsOtherRun() {
        let clusterRunID = RunID()
        let otherRunID = RunID()
        let assetID = MediaAssetID(
            rawValue: UUID(uuidString: "01984444-7444-8444-8444-444444444444")!
        )
        let clusterID = "\(assetID)/SPEAKER_0"
        let revision = revision(turns: [
            turn(
                runID: otherRunID,
                clusterID: clusterID,
                start: 0,
                end: 4,
                text: "dieser UUID Turn stammt aus einem anderen Lauf"
            ),
        ])

        let samples = SpeakerSampleSelector.samples(
            for: makeCluster(
                runID: clusterRunID,
                id: clusterID,
                channel: MediaAsset.Kind.systemTrack.rawValue
            ),
            revision: revision,
            resolutions: []
        )

        #expect(samples.isEmpty)
    }

    @Test("non-UUID opaque namespace is never treated as globally unique")
    func nonUUIDOpaqueNamespaceIsRejectedAcrossChannels() {
        let runID = RunID()
        let revision = revision(turns: [turn(
            runID: runID,
            clusterID: "a/SPEAKER_0",
            start: 0,
            end: 4,
            text: "dieser unbekannte Namespace gehoert zu keiner sicheren Spur"
        )])

        let microphoneSamples = SpeakerSampleSelector.samples(
            for: makeCluster(
                runID: runID,
                id: "a/SPEAKER_0",
                channel: MediaAsset.Kind.micTrack.rawValue
            ),
            revision: revision,
            resolutions: []
        )
        let systemSamples = SpeakerSampleSelector.samples(
            for: makeCluster(
                runID: runID,
                id: "a/SPEAKER_0",
                channel: MediaAsset.Kind.systemTrack.rawValue
            ),
            revision: revision,
            resolutions: []
        )

        #expect(microphoneSamples.isEmpty)
        #expect(systemSamples.isEmpty)
    }
}
