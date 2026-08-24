import Foundation
import StenoDemo
import SwiftUI

/// Copy and state mapping for the local synthetic meeting library.
///
/// This stays separate from the SwiftUI form so the same lifecycle facts are
/// testable on iPhone and iPad without opening a user's library.
enum DemoDataPresentation {
    struct Confirmation {
        let title: LocalizedStringResource
        let message: LocalizedStringResource
        let buttons: [ConfirmationButton]
    }

    enum LifecycleCommand: Equatable {
        case install
        case replace(replacingEditedMeetings: Bool)
        case remove
    }

    enum ConfirmationButtonID: Hashable {
        case install
        case keepEditedMeetings
        case replaceAllDemoData
        case remove
        case cancel
    }

    struct ConfirmationButton: Identifiable {
        let id: ConfirmationButtonID
        let title: LocalizedStringResource
        let role: ConfirmationButtonRole
    }

    enum ConfirmationButtonRole: Equatable {
        case regular
        case destructive
        case cancel
    }

    struct ItemPresentation: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let status: LocalizedStringResource
        let hint: LocalizedStringResource?
        let systemImage: String
    }

    static let title: LocalizedStringResource = "Demo Data"
    static let toolTitle: LocalizedStringResource = "Demo Data"
    static let badge: LocalizedStringResource = "Demo"
    static let badgeAccessibilityLabel: LocalizedStringResource = "Synthetic demo meeting"
    static let summaryTitle: LocalizedStringResource = "3 local synthetic meetings"
    static let noNetwork: LocalizedStringResource = "No network"
    static let noModels: LocalizedStringResource = "No models"
    static let provenanceDescription: LocalizedStringResource = "Built-in sample meetings for screenshots and repeatable local checks."
    static let statusTitle: LocalizedStringResource = "Installation status"
    static let attributionTitle: LocalizedStringResource = "Attribution"
    static let attributionDescription: LocalizedStringResource = "Synthetic German speech and meeting material are bundled with Steno. Piper and the voice repository are MIT-licensed; the MLS training data is CC BY 4.0."
    static let installAction: LocalizedStringResource = "Install demo meetings"
    static let replaceAction: LocalizedStringResource = "Replace demo data"
    static let removeAction: LocalizedStringResource = "Remove demo data"
    static let keepEditedMeetings: LocalizedStringResource = "Keep edited meetings"
    static let replaceAllDemoData: LocalizedStringResource = "Replace all demo data"
    static let cancelAction: LocalizedStringResource = "Cancel"
    static let closeAction: LocalizedStringResource = "OK"
    static let partialResultTitle: LocalizedStringResource = "Some demo data needs attention"
    static let completedResultTitle: LocalizedStringResource = "Demo data updated"
    static let mutationErrorTitle: LocalizedStringResource = "Demo data update needs attention."
    static let statusErrorTitle: LocalizedStringResource = "Demo data status could not be checked."
    static let reconciliationErrorTitle: LocalizedStringResource = "Demo library could not be refreshed."
    static let lifecycleFailureDetail: LocalizedStringResource = "Demo data may have changed. Check its status, then try again if needed."
    static let statusFailureDetail: LocalizedStringResource = "The current demo data status is unavailable. Check again."
    static let meetingReconciliationFailureDetail: LocalizedStringResource = "The meeting list could not be refreshed. Check again."
    static let folderReconciliationFailureDetail: LocalizedStringResource = "The folder list could not be refreshed. Meetings are up to date."
    static let reconciliationStaleError: LocalizedStringResource = "The library changed before demo data could be refreshed."
    static let installConfirmation = Confirmation(
        title: "Install demo meetings?",
        message: "Install three local synthetic demo meetings. No model or network connection is used.",
        buttons: [
            ConfirmationButton(id: .install, title: installAction, role: .regular),
            ConfirmationButton(id: .cancel, title: cancelAction, role: .cancel),
        ]
    )
    static let replacementConfirmation = Confirmation(
        title: "Replace demo data?",
        message: "Keeping edited meetings leaves their changes in place. Replace all demo data moves edited demo meetings and their user changes to Trash.",
        buttons: [
            ConfirmationButton(
                id: .keepEditedMeetings,
                title: keepEditedMeetings,
                role: .regular
            ),
            ConfirmationButton(
                id: .replaceAllDemoData,
                title: replaceAllDemoData,
                role: .destructive
            ),
            ConfirmationButton(id: .cancel, title: cancelAction, role: .cancel),
        ]
    )
    static let removeConfirmation = Confirmation(
        title: "Remove demo data?",
        message: "Marked demo meetings and their user changes are moved to Trash.",
        buttons: [
            ConfirmationButton(id: .remove, title: removeAction, role: .destructive),
            ConfirmationButton(id: .cancel, title: cancelAction, role: .cancel),
        ]
    )

    static func statusText(_ status: DemoLibraryStatus?) -> LocalizedStringResource {
        guard let status else { return "Not checked yet" }
        let states = status.items.map(\.state)
        if states.contains(.conflictingMeeting) {
            return "Demo data needs attention"
        }
        let owned = states.filter { $0 != .missing }
        if owned.isEmpty { return "No demo meetings are installed" }
        if states.allSatisfy({ $0 == .installed }) {
            return "All demo meetings are installed"
        }
        if states.contains(.missing) { return "Some demo meetings are installed" }
        if states.contains(.modified) || states.contains(where: { state in
            if case .outdated = state { return true }
            return false
        }) {
            return "Demo meetings are installed with changes"
        }
        return "Some demo meetings are installed"
    }

    static func actionPolicy(for status: DemoLibraryStatus?) -> DemoDataActionPolicy {
        guard let status else { return .none }
        let states = status.items.map(\.state)
        let hasConflict = states.contains(.conflictingMeeting)
        let hasMissing = states.contains(.missing)
        let hasOutdatedMeeting = states.contains { state in
            if case .outdated = state { return true }
            return false
        }
        let hasReplaceableMeeting = states.contains { state in
            switch state {
            case .modified, .outdated:
                true
            case .missing, .installed, .conflictingMeeting:
                false
            }
        }
        let hasOwnedMeeting = states.contains { state in
            switch state {
            case .installed, .modified, .outdated:
                true
            case .missing, .conflictingMeeting:
                false
            }
        }
        return DemoDataActionPolicy(
            install: hasMissing && !hasConflict && !hasOutdatedMeeting,
            replace: hasReplaceableMeeting && !hasConflict,
            remove: hasOwnedMeeting
        )
    }

    static func lifecycleCommand(
        for buttonID: ConfirmationButtonID
    ) -> LifecycleCommand? {
        switch buttonID {
        case .install:
            .install
        case .keepEditedMeetings:
            .replace(replacingEditedMeetings: false)
        case .replaceAllDemoData:
            .replace(replacingEditedMeetings: true)
        case .remove:
            .remove
        case .cancel:
            nil
        }
    }

    static func itemPresentations(
        for status: DemoLibraryStatus?
    ) -> [ItemPresentation] {
        guard let status else { return [] }
        return manifestItemIDs.map { itemID in
            let state = status.items.first { $0.itemID == itemID }?.state ?? .missing
            return itemPresentation(itemID: itemID, state: state)
        }
    }

    static func itemPresentation(_ item: DemoLibraryItemStatus) -> ItemPresentation {
        itemPresentation(itemID: item.itemID, state: item.state)
    }

    private static func itemPresentation(
        itemID: String,
        state: DemoLibraryItemState
    ) -> ItemPresentation {
        let title = itemTitle(for: itemID)
        switch state {
        case .missing:
            return ItemPresentation(
                id: itemID,
                title: title,
                status: "Not installed",
                hint: "Install demo meetings to add this local sample.",
                systemImage: "arrow.down.circle"
            )
        case .installed:
            return ItemPresentation(
                id: itemID,
                title: title,
                status: "Installed",
                hint: nil,
                systemImage: "checkmark.circle"
            )
        case .modified:
            return ItemPresentation(
                id: itemID,
                title: title,
                status: "Edited",
                hint: "Your changes are kept unless you choose Replace all demo data.",
                systemImage: "pencil.circle"
            )
        case .outdated(let installedVersion):
            return ItemPresentation(
                id: itemID,
                title: title,
                status: "Update available",
                hint: installedVersionHint(installedVersion),
                systemImage: "arrow.triangle.2.circlepath"
            )
        case .conflictingMeeting:
            return ItemPresentation(
                id: itemID,
                title: title,
                status: "Needs attention",
                hint: "A meeting with this ID is not demo data. It cannot be installed or replaced as demo data.",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    static func resultText(
        _ result: DemoLifecycleResult,
        locale: Locale = .current
    ) -> String {
        var parts: [String] = []
        if !result.completedItems.isEmpty {
            parts.append(localized(completedItemCount(result.completedItems.count), locale: locale))
        }
        if !result.retainedItems.isEmpty {
            parts.append(localized(retainedItemsKept, locale: locale))
        }
        if !result.uncertainItems.isEmpty {
            parts.append(localized(uncertainItemsNeedStatusCheck, locale: locale))
        }
        if !retryableItems(in: result).isEmpty {
            parts.append(localized(retryRemainingMeetings, locale: locale))
        }
        return parts.joined(separator: " ")
    }

    static func hasPartialResult(_ result: DemoLifecycleResult) -> Bool {
        !result.uncertainItems.isEmpty
            || !retryableItems(in: result).isEmpty
    }

    private static func completedItemCount(_ count: Int) -> LocalizedStringResource {
        "Completed: \(count)"
    }

    private static let retainedItemsKept: LocalizedStringResource = "Kept edited demo meetings."
    private static let uncertainItemsNeedStatusCheck: LocalizedStringResource = "The outcome of some demo meetings is unknown. Check their status."
    private static let retryRemainingMeetings: LocalizedStringResource = "Retry to finish the remaining demo meetings."

    private static func retryableItems(in result: DemoLifecycleResult) -> [String] {
        let excluded = Set(result.retainedItems).union(result.uncertainItems)
        return result.remainingItems.filter { !excluded.contains($0) }
    }

    private static func localized(
        _ resource: LocalizedStringResource,
        locale: Locale
    ) -> String {
        var localizedResource = resource
        localizedResource.locale = locale
        return String(localized: localizedResource)
    }

    private static let manifestItemIDs = [
        "projektauftakt",
        "wochenrunde",
        "produktinterview",
    ]

    private static func itemTitle(for itemID: String) -> LocalizedStringResource {
        switch itemID {
        case "projektauftakt": "Project kickoff"
        case "wochenrunde": "Weekly round"
        case "produktinterview": "Product interview"
        default: "Demo meeting"
        }
    }

    private static func installedVersionHint(_ version: String) -> LocalizedStringResource {
        "Installed version \(version) can be updated."
    }
}

struct DemoDataActionPolicy: Equatable {
    let install: Bool
    let replace: Bool
    let remove: Bool

    static let none = Self(install: false, replace: false, remove: false)
    static let all = Self(install: true, replace: true, remove: true)
}

enum DemoDataOperation: Equatable {
    case checkingStatus
    case installing
    case replacing
    case removing

    var title: LocalizedStringResource {
        switch self {
        case .checkingStatus: "Checking demo data"
        case .installing: "Installing demo meetings"
        case .replacing: "Replacing demo data"
        case .removing: "Removing demo data"
        }
    }
}
