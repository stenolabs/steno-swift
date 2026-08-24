import Testing
@testable import steno_macos

@Suite("Mac toolbar presentation")
struct MacToolbarPresentationTests {
    @Test("semantic toolbar item identifiers are unique")
    func itemIdentifiersAreUnique() {
        let identifiers = MacToolbarItemID.allCases.map(\.rawValue)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(Set(MacToolbarID.allCases.map(\.rawValue)).count == MacToolbarID.allCases.count)
    }

    @Test("toolbar has one import surface and no settings item")
    func consolidatesImportsAndOmitsSettings() {
        #expect(MacToolbarPresentation.importSurfaceCount == 1)
        #expect(!MacToolbarItemID.allCases.map(\.rawValue).contains("settings"))
    }

    @Test("essential actions are visible by default in their context")
    func exposesEssentialDefaults() {
        #expect(MacToolbarPresentation.showsByDefault(.recording, in: .main))
        #expect(MacToolbarPresentation.showsByDefault(.newMeeting, in: .main))
        #expect(MacToolbarPresentation.showsByDefault(.importMeeting, in: .main))
        #expect(MacToolbarPresentation.showsByDefault(.inspector, in: .meetingDetail))
        #expect(!MacToolbarPresentation.showsByDefault(.microphoneSelection, in: .main))
        #expect(!MacToolbarPresentation.showsByDefault(.recordingNotes, in: .recording))
    }
}
