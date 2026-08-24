import Foundation
import Testing
@testable import StenoDomain

@Suite("Demo provenance")
struct DemoProvenanceTests {
    private let generationID = MeetingTransferGenerationID(
        rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000123")!
    )
    private let provenance = DemoProvenance(
        datasetID: "synthetic-demo",
        datasetVersion: "2026-08-23",
        itemID: "projektauftakt-musterstadt"
    )

    @Test("demo provenance round-trips its stable identifiers")
    func provenanceRoundTrips() throws {
        try expectRoundTrip(provenance)
        #expect(provenance.datasetID == "synthetic-demo")
        #expect(provenance.datasetVersion == "2026-08-23")
        #expect(provenance.itemID == "projektauftakt-musterstadt")
    }

    @Test("demo installation generation is persisted and selected before transfer provenance")
    func processingGenerationPrefersDemoInstallation() throws {
        let demo = DemoProvenance(
            datasetID: provenance.datasetID,
            datasetVersion: provenance.datasetVersion,
            itemID: provenance.itemID,
            installationGenerationID: generationID
        )
        let transferGeneration = MeetingTransferGenerationID()
        let meeting = Meeting(
            title: "Demo",
            status: .ready,
            metadata: MeetingMetadata(
                transferReceipt: MeetingTransferReceipt(
                    sourceMeetingID: MeetingID(),
                    sourceRevisionID: nil,
                    sourcePackageContentDigest: String(repeating: "a", count: 64),
                    importedAt: Date(timeIntervalSince1970: 1),
                    sourceAppVersion: nil,
                    includedCapabilities: [],
                    sourceLocaleIdentifier: nil,
                    sourceLocaleOrigin: .absent,
                    importGenerationID: transferGeneration
                ),
                demoProvenance: demo
            )
        )

        #expect(meeting.processingGenerationID == generationID)
        #expect(try JSONDecoder().decode(
            Meeting.self,
            from: JSONEncoder().encode(meeting)
        ).processingGenerationID == generationID)
    }

    @Test("old demo provenance decodes without an installation generation")
    func oldDemoProvenanceDecodesWithoutGeneration() throws {
        let data = Data(
            """
            {"datasetID":"synthetic-demo","datasetVersion":"v1","itemID":"one"}
            """.utf8
        )

        let decoded = try JSONDecoder().decode(DemoProvenance.self, from: data)

        #expect(decoded.installationGenerationID == nil)
    }

    @Test("job processing generation aliases the persisted import-generation key")
    func jobProcessingGenerationAliasesPersistedKey() throws {
        let job = Job(
            kind: .finalASR,
            meetingID: MeetingID(),
            importGenerationID: generationID
        )
        let data = try JSONEncoder().encode(job)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(job.processingGenerationID == generationID)
        #expect(object["processingGenerationID"] == nil)
        #expect(object["importGenerationID"] != nil)
        #expect(try JSONDecoder().decode(Job.self, from: data).processingGenerationID == generationID)
    }

    @Test("demo transcript origins round-trip their provenance")
    func demoTranscriptOriginRoundTrips() throws {
        try expectRoundTrip(TranscriptOrigin.demo(provenance))
    }

    @Test("schema-one meeting metadata without demo provenance remains readable")
    func legacyMeetingMetadataRemainsWithoutDemoProvenance() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "id": "018f22e2-7c00-7000-8000-000000000001",
              "title": "Alte Aufnahme",
              "createdAt": 0,
              "status": "ready",
              "metadata": {"legacyProvenanceKey": null, "legacyFolders": []}
            }
            """.utf8
        )

        let meeting = try JSONDecoder().decode(Meeting.self, from: data)

        #expect(meeting.metadata?.demoProvenance == nil)
        #expect(!meeting.isDemo)
    }

    @Test("renaming and refiling a demo meeting preserve its demo identity")
    func demoIdentitySurvivesRenameAndFolderChanges() {
        var meeting = Meeting(
            title: "DEMO: Projektauftakt Musterstadt",
            status: .ready,
            metadata: MeetingMetadata(demoProvenance: provenance)
        )

        #expect(meeting.isDemo)

        meeting.title = "Umbenanntes Beispielmeeting"
        meeting.folderID = FolderID(
            rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000099")!
        )

        #expect(meeting.isDemo)
    }

    @Test("a real meeting title with a demo prefix is not a demo")
    func demoTitleDoesNotCreateDemoIdentity() {
        let meeting = Meeting(
            title: "DEMO: Real meeting",
            status: .ready
        )

        #expect(!meeting.isDemo)
    }

    private func expectRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(Value.self, from: data) == value)
    }
}
