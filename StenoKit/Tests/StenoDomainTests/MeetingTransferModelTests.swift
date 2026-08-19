import Foundation
import Testing
@testable import StenoDomain

@Suite("Meeting transfer models")
struct MeetingTransferModelTests {
    @Test("old jobs decode without a pinned locale")
    func oldJobDecodesWithoutLocale() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "id": "018f22e2-7c00-7000-8000-000000000001",
              "kind": "finalASR",
              "meetingID": "018f22e2-7c00-7000-8000-000000000002",
              "status": "queued",
              "attemptCount": 0,
              "createdAt": 0
            }
            """.utf8
        )

        let job = try JSONDecoder().decode(Job.self, from: data)
        #expect(job.localeIdentifier == nil)
        #expect(job.importGenerationID == nil)
    }

    @Test("old runs decode without a pinned locale")
    func oldRunDecodesWithoutLocale() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "id": "018f22e2-7c00-7000-8000-000000000003",
              "meetingID": "018f22e2-7c00-7000-8000-000000000002",
              "kind": "finalASR",
              "engine": { "name": "fixture", "version": "1" },
              "status": "finished",
              "createdAt": 0
            }
            """.utf8
        )

        #expect(try JSONDecoder().decode(ProcessingRun.self, from: data).localeIdentifier == nil)
    }

    @Test("meeting metadata decodes without a transfer receipt")
    func oldMeetingMetadataRemainsReadable() throws {
        let data = Data(#"{"legacyProvenanceKey":null,"legacyFolders":[]}"#.utf8)

        #expect(try JSONDecoder().decode(MeetingMetadata.self, from: data).transferReceipt == nil)
    }

    @Test("imported speaker label carries text but no person identity")
    func importedLabelIsTextOnly() {
        let label = ImportedSpeakerTextLabel(
            id: UUID(uuidString: "00000000-0000-7000-8000-000000000010")!,
            text: "Ada",
            wasConfirmedAtSource: true
        )

        #expect(SpeakerReference.importedTextLabel(label) != .person(PersonID()))
    }

    @Test("transfer contracts round-trip their explicit provenance")
    func transferContractsRoundTrip() throws {
        let meetingID = MeetingID(
            rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000011")!
        )
        let revisionID = RevisionID(
            rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000012")!
        )
        let jobID = JobID(
            rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000013")!
        )
        let requestID = MeetingTransferRequestID(
            rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000014")!
        )
        let generationID = MeetingTransferGenerationID(
            rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000015")!
        )
        let receipt = MeetingTransferReceipt(
            sourceMeetingID: meetingID,
            sourceRevisionID: revisionID,
            sourcePackageContentDigest: "digest",
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceAppVersion: "1.0",
            includedCapabilities: [.notes, .transcript],
            sourceLocaleIdentifier: "de-DE",
            sourceLocaleOrigin: .explicit,
            importGenerationID: generationID
        )
        let request = ImportedProcessingRequest(
            id: requestID,
            jobID: jobID,
            meetingID: meetingID,
            localeIdentifier: "de-DE",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            importGenerationID: generationID
        )
        let job = Job(
            id: jobID,
            kind: .finalASR,
            meetingID: meetingID,
            localeIdentifier: "de-DE",
            importGenerationID: generationID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        try expectRoundTrip(receipt)
        try expectRoundTrip(ImportedMeetingProcessingState.processingRequested(request))
        try expectRoundTrip(job)
        try expectRoundTrip(
            TranscriptOrigin.meetingTransfer(
                sourceMeetingID: meetingID,
                sourceRevisionID: revisionID
            )
        )
    }

    @Test("pre-generation transfer records remain decodable")
    func preGenerationTransferRecordsRemainDecodable() throws {
        let receiptData = Data(
            """
            {
              "sourceMeetingID": "018f22e2-7c00-7000-8000-000000000002",
              "sourcePackageContentDigest": "digest",
              "importedAt": 0,
              "includedCapabilities": ["notes"],
              "sourceLocaleOrigin": "explicit"
            }
            """.utf8
        )
        let requestData = Data(
            """
            {
              "id": "018f22e2-7c00-7000-8000-000000000004",
              "jobID": "018f22e2-7c00-7000-8000-000000000001",
              "meetingID": "018f22e2-7c00-7000-8000-000000000002",
              "localeIdentifier": "de-DE",
              "createdAt": 0
            }
            """.utf8
        )

        #expect(try JSONDecoder().decode(
            MeetingTransferReceipt.self,
            from: receiptData
        ).importGenerationID == nil)
        #expect(try JSONDecoder().decode(
            ImportedProcessingRequest.self,
            from: requestData
        ).importGenerationID == nil)
    }

    private func expectRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(Value.self, from: data) == value)
    }
}
