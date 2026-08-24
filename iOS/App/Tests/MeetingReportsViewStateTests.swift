import Foundation
import StenoDomain
import StenoIntelligence
import StenoPipeline
import Testing
@testable import Steno

@Suite("Meeting reports view state")
struct MeetingReportsViewStateTests {
    @Test("button title follows immutable report presence")
    func buttonTitles() {
        #expect(english(MeetingReportsViewState.actionTitle(hasReport: false)) == "Generate minutes")
        #expect(english(MeetingReportsViewState.actionTitle(hasReport: true)) == "Regenerate")
    }

    @Test(
        "every unavailable Apple state disables generation",
        arguments: [
            TextModelAvailability.unavailable(.deviceNotEligible),
            .unavailable(.appleIntelligenceNotEnabled),
            .unavailable(.modelNotReady),
            .unavailable(.unknown),
        ]
    )
    func appleUnavailable(availability: TextModelAvailability) {
        let state = MeetingReportsViewState(
            hasReport: true,
            hasTranscript: true,
            hasUnconfirmedSpeakers: false,
            usesExternalEndpoint: false,
            appleAvailability: availability
        )

        #expect(!state.canGenerate)
        #expect(state.availabilityMessage.map(english) == availability.unavailabilityMessage)
    }

    @Test("a configured external endpoint is actionable without a probe")
    func externalEndpointDoesNotNeedProbe() {
        let state = MeetingReportsViewState(
            hasReport: false,
            hasTranscript: true,
            hasUnconfirmedSpeakers: false,
            usesExternalEndpoint: true,
            appleAvailability: .unavailable(.deviceNotEligible)
        )

        #expect(state.canGenerate)
        #expect(state.availabilityMessage == nil)
    }

    @Test("missing transcript blocks generation but keeps existing results readable")
    func missingTranscript() {
        let state = MeetingReportsViewState(
            hasReport: true,
            hasTranscript: false,
            hasUnconfirmedSpeakers: false,
            usesExternalEndpoint: false,
            appleAvailability: .available
        )

        #expect(!state.canGenerate)
        #expect(state.availabilityMessage.map { english($0).contains("transcript") } == true)
        #expect(english(state.actionTitle) == "Regenerate")
    }

    @Test("unconfirmed speakers are a non-blocking warning")
    func unconfirmedSpeakers() {
        let state = MeetingReportsViewState(
            hasReport: false,
            hasTranscript: true,
            hasUnconfirmedSpeakers: true,
            usesExternalEndpoint: false,
            appleAvailability: .available
        )

        #expect(state.canGenerate)
        #expect(state.speakerHint.map { english($0).contains("unconfirmed") } == true)
    }

    @Test("copy and share always use the selected old version")
    func selectedVersionPayload() {
        let newest = report("NEW", createdAt: 2)
        let old = report("OLD", createdAt: 1)
        var presentation = MeetingReportsPresentation(reports: [newest, old])
        presentation.select(old.runID)

        #expect(MeetingReportsViewState.copyText(for: presentation.shownReport) == "OLD")
        #expect(MeetingReportsViewState.sharePayload(for: presentation.shownReport)?.text == "OLD")
    }

    private func report(
        _ markdown: String,
        createdAt: TimeInterval
    ) -> StoredTemplateResult {
        StoredTemplateResult(
            runID: RunID(),
            result: TemplateResult(
                markdown: markdown,
                template: .meetingMinutes,
                engine: EngineDescriptor(name: "fixture", version: "1"),
                revisionID: RevisionID(),
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        )
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }
}
