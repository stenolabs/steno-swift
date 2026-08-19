import Foundation
import StenoDomain
import SwiftUI

/// Persistiert ausschließlich bewusste Disclosure-Aktionen.
/// Temporäre Such- und Reveal-Zustände werden von der View getrennt berechnet.
@MainActor
struct IOSFolderDisclosureStore {
    private static let key = "steno.ios.sidebar.expandedFolders"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Set<FolderID> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap { value in
            UUID(uuidString: value).map(FolderID.init(rawValue:))
        })
    }

    @discardableResult
    func setExpanded(
        _ isExpanded: Bool,
        for folderID: FolderID
    ) -> Set<FolderID> {
        var folderIDs = load()
        if isExpanded {
            folderIDs.insert(folderID)
        } else {
            folderIDs.remove(folderID)
        }
        write(folderIDs)
        return folderIDs
    }

    @discardableResult
    func add(_ additions: Set<FolderID>) -> Set<FolderID> {
        var folderIDs = load()
        folderIDs.formUnion(additions)
        write(folderIDs)
        return folderIDs
    }

    @discardableResult
    func remove(_ folderID: FolderID) -> Set<FolderID> {
        var folderIDs = load()
        folderIDs.remove(folderID)
        write(folderIDs)
        return folderIDs
    }

    private func write(_ folderIDs: Set<FolderID>) {
        defaults.set(
            folderIDs.map(\.description).sorted(),
            forKey: Self.key
        )
    }
}

@MainActor
enum IOSSidebarRevealApplication {
    /// Schreibt die bestaetigte Elternkette zuerst und meldet die vorhandene
    /// Meetingroute erst danach als navigationsbereit.
    @discardableResult
    static func apply(
        _ request: IOSSidebarRevealRequest,
        presentation: IOSMeetingSidebarPresentation,
        disclosureStore: IOSFolderDisclosureStore,
        updateExpansion: (Set<FolderID>) -> Void,
        selectionReady: (IOSSidebarRevealRequest, SidebarItem) -> Void
    ) -> Bool {
        guard let reveal = presentation.navigationReveal(
            for: request.meetingID,
            persisted: []
        ) else { return false }
        let expanded = disclosureStore.add(reveal.expandedFolderIDs)
        updateExpansion(expanded)
        selectionReady(request, reveal.selection)
        return true
    }
}

/// Ein ruhiger Archivbaum fuer iPhone und iPad.
///
/// Ordner sind reine Disclosure-Zeilen. Nur Meetings und Werkzeuge tragen
/// Navigationswerte, damit `.meeting` die einzige Detailroute bleibt.
struct MeetingSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    let revealRequest: IOSSidebarRevealRequest?
    let onRevealApplied: (IOSSidebarRevealRequest, SidebarItem) -> Void

    @State private var query = ""
    @State private var persistedExpandedFolderIDs = IOSFolderDisclosureStore().load()
    @State private var folderNameOperation: FolderNameOperation?
    @State private var folderName = ""
    @State private var folderDeleteTarget: Folder?
    @State private var targetedFolderID: FolderID?
    @State private var isFoldersHeadingTargeted = false
    @State private var targetedUnfiledSectionID: String?

    private let disclosureStore = IOSFolderDisclosureStore()

    var body: some View {
        List(selection: $selection) {
            if let failure = model.startupFailure {
                Section("Library") {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.body)
                        .foregroundStyle(Steno.Colors.error)
                }
            }

            Section {
                foldersHeading
                ForEach(presentation.tree.folderNodes) { node in
                    rootFolder(node)
                }
            }

            if presentation.tree.folderNodes.isEmpty,
               presentation.tree.unfiledSections.isEmpty
            {
                Section {
                    Text(emptyMeetingMessage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }

            ForEach(presentation.tree.unfiledSections) { section in
                Section {
                    ForEach(section.meetings, id: \.id) { meeting in
                        meetingRow(meeting)
                    }
                } header: {
                    unfiledSectionHeader(section)
                }
            }

            Section("Tools") {
                NavigationLink(value: SidebarItem.recording) {
                    Label("Record", systemImage: "record.circle")
                }
                NavigationLink(value: SidebarItem.readiness) {
                    Label("Audio readiness", systemImage: "waveform")
                }
                NavigationLink(value: SidebarItem.languageModels) {
                    Label("Language models", systemImage: "brain")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Steno")
        .searchable(text: $query, prompt: "Search titles")
        .onChange(of: revealRequest, initial: true) { _, request in
            guard let request else { return }
            revealMeeting(request)
        }
        .alert(
            folderNameOperation?.title ?? "Folder",
            isPresented: folderNameOperationIsPresented
        ) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button(folderNameOperation?.actionTitle ?? "Save") {
                commitFolderNameOperation()
            }
            .disabled(normalizedFolderName.isEmpty)
        } message: {
            if let message = folderNameOperation?.message {
                Text(message)
            }
        }
        .confirmationDialog(
            folderDeleteTarget.flatMap {
                presentation.folderDeletionConfirmation(for: $0.id)?.title
            } ?? "Delete folder?",
            isPresented: folderDeleteIsPresented,
            titleVisibility: .visible,
            presenting: folderDeleteTarget
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                deleteFolder(folder)
            }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            if let confirmation = presentation.folderDeletionConfirmation(
                for: folder.id
            ) {
                Text(confirmation.message)
            }
        }
    }

    private var presentation: IOSMeetingSidebarPresentation {
        IOSMeetingSidebarPresentation(
            folders: model.folders,
            meetings: model.meetings,
            query: query
        )
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveExpandedFolderIDs: Set<FolderID> {
        presentation.effectiveExpandedFolderIDs(
            persisted: persistedExpandedFolderIDs
        )
    }

    private var emptyMeetingMessage: String {
        if isSearching {
            return "No meeting titles match \u{201c}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201d}."
        }
        return model.isReady ? "No recordings yet." : "Opening the library\u{2026}"
    }

    // MARK: - Folders

    private var foldersHeading: some View {
        let dropSurface = IOSSidebarNoFolderDropSurface.foldersHeading
        return HStack(spacing: Steno.Space.s) {
            Label("Folders", systemImage: "folder")
                .font(.headline)
            Spacer(minLength: Steno.Space.s)
            Button {
                beginCreatingFolder(parentFolderID: nil)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Steno.Colors.brand)
            .disabled(model.runtime == nil)
            .accessibilityLabel("Create folder")
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .selectionDisabled()
        .accessibilityIdentifier("meeting-sidebar-folders-heading")
        .accessibilityHint(dropSurface.accessibilityHint)
        .contextMenu {
            Button {
                beginCreatingFolder(parentFolderID: nil)
            } label: {
                Label("New Folder\u{2026}", systemImage: "folder.badge.plus")
            }
            .disabled(model.runtime == nil)
        }
        .dropDestination(for: IOSSidebarDragPayload.self) { payloads, _ in
            acceptDrop(payloads, onto: dropSurface)
        } isTargeted: { targeted in
            isFoldersHeadingTargeted = targeted
        }
        .listRowBackground(
            isFoldersHeadingTargeted
                ? Steno.Colors.brand.opacity(0.12)
                : Color.clear
        )
    }

    private func unfiledSectionHeader(
        _ section: MeetingSection
    ) -> some View {
        let dropSurface = IOSSidebarNoFolderDropSurface.unfiledSection(section.id)
        let isTargeted = targetedUnfiledSectionID == section.id
        return Text(section.title)
            .font(.caption)
            .foregroundStyle(isTargeted ? Steno.Colors.brand : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHint(dropSurface.accessibilityHint)
            .dropDestination(for: IOSSidebarDragPayload.self) { payloads, _ in
                acceptDrop(payloads, onto: dropSurface)
            } isTargeted: { targeted in
                if targeted {
                    targetedUnfiledSectionID = section.id
                } else if targetedUnfiledSectionID == section.id {
                    targetedUnfiledSectionID = nil
                }
            }
            .background(
                isTargeted ? Steno.Colors.brand.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    private func rootFolder(_ node: MeetingFolderNode) -> some View {
        DisclosureGroup(isExpanded: disclosureBinding(for: node.id)) {
            ForEach(node.children) { child in
                childFolder(child)
            }
            ForEach(node.meetings, id: \.id) { meeting in
                meetingRow(meeting)
            }
            if node.meetings.isEmpty, node.children.isEmpty {
                emptyFolderRow
            }
        } label: {
            folderLabel(node, font: .headline)
                .selectionDisabled()
        }
    }

    private func childFolder(_ node: MeetingFolderNode) -> some View {
        DisclosureGroup(isExpanded: disclosureBinding(for: node.id)) {
            ForEach(node.meetings, id: \.id) { meeting in
                meetingRow(meeting)
            }
            if node.meetings.isEmpty {
                emptyFolderRow
            }
        } label: {
            folderLabel(node, font: .body)
                .selectionDisabled()
        }
    }

    private func folderLabel(
        _ node: MeetingFolderNode,
        font: Font
    ) -> some View {
        let isTargeted = targetedFolderID == node.id
        return Label(node.folder.name, systemImage: "folder")
            .font(font)
            .foregroundStyle(isTargeted ? Steno.Colors.brand : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { folderMenu(node.folder) }
            .accessibilityIdentifier("meeting-sidebar-folder-\(node.id.description)")
            .accessibilityValue(
                "\(node.meetings.count) direct meetings, \(node.children.count) subfolders"
            )
            .draggable(IOSSidebarDragPayload.folder(node.id))
            .dropDestination(for: IOSSidebarDragPayload.self) { payloads, _ in
                acceptDrop(payloads, ontoFolder: node.id)
            } isTargeted: { targeted in
                if targeted {
                    targetedFolderID = node.id
                } else if targetedFolderID == node.id {
                    targetedFolderID = nil
                }
            }
            .background(
                isTargeted ? Steno.Colors.brand.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    private var emptyFolderRow: some View {
        Text("No meetings")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .selectionDisabled()
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        if let policy = presentation.folderActionPolicy(for: folder.id) {
            if policy.canCreateChild {
                Button {
                    beginCreatingFolder(parentFolderID: folder.id)
                } label: {
                    Label("New Subfolder\u{2026}", systemImage: "folder.badge.plus")
                }
            }

            Button {
                beginRenamingFolder(folder)
            } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }

            Divider()

            Button {
                moveFolder(folder.id, up: true)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!policy.canMoveUp)

            Button {
                moveFolder(folder.id, up: false)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!policy.canMoveDown)

            if !policy.parentDestinations.isEmpty {
                Menu("Move into Folder", systemImage: "folder") {
                    ForEach(policy.parentDestinations) { destination in
                        Button(destination.title) {
                            execute(.moveFolder(folder.id, destination.folderID))
                        }
                    }
                }
            }

            if policy.canMoveToRoot {
                Button {
                    execute(.moveFolder(folder.id, nil))
                } label: {
                    Label("Move to Top Level", systemImage: "arrow.up.to.line")
                }
            }

            Divider()

            Button(role: .destructive) {
                folderDeleteTarget = folder
            } label: {
                Label("Delete Folder\u{2026}", systemImage: "trash")
            }
        }
    }

    private func disclosureBinding(for folderID: FolderID) -> Binding<Bool> {
        Binding(
            get: { effectiveExpandedFolderIDs.contains(folderID) },
            set: { isExpanded in
                guard !isSearching else { return }
                persistedExpandedFolderIDs = disclosureStore.setExpanded(
                    isExpanded,
                    for: folderID
                )
            }
        )
    }

    // MARK: - Meetings

    private func meetingRow(_ meeting: Meeting) -> some View {
        NavigationLink(value: SidebarItem.meeting(meeting.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(2)
                Text(
                    meeting.createdAt,
                    format: .dateTime.day().month().hour().minute()
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("meeting-sidebar-meeting-\(meeting.id.description)")
        .contextMenu { meetingMenu(meeting) }
        .draggable(IOSSidebarDragPayload.meeting(meeting.id))
    }

    @ViewBuilder
    private func meetingMenu(_ meeting: Meeting) -> some View {
        let policy = presentation.meetingActionPolicy(for: meeting.id)
        Menu("Move to Folder", systemImage: "folder") {
            ForEach(policy.moveDestinations) { destination in
                Button(destination.title) {
                    execute(.moveMeeting(meeting.id, destination.folderID))
                }
                .disabled(destination.isCurrent)
            }
        }
    }

    // MARK: - Mutations

    private func acceptDrop(
        _ payloads: [IOSSidebarDragPayload],
        ontoFolder destinationFolderID: FolderID
    ) -> Bool {
        guard payloads.count == 1 else { return false }
        let decision = presentation.dropDecision(
            for: payloads[0],
            ontoFolder: destinationFolderID
        )
        guard decision != .reject else { return false }
        execute(decision)
        return true
    }

    private func acceptDrop(
        _ payloads: [IOSSidebarDragPayload],
        onto surface: IOSSidebarNoFolderDropSurface
    ) -> Bool {
        guard payloads.count == 1 else { return false }
        let decision = presentation.dropDecision(
            for: payloads[0],
            onto: surface
        )
        guard decision != .reject else { return false }
        execute(decision)
        return true
    }

    private func execute(_ decision: IOSSidebarDropDecision) {
        switch decision {
        case let .moveMeeting(meetingID, folderID):
            Task {
                guard await model.moveMeeting(meetingID, to: folderID) else { return }
                if let folderID {
                    revealFolder(folderID)
                }
            }
        case let .moveFolder(folderID, parentFolderID):
            Task {
                guard await model.moveFolder(folderID, to: parentFolderID) else { return }
                revealFolder(folderID)
            }
        case .reject:
            break
        }
    }

    private func moveFolder(_ folderID: FolderID, up: Bool) {
        Task {
            guard await model.moveFolder(folderID, up: up) else { return }
            revealFolder(folderID)
        }
    }

    private func beginCreatingFolder(parentFolderID: FolderID?) {
        folderName = ""
        folderNameOperation = .create(parentFolderID: parentFolderID)
    }

    private func beginRenamingFolder(_ folder: Folder) {
        folderName = folder.name
        folderNameOperation = .rename(folder)
    }

    private var normalizedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitFolderNameOperation() {
        guard let operation = folderNameOperation,
              !normalizedFolderName.isEmpty
        else { return }
        let name = normalizedFolderName
        switch operation {
        case .create(let parentFolderID):
            Task {
                guard let folder = await model.createFolder(
                    named: name,
                    parentFolderID: parentFolderID
                ) else { return }
                revealFolder(folder.id)
            }
        case .rename(let folder):
            Task {
                _ = await model.renameFolder(folder.id, to: name)
            }
        }
    }

    private func deleteFolder(_ folder: Folder) {
        Task {
            guard await model.deleteFolder(folder.id) else { return }
            persistedExpandedFolderIDs = disclosureStore.remove(folder.id)
        }
    }

    private func revealMeeting(_ request: IOSSidebarRevealRequest) {
        IOSSidebarRevealApplication.apply(
            request,
            presentation: presentation,
            disclosureStore: disclosureStore,
            updateExpansion: { expanded in
                persistedExpandedFolderIDs = expanded
            },
            selectionReady: onRevealApplied
        )
    }

    private func revealFolder(_ folderID: FolderID) {
        let expanded = presentation.expandedFolderIDs(
            revealing: folderID,
            persisted: []
        )
        guard !expanded.isEmpty else { return }
        persistedExpandedFolderIDs = disclosureStore.add(expanded)
    }

    private var folderNameOperationIsPresented: Binding<Bool> {
        Binding(
            get: { folderNameOperation != nil },
            set: { if !$0 { folderNameOperation = nil } }
        )
    }

    private var folderDeleteIsPresented: Binding<Bool> {
        Binding(
            get: { folderDeleteTarget != nil },
            set: { if !$0 { folderDeleteTarget = nil } }
        )
    }
}

private enum FolderNameOperation: Identifiable {
    case create(parentFolderID: FolderID?)
    case rename(Folder)

    var id: String {
        switch self {
        case .create(let parentFolderID):
            parentFolderID.map { "create:\($0.description)" } ?? "create:root"
        case .rename(let folder):
            "rename:\(folder.id.description)"
        }
    }

    var title: String {
        switch self {
        case .create(let parentFolderID):
            parentFolderID == nil ? "New Folder" : "New Subfolder"
        case .rename:
            "Rename Folder"
        }
    }

    var actionTitle: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        }
    }

    var message: String? {
        switch self {
        case .create(let parentFolderID) where parentFolderID != nil:
            "Subfolders can contain meetings but no further folders."
        case .create, .rename:
            nil
        }
    }
}
