import StenoDomain
import Testing

@Suite("Final ASR job factory")
struct FinalASRJobTests {
    @Test("Meeting plan and explicit source locale are copied into the final ASR job")
    func plannedJob() throws {
        let plan = TranscriptionPlan(
            liveProviderID: .apple,
            finalProviderID: .parakeetTDTv3
        )
        let sourceLocale = try MeetingSourceLocale(
            localeIdentifier: "de-DE",
            origin: .explicit
        )
        let meeting = Meeting(
            title: "Test",
            status: .recording,
            sourceLocale: sourceLocale,
            transcriptionPlan: plan
        )

        let job = Job.finalASR(for: meeting)

        #expect(job.kind == .finalASR)
        #expect(job.meetingID == meeting.id)
        #expect(job.transcriptionProviderID == .parakeetTDTv3)
        #expect(job.localeIdentifier == "de-DE")
    }

    @Test("An only estimated source locale stays unpinned")
    func estimatedLocaleStaysUnpinned() throws {
        let sourceLocale = try MeetingSourceLocale(
            localeIdentifier: "de-DE",
            origin: .estimated
        )
        let meeting = Meeting(
            title: "Test",
            status: .recording,
            sourceLocale: sourceLocale
        )

        let job = Job.finalASR(for: meeting)

        #expect(job.localeIdentifier == nil)
    }

    @Test("Legacy meeting creates a legacy-compatible Apple job")
    func legacyJob() {
        let meeting = Meeting(title: "Alt", status: .interrupted)

        let job = Job.finalASR(for: meeting)

        #expect(job.transcriptionProviderID == nil)
        #expect(job.localeIdentifier == nil)
    }

    @Test("A demo job is pinned to its installation generation")
    func demoJobPreservesInstallationGeneration() {
        let generationID = MeetingTransferGenerationID()
        let meeting = Meeting(
            title: "Demo",
            status: .ready,
            metadata: MeetingMetadata(demoProvenance: DemoProvenance(
                datasetID: "demo",
                datasetVersion: "v1",
                itemID: "one",
                installationGenerationID: generationID
            ))
        )

        #expect(Job.finalASR(for: meeting).processingGenerationID == generationID)
    }

    @Test("An explicit re-run pins its arguments")
    func explicitJob() {
        let meetingID = MeetingID()

        let job = Job.finalASR(
            meetingID: meetingID,
            providerID: .apple,
            localeIdentifier: "fr-FR"
        )

        #expect(job.meetingID == meetingID)
        #expect(job.transcriptionProviderID == .apple)
        #expect(job.localeIdentifier == "fr-FR")
    }

    @Test("An explicit Apple retry preserves the failed processing generation")
    func explicitRetryGeneration() {
        let generationID = MeetingTransferGenerationID()

        let job = Job.finalASR(
            meetingID: MeetingID(),
            providerID: .apple,
            localeIdentifier: "de-DE",
            processingGenerationID: generationID
        )

        #expect(job.processingGenerationID == generationID)
    }
}
