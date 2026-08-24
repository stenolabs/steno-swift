import Foundation
import StenoDomain
import StenoPipeline
import Testing
@testable import Steno

@Suite("Pipeline startup warning presentation")
struct PipelineStartupWarningPresentationTests {
    @Test("startup presentation uses localized resources for every visible category")
    func typedPresentationCopy() {
        #expect(english(IOSStartupState.opening.title) == "Opening library")
        #expect(
            english(IOSStartupFailure.runtimeOpening("disk").title)
                == "The library could not be opened"
        )
        #expect(
            english(IOSLibraryIssue.meetings("index").retryTitle)
                == "Reload Meetings"
        )
        #expect(
            english(IOSLibraryIssue.folders("index").retryTitle)
                == "Reload Folders"
        )
        #expect(
            english(IOSActionNotice.draftCreation("write").title)
                == "Draft not created"
        )
    }

    @Test("warning stays generic and does not expose a meeting identifier")
    func warningDoesNotExposeMeetingDetails() throws {
        let meetingID = MeetingID(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let warning = PipelineStartupWarning.importedMeetingProcessing(
            meetingID: meetingID,
            issue: .invalidTransferState
        )

        let message = try #require(AppModel.pipelineStartupWarningMessage(for: [warning]))

        #expect(message == String(localized: "One imported meeting needs attention because its processing could not be resumed. Other meetings and recording remain available."))
        #expect(!message.contains(meetingID.description))
        #expect(AppModel.pipelineStartupWarningMessage(for: []) == nil)
    }

    @Test("unreconstructable media warning says the original remains stored")
    func orphanedMediaWarningIsExplicitAndPrivate() throws {
        let meetingID = MeetingID(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let fileName = "11111111-2222-3333-4444-555555555555.caf"
        let warning = PipelineStartupWarning.orphanedMedia(
            meetingID: meetingID,
            fileName: fileName
        )

        let message = try #require(AppModel.pipelineStartupWarningMessage(for: [warning]))

        #expect(message == String(localized: "Steno found an original recording file that could not be safely registered. The file remains stored and needs attention."))
        #expect(!message.contains(meetingID.description))
        #expect(!message.contains(fileName))
    }

    @Test("warning, library issue, and action notice clear independently")
    @MainActor
    func independentCategoryClearing() {
        let model = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in throw PresentationTestError.runtime }
        )
        model.reportStartupWarning(.captureRecovery("capture"))
        model.reportLibraryIssue(.meetings("meetings"))
        model.reportFolderAvailabilityFailure("folders")
        model.reportDraftCreationFailure(PresentationTestError.draft)

        model.clearStartupWarnings()

        #expect(model.startupWarnings.isEmpty)
        #expect(
            model.libraryIssues
                == [.meetings("meetings"), .folders("folders")]
        )
        #expect(model.actionNotice == .draftCreation("draft"))

        model.clearActionNotice()

        #expect(
            model.libraryIssues
                == [.meetings("meetings"), .folders("folders")]
        )
        #expect(model.actionNotice == nil)
    }

    @Test("every former startup failure writer has a typed destination")
    @MainActor
    func exhaustiveWriterMapping() {
        let model = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in throw PresentationTestError.runtime }
        )

        model.reportLibraryIssue(.meetings("meetings"))
        #expect(model.libraryIssue == .meetings("meetings"))
        model.reportFolderAvailabilityFailure("folders")
        #expect(
            model.libraryIssues
                == [.meetings("meetings"), .folders("folders")]
        )

        model.reportStartupWarning(.captureRecovery("capture"))
        model.reportStartupWarning(.missingModelRequeue("model"))
        model.reportStartupWarning(.pipeline("pipeline"))
        #expect(
            model.startupWarnings
                == [.captureRecovery("capture"), .missingModelRequeue("model"), .pipeline("pipeline")]
        )

        model.reportActionNotice(.appleRetryQueue("apple"))
        #expect(model.actionNotice == .appleRetryQueue("apple"))
        model.reportDraftCreationFailure(PresentationTestError.draft)
        #expect(model.actionNotice == .draftCreation("draft"))
        model.reportFolderFailure("Folder mutation", PresentationTestError.folder)
        #expect(model.actionNotice == .folderMutation("Folder mutation (folder)"))
        model.reportFolderStateReloaded()
        #expect(
            model.actionNotice
                == .folderStateReload("The folder no longer exists and the current library state was reloaded.")
        )
        model.reportFolderPartialRecoveryFailure(
            PresentationTestError.recovery,
            reloadResult: .published
        )
        #expect(model.actionNotice == .partialRecovery(
            "The current folder index was reloaded. The folder could not be deleted and some meeting assignments could not be restored. recovery"
        ))
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var englishResource = resource
        englishResource.locale = Locale(identifier: "en")
        return String(localized: englishResource)
    }
}

private enum PresentationTestError: LocalizedError {
    case runtime
    case draft
    case folder
    case recovery

    var errorDescription: String? {
        switch self {
        case .runtime: "runtime"
        case .draft: "draft"
        case .folder: "folder"
        case .recovery: "recovery"
        }
    }
}
