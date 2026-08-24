import StenoDemo
import SwiftUI

struct DemoDataConfirmation {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let confirmationAction: LocalizedStringResource
}

struct DemoDataItemPresentation {
    let title: LocalizedStringResource
    let stateTitle: LocalizedStringResource
    let detail: LocalizedStringResource
    let symbolName: String

    init(itemID: String, state: DemoLibraryItemState) {
        title = DemoDataPresentation.itemTitle(for: itemID)
        switch state {
        case .missing:
            stateTitle = DemoDataPresentation.itemMissingTitle
            detail = DemoDataPresentation.itemMissingDetail
            symbolName = "arrow.down.circle"
        case .installed:
            stateTitle = DemoDataPresentation.itemInstalledTitle
            detail = DemoDataPresentation.itemInstalledDetail
            symbolName = "checkmark.circle"
        case .modified:
            stateTitle = DemoDataPresentation.itemModifiedTitle
            detail = DemoDataPresentation.itemModifiedDetail
            symbolName = "pencil.circle"
        case .outdated(let installedVersion):
            stateTitle = DemoDataPresentation.itemOutdatedTitle
            detail = DemoDataPresentation.itemOutdatedDetail(
                installedVersion: installedVersion
            )
            symbolName = "arrow.triangle.2.circlepath"
        case .conflictingMeeting:
            stateTitle = DemoDataPresentation.itemConflictTitle
            detail = DemoDataPresentation.itemConflictDetail
            symbolName = "exclamationmark.triangle"
        }
    }
}

struct DemoDataStatusPresentation {
    let summary: LocalizedStringResource
    let symbolName: String
    let isAttention: Bool
    let isConflict: Bool
}

struct DemoDataLifecycleEntry {
    enum Kind: Hashable {
        case retained
        case uncertain
        case retryable
    }

    let kind: Kind
    let itemIDs: [String]
    let summary: LocalizedStringResource
    let symbolName: String
}

enum DemoDataActionPolicy {
    struct Actions: Equatable {
        let canInstall: Bool
        let canReplace: Bool
        let canRemove: Bool
    }

    static func actions(for status: DemoLibraryStatus?) -> Actions {
        guard let status else {
            return Actions(
                canInstall: false,
                canReplace: false,
                canRemove: false
            )
        }
        let states = status.items.map(\.state)
        let hasConflict = states.contains(.conflictingMeeting)
        let hasMissing = states.contains(.missing)
        let hasOutdated = states.contains { state in
            if case .outdated = state { return true }
            return false
        }
        let hasModifiedOrOutdated = states.contains { state in
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
        return Actions(
            // `install()` lehnt vorhandene, ältere Datensätze ab. In diesem
            // Mischzustand ist nur das vollständige Ersetzen sicher.
            canInstall: hasMissing && !hasConflict && !hasOutdated,
            canReplace: hasModifiedOrOutdated && !hasConflict,
            canRemove: hasOwnedMeeting
        )
    }
}

struct DemoDataPresentationState: Equatable {
    struct StatusToken: Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private(set) var status: DemoLibraryStatus?
    private(set) var statusError: String?
    private(set) var isChecking = false
    private(set) var lifecycleError: String?
    private(set) var lifecycleResult: DemoLifecycleResult?

    init(
        lifecycleError: String? = nil,
        lifecycleResult: DemoLifecycleResult? = nil
    ) {
        self.lifecycleError = lifecycleError
        self.lifecycleResult = lifecycleResult
    }

    var currentStatusToken: StatusToken {
        StatusToken(generation: generation)
    }

    mutating func beginStatusCheck() -> StatusToken {
        // Ein alter Befund darf während und nach einem fehlgeschlagenen
        // Abgleich nicht weiter als aktueller Bestand erscheinen.
        status = nil
        isChecking = true
        statusError = nil
        return currentStatusToken
    }

    @discardableResult
    mutating func invalidateStatus() -> StatusToken {
        generation &+= 1
        status = nil
        statusError = nil
        isChecking = false
        return currentStatusToken
    }

    @discardableResult
    mutating func publish(
        _ status: DemoLibraryStatus,
        for token: StatusToken
    ) -> Bool {
        guard token == currentStatusToken else { return false }
        self.status = status
        statusError = nil
        isChecking = false
        return true
    }

    @discardableResult
    mutating func publishStatusFailure(
        _ message: String,
        for token: StatusToken
    ) -> Bool {
        guard token == currentStatusToken else { return false }
        status = nil
        statusError = message
        isChecking = false
        return true
    }

    mutating func beginLifecycleOperation() {
        lifecycleError = nil
        lifecycleResult = nil
    }

    mutating func publishLifecycleResult(_ result: DemoLifecycleResult?) {
        lifecycleResult = result
    }

    mutating func publishLifecycleError(_ message: String) {
        lifecycleError = message
    }
}

enum DemoDataPresentation {
    static let tabTitle = LocalizedStringResource("demo.data.tab.title", defaultValue: "Demo Data")
    static let summaryTitle = LocalizedStringResource("demo.data.summary.title", defaultValue: "3 local synthetic meetings")
    static let noNetwork = LocalizedStringResource("demo.data.summary.network", defaultValue: "No network")
    static let noModels = LocalizedStringResource("demo.data.summary.models", defaultValue: "No models")
    static let statusTitle = LocalizedStringResource("demo.data.status.title", defaultValue: "Status")
    static let attributionTitle = LocalizedStringResource("demo.data.attribution.title", defaultValue: "Attribution")
    static let badgeLabel = LocalizedStringResource("demo.badge.label", defaultValue: "Demo")
    static let badgeAccessibilityLabel = LocalizedStringResource("demo.badge.accessibility.label", defaultValue: "Synthetic demo meeting")
    static let voiceEvidenceExplanation = LocalizedStringResource("demo.review.voice-evidence.explanation", defaultValue: "Demo audio cannot create or change real voice profiles. You can leave a speaker generic.")
    static let leaveGenericAction = LocalizedStringResource("demo.review.leave-generic.action", defaultValue: "Leave generic")
    static let keepEditedMeetingsAction = LocalizedStringResource("demo.data.replace.keep-edited.action", defaultValue: "Keep edited meetings")
    static let replaceAllDemoDataAction = LocalizedStringResource("demo.data.replace-all.action", defaultValue: "Replace all demo data")
    static let installAction = LocalizedStringResource("demo.data.install.action", defaultValue: "Install demo meetings")
    static let removeAction = LocalizedStringResource("demo.data.remove.action", defaultValue: "Remove demo data")
    static let replaceAction = LocalizedStringResource("demo.data.replace.action", defaultValue: "Replace demo data")
    static let checkingStatus = LocalizedStringResource("demo.data.status.checking", defaultValue: "Checking demo data")
    static let unavailableStatus = LocalizedStringResource("demo.data.status.unavailable", defaultValue: "Open a library to manage demo data.")
    static let processingStatus = LocalizedStringResource("demo.data.status.processing", defaultValue: "Updating demo data")
    static let operationFailedMessage = LocalizedStringResource("demo.data.operation.failed", defaultValue: "Demo data could not be updated. Check the status below and try again.")
    static let statusCheckFailedMessage = LocalizedStringResource("demo.data.status.failed", defaultValue: "Demo data could not be checked. Try again from this pane.")
    static let retryStatusAction = LocalizedStringResource("demo.data.status.retry.action", defaultValue: "Check again")
    static let statusUnavailable = LocalizedStringResource("demo.data.status.unavailable-result", defaultValue: "Demo data status is unavailable. Try again from this pane.")
    static let languageChangeLocked = LocalizedStringResource("demo.data.language-change.locked", defaultValue: "The transcription language cannot change while demo data is being updated.")
    static let replacementTitle = LocalizedStringResource("demo.data.replace.title", defaultValue: "Replace demo data?")
    static let replacementMessage = LocalizedStringResource("demo.data.replace.message", defaultValue: "Replace unedited meetings with the bundled version. Choose whether edited meetings stay in the library or also move to Trash.")
    static let attribution = LocalizedStringResource("demo.data.attribution.copy", defaultValue: "The three recordings are pre-rendered from fictional German text. Piper and its voice repository are MIT-licensed; the voice model card names MLS as CC BY 4.0. Full attribution is bundled with the dataset.")
    static let itemMissingTitle = LocalizedStringResource("demo.data.item.missing.title", defaultValue: "Not installed")
    static let itemMissingDetail = LocalizedStringResource("demo.data.item.missing.detail", defaultValue: "Install demo meetings to add this local synthetic meeting.")
    static let itemInstalledTitle = LocalizedStringResource("demo.data.item.installed.title", defaultValue: "Installed")
    static let itemInstalledDetail = LocalizedStringResource("demo.data.item.installed.detail", defaultValue: "Matches the bundled demo data.")
    static let itemModifiedTitle = LocalizedStringResource("demo.data.item.modified.title", defaultValue: "Edited")
    static let itemModifiedDetail = LocalizedStringResource("demo.data.item.modified.detail", defaultValue: "Your changes stay unless you choose Replace all demo data.")
    static let itemOutdatedTitle = LocalizedStringResource("demo.data.item.outdated.title", defaultValue: "Update available")
    static let itemConflictTitle = LocalizedStringResource("demo.data.item.conflict.title", defaultValue: "Conflicting meeting")
    static let itemConflictDetail = LocalizedStringResource("demo.data.item.conflict.detail", defaultValue: "This meeting is not owned as demo data. Steno will not change it.")
    static let allReviewed = LocalizedStringResource("demo.review.progress.all-reviewed", defaultValue: "all reviewed")

    static let installationConfirmation = DemoDataConfirmation(
        title: LocalizedStringResource("demo.data.install.confirmation.title", defaultValue: "Install demo meetings?"),
        message: LocalizedStringResource("demo.data.install.confirmation.message", defaultValue: "Steno installs three local synthetic meetings for screenshots and benchmarks. No model or network connection is used."),
        confirmationAction: installAction
    )

    static let removalConfirmation = DemoDataConfirmation(
        title: LocalizedStringResource("demo.data.remove.confirmation.title", defaultValue: "Remove demo data?"),
        message: LocalizedStringResource("demo.data.remove.confirmation.message", defaultValue: "Marked demo meetings, including your changes, move to Trash. Other meetings stay in the library."),
        confirmationAction: removeAction
    )

    static func statusPresentation(
        for status: DemoLibraryStatus
    ) -> DemoDataStatusPresentation {
        let installed = status.items.filter { $0.state == .installed }.count
        let modified = status.items.filter { $0.state == .modified }.count
        let outdated = status.items.filter {
            if case .outdated = $0.state { return true }
            return false
        }.count
        let conflicts = status.items.filter { $0.state == .conflictingMeeting }.count
        if conflicts > 0 {
            return DemoDataStatusPresentation(
                summary: LocalizedStringResource(
                    "demo.data.status.conflict",
                    defaultValue: "A different meeting conflicts with demo data."
                ),
                symbolName: "exclamationmark.triangle",
                isAttention: true,
                isConflict: true
            )
        }
        if modified > 0 || outdated > 0 {
            return DemoDataStatusPresentation(
                summary: LocalizedStringResource(
                    "demo.data.status.attention",
                    defaultValue: "Some demo meetings need attention before replacement."
                ),
                symbolName: "exclamationmark.circle",
                isAttention: true,
                isConflict: false
            )
        }
        if !status.items.isEmpty, installed == status.items.count {
            return DemoDataStatusPresentation(
                summary: LocalizedStringResource(
                    "demo.data.status.installed",
                    defaultValue: "All three demo meetings are installed."
                ),
                symbolName: "checkmark.circle",
                isAttention: false,
                isConflict: false
            )
        }
        return DemoDataStatusPresentation(
            summary: LocalizedStringResource(
                "demo.data.status.not-installed",
                defaultValue: "Demo meetings are not installed."
            ),
            symbolName: "arrow.down.circle",
            isAttention: false,
            isConflict: false
        )
    }

    static func lifecycleEntries(
        for result: DemoLifecycleResult
    ) -> [DemoDataLifecycleEntry] {
        let uncertain = uniqueItemIDs(result.uncertainItems)
        let uncertainSet = Set(uncertain)
        let retained = uniqueItemIDs(result.retainedItems).filter {
            !uncertainSet.contains($0)
        }
        let excludedFromRetry = uncertainSet.union(Set(retained))
        let retryable = uniqueItemIDs(result.remainingItems).filter {
            !excludedFromRetry.contains($0)
        }
        var entries: [DemoDataLifecycleEntry] = []
        if !retained.isEmpty {
            entries.append(DemoDataLifecycleEntry(
                kind: .retained,
                itemIDs: retained,
                summary: LocalizedStringResource(
                    "demo.data.status.retained-result",
                    defaultValue: "Some meetings were kept and will not be retried."
                ),
                symbolName: "hand.raised"
            ))
        }
        if !uncertain.isEmpty {
            entries.append(DemoDataLifecycleEntry(
                kind: .uncertain,
                itemIDs: uncertain,
                summary: LocalizedStringResource(
                    "demo.data.status.uncertain-result",
                    defaultValue: "The outcome for some demo meetings is unknown. Check the status before taking another action."
                ),
                symbolName: "questionmark.circle"
            ))
        }
        if !retryable.isEmpty {
            entries.append(DemoDataLifecycleEntry(
                kind: .retryable,
                itemIDs: retryable,
                summary: LocalizedStringResource(
                    "demo.data.status.retryable-result",
                    defaultValue: "Some demo meetings were not processed. You can try the action again."
                ),
                symbolName: "arrow.clockwise"
            ))
        }
        return entries
    }

    private static func uniqueItemIDs(_ itemIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return itemIDs.filter { seen.insert($0).inserted }
    }

    static func itemTitle(for itemID: String) -> LocalizedStringResource {
        switch itemID {
        case "projektauftakt":
            LocalizedStringResource(
                "demo.data.item.projektauftakt.title",
                defaultValue: "Project kickoff"
            )
        case "wochenrunde":
            LocalizedStringResource(
                "demo.data.item.wochenrunde.title",
                defaultValue: "Weekly round"
            )
        case "produktinterview":
            LocalizedStringResource(
                "demo.data.item.produktinterview.title",
                defaultValue: "Product interview"
            )
        default:
            LocalizedStringResource(
                "demo.data.item.unknown.title",
                defaultValue: "Demo meeting"
            )
        }
    }

    static func itemOutdatedDetail(
        installedVersion: String
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            "demo.data.item.outdated.detail",
            defaultValue: "Installed demo data is version \(installedVersion)."
        )
    }

    static func reviewProgressTitle(
        _ progress: SpeakerReviewPresentation.ReviewProgress
    ) -> LocalizedStringResource {
        guard progress.reviewed != progress.total else { return allReviewed }
        return LocalizedStringResource(
            "demo.review.progress.reviewed-count",
            defaultValue: "\(progress.reviewed) of \(progress.total) reviewed"
        )
    }
}

struct DemoDataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showInstallConfirmation = false
    @State private var showReplacementConfirmation = false
    @State private var showRemovalConfirmation = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Steno.Space.s) {
                    Label(DemoDataPresentation.summaryTitle, systemImage: "checkmark.shield")
                        .font(.headline)
                    HStack(spacing: Steno.Space.m) {
                        Label(DemoDataPresentation.noNetwork, systemImage: "network.slash")
                        Label(DemoDataPresentation.noModels, systemImage: "cpu")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, Steno.Space.xs)
            }

            Section(DemoDataPresentation.statusTitle) {
                statusContent
                if let status = model.demoDataStatus {
                    ForEach(status.items, id: \.itemID) { item in
                        itemStatusRow(item)
                    }
                }
                if let result = model.demoDataLastResult {
                    ForEach(
                        DemoDataPresentation.lifecycleEntries(for: result),
                        id: \.kind
                    ) { entry in
                        Label(entry.summary, systemImage: entry.symbolName)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.demoDataError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Steno.Colors.error)
                }
            }

            Section {
                Button(DemoDataPresentation.installAction) {
                    showInstallConfirmation = true
                }
                .disabled(!actions.canInstall)
                Button(DemoDataPresentation.replaceAction) {
                    showReplacementConfirmation = true
                }
                .disabled(!actions.canReplace)
                Button(DemoDataPresentation.removeAction, role: .destructive) {
                    showRemovalConfirmation = true
                }
                .disabled(!actions.canRemove)
            }

            Section(DemoDataPresentation.attributionTitle) {
                Text(DemoDataPresentation.attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 390)
        .task { await model.refreshDemoDataStatus() }
        .confirmationDialog(
            DemoDataPresentation.installationConfirmation.title,
            isPresented: $showInstallConfirmation
        ) {
            Button(DemoDataPresentation.installationConfirmation.confirmationAction) {
                Task { await model.installDemoData() }
            }
        } message: {
            Text(DemoDataPresentation.installationConfirmation.message)
        }
        .confirmationDialog(
            DemoDataPresentation.replacementTitle,
            isPresented: $showReplacementConfirmation
        ) {
            Button(DemoDataPresentation.keepEditedMeetingsAction) {
                Task { await model.replaceDemoData(policy: .keepModifiedMeetings) }
            }
            Button(DemoDataPresentation.replaceAllDemoDataAction, role: .destructive) {
                Task { await model.replaceDemoData(policy: .replaceModifiedMeetings) }
            }
        } message: {
            Text(DemoDataPresentation.replacementMessage)
        }
        .confirmationDialog(
            DemoDataPresentation.removalConfirmation.title,
            isPresented: $showRemovalConfirmation
        ) {
            Button(DemoDataPresentation.removalConfirmation.confirmationAction, role: .destructive) {
                Task { await model.removeDemoData() }
            }
        } message: {
            Text(DemoDataPresentation.removalConfirmation.message)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if model.isManagingDemoData {
            HStack(spacing: Steno.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text(DemoDataPresentation.processingStatus)
            }
        } else if let error = model.demoDataStatusError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Steno.Colors.error)
            Button(DemoDataPresentation.retryStatusAction) {
                Task { await model.refreshDemoDataStatus() }
            }
        } else if model.isCheckingDemoDataStatus {
            HStack(spacing: Steno.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text(DemoDataPresentation.checkingStatus)
            }
        } else if let status = model.demoDataStatus {
            let presentation = DemoDataPresentation.statusPresentation(for: status)
            Label(presentation.summary, systemImage: presentation.symbolName)
                .foregroundStyle(
                    presentation.isConflict
                        ? AnyShapeStyle(Steno.Colors.error)
                        : AnyShapeStyle(.primary)
                )
        } else if model.runtime == nil {
            Label(DemoDataPresentation.unavailableStatus, systemImage: "externaldrive.badge.xmark")
        } else {
            Label(DemoDataPresentation.statusUnavailable, systemImage: "exclamationmark.triangle")
        }
    }

    private var actions: DemoDataActionPolicy.Actions {
        DemoDataActionPolicy.actions(for: model.demoDataStatus)
    }

    private func itemStatusRow(_ item: DemoLibraryItemStatus) -> some View {
        let presentation = DemoDataItemPresentation(
            itemID: item.itemID,
            state: item.state
        )
        return HStack(alignment: .top, spacing: Steno.Space.s) {
            Image(systemName: presentation.symbolName)
                .foregroundStyle(
                    item.state == .conflictingMeeting
                        ? AnyShapeStyle(Steno.Colors.error)
                        : AnyShapeStyle(.secondary)
                )
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Text(presentation.title)
                Text(presentation.stateTitle)
                    .font(.caption.weight(.medium))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
