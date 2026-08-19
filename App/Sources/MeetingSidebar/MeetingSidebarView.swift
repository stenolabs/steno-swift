import StenoDomain
import SwiftUI

struct MeetingSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<MeetingID>

    @State private var renameTarget: Meeting?
    @State private var renameTitle = ""
    @State private var deleteTarget: Meeting?
    @State private var folderRenameTarget: Folder?
    @State private var folderName = ""
    @State private var folderDeleteTarget: Folder?
    @State private var isCreatingFolder = false
    @State private var newFolderParentID: FolderID?
    @State private var query = ""
    @State private var retranscribeTarget: Meeting?
    @State private var audioExportRequest: AudioExportDialogRequest?
    @State private var audioExportLoadRequestID: UUID?
    @State private var persistedExpandedFolderIDs = FolderDisclosureStore().load()
    @State private var targetedFolderID: FolderID?
    @State private var isFolderHeadingTargeted = false
    @State private var isMovingMeetings = false

    private let disclosureStore = FolderDisclosureStore()

    var body: some View {
        list
            .modifier(FolderDialogs(
                folderName: $folderName,
                isCreating: $isCreatingFolder,
                newFolderParentID: $newFolderParentID,
                renameTarget: $folderRenameTarget,
                deleteTarget: $folderDeleteTarget,
                disclosureStore: disclosureStore
            ))
            .confirmationDialog(
                "Which track?",
                isPresented: Binding(
                    get: { audioExportRequest != nil },
                    set: { if !$0 { audioExportRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: audioExportRequest
            ) { request in
                ForEach(request.options) { option in
                    Button(option.label) {
                        let target = request.meeting
                        audioExportRequest = nil
                        switch option {
                        case let .original(asset, _):
                            Task {
                                await model.exportAudioTrack(asset, of: target.id)
                            }
                        case let .stereoM4A(microphone, system):
                            Task {
                                await model.exportStereoAudio(
                                    microphone: microphone,
                                    system: system,
                                    of: target.id
                                )
                            }
                        }
                    }
                    .disabled(
                        option.kind == .stereoM4A
                            && model.audioExportActivity != nil
                    )
                }
                Button("Cancel", role: .cancel) { audioExportRequest = nil }
            } message: { _ in
                Text("The original stays in the library; this saves a copy.")
            }
            .modifier(MeetingDialogs(
                renameTitle: $renameTitle,
                renameTarget: $renameTarget,
                deleteTarget: $deleteTarget,
                retranscribeTarget: $retranscribeTarget
            ))
    }

    private var list: some View {
        List(selection: $selection) {
            folderHeading
            ForEach(tree.folderNodes) { node in
                rootFolder(node)
            }
            ForEach(tree.unfiledSections) { section in
                dateSection(section)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: MeetingID.self) { meetingIDs in
            meetingSelectionMenu(for: meetingIDs)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    beginCreatingFolder(parentFolderID: nil)
                } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                .help("Create a folder")
                .disabled(model.runtime == nil)
            }
        }
        .navigationTitle("Steno")
        .safeAreaInset(edge: .top) { searchBar }
        .overlay {
            if model.meetings.isEmpty, model.folders.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "tray",
                    description: Text("Recordings and imports appear here.")
                )
            } else if allTreeMeetingIDs.isEmpty, isSearching {
                ContentUnavailableView.search(text: query)
            }
        }
        .onChange(of: query) { _, _ in
            pruneSelection()
        }
        .onChange(of: model.meetings) { _, _ in
            if !isMovingMeetings {
                pruneSelection()
            }
        }
        .onChange(of: model.folders) { _, folders in
            let existing = Set(folders.map(\.id))
            persistedExpandedFolderIDs.formIntersection(existing)
            disclosureStore.save(persistedExpandedFolderIDs)
            pruneSelection()
        }
    }

    private var folderHeading: some View {
        HStack {
            Text("Folders")
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isFolderHeadingTargeted
                        ? Color(nsColor: .selectedControlTextColor)
                        : Color.secondary
                )
            Spacer()
        }
        .padding(.top, Steno.Space.s)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityLabel("Folders")
        .accessibilityHint("Drop a nested folder here to move it to the top level.")
        .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
            guard payloads.count == 1,
                  case let .folder(folderID) = payloads[0],
                  MeetingSidebarDropPolicy.canPromote(
                      folder: folderID,
                      folders: model.folders
                  )
            else { return false }
            Task {
                _ = await model.moveFolder(folderID, to: nil)
            }
            return true
        } isTargeted: { isTargeted in
            isFolderHeadingTargeted = isTargeted
        }
        .dropConfiguration { session in
            dropConfigurationForFolderHeading(session)
        }
        .background(
            isFolderHeadingTargeted
                ? Color(nsColor: .selectedContentBackgroundColor)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
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
            folderLabel(node)
                .selectionDisabled()
        }
        .springLoadingBehavior(.enabled)
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
            folderLabel(node)
                .selectionDisabled()
        }
        .springLoadingBehavior(.enabled)
    }

    private func folderLabel(_ node: MeetingFolderNode) -> some View {
        let isTargeted = MeetingSidebarDropPresentation.isTargeted(
            node.id,
            targetedFolderID: targetedFolderID
        )

        return HStack(spacing: Steno.Space.s) {
            Label {
                Text(node.folder.name)
            } icon: {
                Image(systemName: MeetingSidebarDropPresentation.symbolName)
            }
            Spacer(minLength: Steno.Space.xs)
        }
            .foregroundStyle(
                isTargeted
                    ? Color(nsColor: .selectedControlTextColor)
                    : Color.primary
            )
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { folderMenu(node) }
            .accessibilityValue(
                "\(node.meetings.count) direct meetings, \(node.children.count) subfolders"
            )
            .draggable(SidebarDragPayload(folderID: node.id)) {
                SidebarDragPreview(
                    title: node.folder.name,
                    systemImage: "folder"
                )
            }
            .dragConfiguration(MeetingSidebarDragContract.sourceConfiguration)
            .dropDestination(for: SidebarDragPayload.self) { payloads, _ in
                guard payloads.count == 1 else { return false }
                switch payloads[0] {
                case .meetings:
                    guard let meetingIDs = MeetingSidebarDropPolicy
                        .meetingIDsToAttempt(payloads[0])
                    else { return false }
                    moveMeetings(meetingIDs, to: node.id)
                    return true
                case let .folder(folderID):
                    guard MeetingSidebarDropPolicy.canMove(
                        folder: folderID,
                        onto: node.id,
                        folders: model.folders
                    ) else { return false }
                    moveFolder(folderID, to: node.id)
                    return true
                }
            } isTargeted: { isTargeted in
                updateFolderTarget(node.id, isTargeted: isTargeted)
            }
            .dropConfiguration { session in
                dropConfiguration(session, for: node.id)
            }
            .background(
                isTargeted
                    ? Color(nsColor: .selectedContentBackgroundColor)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    private var emptyFolderRow: some View {
        Text("Empty - move a meeting here")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    @ViewBuilder
    private func dateSection(_ section: MeetingSection) -> some View {
        Text(section.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, Steno.Space.s)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        ForEach(section.meetings, id: \.id) { meeting in
            meetingRow(meeting)
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        let draggedMeetingIDs = MeetingSidebarSelectionPolicy.draggedIDs(
            startingAt: meeting.id,
            selection: selection
        )

        return VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(
                    meeting.createdAt,
                    format: .dateTime.day().month().hour().minute()
                )
                if meeting.status != .ready {
                    StatusBadge(status: meeting.status)
                }
                if model.meetingsWithAudio.contains(meeting.id) {
                    Image(systemName: "waveform")
                        .help("Audio available - voice samples and speaker naming possible")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(meeting.id)
        .draggable(SidebarDragPayload(meetingIDs: draggedMeetingIDs)) {
            SidebarDragPreview(
                title: meeting.title,
                systemImage: "waveform",
                itemCount: draggedMeetingIDs.count
            )
        }
        .dragConfiguration(MeetingSidebarDragContract.sourceConfiguration)
    }

    @ViewBuilder
    private func meetingSelectionMenu(for meetingIDs: Set<MeetingID>) -> some View {
        if meetingIDs.count > 1 {
            Menu("Move \(meetingIDs.count) Meetings") {
                meetingDestinationMenu(for: meetingIDs)
            }
        } else if let meetingID = meetingIDs.first,
                  let meeting = model.meetings.first(where: { $0.id == meetingID }) {
            Button("Rename…") {
                renameTitle = meeting.title
                renameTarget = meeting
            }
            Menu("Move to Folder") {
                meetingDestinationMenu(for: meetingIDs)
                Divider()
                Button("New Folder…") {
                    beginCreatingFolder(parentFolderID: nil)
                }
            }
            Divider()
            Button("Transcribe Again…") {
                retranscribeTarget = meeting
            }
            .disabled(
                meeting.status == .recording
                    || !model.meetingsWithAudio.contains(meeting.id)
            )
            Button("Export as Markdown…") {
                Task { await model.exportMeetingToFile(meeting.id) }
            }
            if model.meetingsWithAudio.contains(meeting.id) {
                Button("Export Audio…") {
                    beginAudioExport(for: meeting)
                }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) {
                deleteTarget = meeting
            }
            .disabled(meeting.status == .recording)
        }
    }

    private func beginAudioExport(for meeting: Meeting) {
        let loadRequestID = UUID()
        audioExportLoadRequestID = loadRequestID
        Task {
            let request = await AudioExportDialogRequest.load(for: meeting) {
                await model.audioExportOptions(for: $0)
            }
            guard audioExportLoadRequestID == loadRequestID else { return }
            audioExportLoadRequestID = nil
            guard let request else {
                model.report("No readable audio tracks are available for export.")
                return
            }
            audioExportRequest = request
        }
    }

    @ViewBuilder
    private func meetingDestinationMenu(for meetingIDs: Set<MeetingID>) -> some View {
        ForEach(normalTree.folderNodes) { root in
            Menu(root.folder.name) {
                Button("Move Here") {
                    moveMeetings(meetingIDs, to: root.id)
                }
                ForEach(root.children) { child in
                    Button(child.folder.name) {
                        moveMeetings(meetingIDs, to: child.id)
                    }
                }
            }
        }
        if !normalTree.folderNodes.isEmpty {
            Divider()
        }
        Button("None") {
            moveMeetings(meetingIDs, to: nil)
        }
    }

    @ViewBuilder
    private func folderMenu(_ node: MeetingFolderNode) -> some View {
        if node.folder.parentFolderID == nil {
            Button("New Subfolder…") {
                beginCreatingFolder(parentFolderID: node.id)
            }
        }
        Button("Rename…") {
            folderName = node.folder.name
            folderRenameTarget = node.folder
        }
        Divider()
        Button("Move Up") {
            Task { await model.moveFolder(node.id, up: true) }
        }
        .disabled(!canMoveSibling(node.folder, offset: -1))
        Button("Move Down") {
            Task { await model.moveFolder(node.id, up: false) }
        }
        .disabled(!canMoveSibling(node.folder, offset: 1))
        let nestingDestinations = MeetingSidebarFolderMenuPolicy
            .nestingDestinations(for: node.folder, folders: model.folders)
        if !nestingDestinations.isEmpty {
            Menu("Move into Folder") {
                ForEach(nestingDestinations) { destination in
                    Button(destination.name) {
                        moveFolder(node.id, to: destination.id)
                    }
                }
            }
        }
        if node.folder.parentFolderID != nil {
            Button("Move to Top Level") {
                moveFolder(node.id, to: nil)
            }
        }
        Divider()
        Button("Delete Folder…", role: .destructive) {
            folderDeleteTarget = node.folder
        }
    }

    private var searchBar: some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search titles", text: $query)
                .textFieldStyle(.plain)
            if isSearching {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, Steno.Space.m)
        .padding(.vertical, Steno.Space.s)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tree: MeetingSidebarTree {
        MeetingSidebarTree.build(
            for: MeetingSearch.matching(model.meetings, query: query),
            folders: model.folders,
            hidesEmptyFolders: isSearching
        )
    }

    private var normalTree: MeetingSidebarTree {
        MeetingSidebarTree.build(
            for: model.meetings,
            folders: model.folders
        )
    }

    private var effectiveExpandedFolderIDs: Set<FolderID> {
        MeetingSidebarVisibility.effectiveExpandedFolderIDs(
            in: tree,
            persisted: persistedExpandedFolderIDs,
            isSearching: isSearching
        )
    }

    private var allTreeMeetingIDs: Set<MeetingID> {
        var result = Set(
            tree.unfiledSections.flatMap(\.meetings).map(\.id)
        )
        for root in tree.folderNodes {
            result.formUnion(root.meetings.map(\.id))
            for child in root.children {
                result.formUnion(child.meetings.map(\.id))
            }
        }
        return result
    }

    private func disclosureBinding(for folderID: FolderID) -> Binding<Bool> {
        Binding(
            get: { effectiveExpandedFolderIDs.contains(folderID) },
            set: { expanded in
                guard !isSearching else { return }
                if expanded {
                    persistedExpandedFolderIDs.insert(folderID)
                } else {
                    persistedExpandedFolderIDs.remove(folderID)
                }
                disclosureStore.save(persistedExpandedFolderIDs)
                if !expanded {
                    pruneSelection()
                }
            }
        )
    }

    private func pruneSelection() {
        selection = MeetingSidebarVisibility.prunedSelection(
            selection,
            in: tree,
            expandedFolderIDs: effectiveExpandedFolderIDs
        )
    }

    private func beginCreatingFolder(parentFolderID: FolderID?) {
        folderName = ""
        newFolderParentID = parentFolderID
        isCreatingFolder = true
    }

    private func moveMeetings(
        _ meetingIDs: Set<MeetingID>,
        to folderID: FolderID?
    ) {
        isMovingMeetings = true
        Task {
            let moved = await model.moveMeetings(meetingIDs, to: folderID)
            if moved, let folderID {
                expandPath(to: folderID)
            }
            isMovingMeetings = false
            pruneSelection()
        }
    }

    private func moveFolder(_ folderID: FolderID, to parentFolderID: FolderID?) {
        Task {
            guard await model.moveFolder(folderID, to: parentFolderID) else {
                return
            }
            if parentFolderID != nil {
                expandPath(to: folderID)
            }
        }
    }

    private func expandPath(to folderID: FolderID) {
        persistedExpandedFolderIDs = MeetingSidebarVisibility.expandedFolderIDs(
            persistedExpandedFolderIDs,
            revealing: folderID,
            folders: model.folders
        )
        disclosureStore.save(persistedExpandedFolderIDs)
    }

    private func canMoveSibling(_ folder: Folder, offset: Int) -> Bool {
        let siblings = model.folders.filter {
            $0.parentFolderID == folder.parentFolderID
        }
        guard let index = siblings.firstIndex(where: { $0.id == folder.id }) else {
            return false
        }
        return siblings.indices.contains(index + offset)
    }

    private func updateFolderTarget(
        _ folderID: FolderID,
        isTargeted: Bool
    ) {
        if isTargeted {
            targetedFolderID = folderID
        } else if targetedFolderID == folderID {
            targetedFolderID = nil
        }
    }

    private func isValidLocalDrop(
        _ session: DropSession,
        onto folderID: FolderID
    ) -> Bool {
        MeetingSidebarDropPolicy.canNegotiateLocalMove(
            itemCount: session.itemsCount,
            hasLocalSession: session.localSession != nil,
            suggestsMove: session.suggestedOperations.contains(.move),
            targetExists: model.folders.contains(where: { $0.id == folderID })
        )
    }

    private func dropConfiguration(
        _ session: DropSession,
        for folderID: FolderID
    ) -> DropConfiguration {
        var configuration = DropConfiguration(
            operation: isValidLocalDrop(session, onto: folderID)
                ? MeetingSidebarDragContract.destinationOperation
                : .forbidden
        )
        configuration.acceptedItemCount = 1
        return configuration
    }

    private func isValidFolderHeadingDrop(_ session: DropSession) -> Bool {
        MeetingSidebarDropPolicy.canNegotiateLocalMove(
            itemCount: session.itemsCount,
            hasLocalSession: session.localSession != nil,
            suggestsMove: session.suggestedOperations.contains(.move),
            targetExists: !model.folders.isEmpty
        )
    }

    private func dropConfigurationForFolderHeading(
        _ session: DropSession
    ) -> DropConfiguration {
        var configuration = DropConfiguration(
            operation: isValidFolderHeadingDrop(session)
                ? MeetingSidebarDragContract.destinationOperation
                : .forbidden
        )
        configuration.acceptedItemCount = 1
        return configuration
    }
}

private struct FolderDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var folderName: String
    @Binding var isCreating: Bool
    @Binding var newFolderParentID: FolderID?
    @Binding var renameTarget: Folder?
    @Binding var deleteTarget: Folder?
    let disclosureStore: FolderDisclosureStore

    func body(content: Content) -> some View {
        content
            .alert(
                newFolderParentID == nil ? "New folder" : "New subfolder",
                isPresented: $isCreating
            ) {
                TextField("Name", text: $folderName)
                Button("Create") {
                    let name = folderName
                    let parentFolderID = newFolderParentID
                    isCreating = false
                    Task {
                        _ = await model.createFolder(
                            named: name,
                            parentFolderID: parentFolderID
                        )
                    }
                }
                Button("Cancel", role: .cancel) { isCreating = false }
            }
            .alert(
                "Rename folder",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { folder in
                TextField("Name", text: $folderName)
                Button("Rename") {
                    let target = folder.id
                    let name = folderName
                    renameTarget = nil
                    Task { await model.renameFolder(target, to: name) }
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog(
                deleteTarget.map { "Delete the folder \u{201C}\($0.name)\u{201D}?" } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { folder in
                Button("Delete folder", role: .destructive) {
                    let target = folder.id
                    deleteTarget = nil
                    Task {
                        if await model.deleteFolder(target) {
                            disclosureStore.remove(target)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { folder in
                if model.folders.contains(where: {
                    $0.parentFolderID == folder.id
                }) {
                    Text("Only the folder goes away. Its meetings stay in the library, and its subfolders move to the top level.")
                } else {
                    Text("Only the folder goes away. Its meetings stay in the library and move back to the date list.")
                }
            }
    }
}

private struct MeetingDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var renameTitle: String
    @Binding var renameTarget: Meeting?
    @Binding var deleteTarget: Meeting?
    @Binding var retranscribeTarget: Meeting?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                retranscribeTarget.map { "Transcribe \u{201C}\($0.title)\u{201D} again?" } ?? "",
                isPresented: Binding(
                    get: { retranscribeTarget != nil },
                    set: { if !$0 { retranscribeTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: retranscribeTarget
            ) { meeting in
                Button("Transcribe Again") {
                    let target = meeting.id
                    retranscribeTarget = nil
                    Task { await model.requestRetranscription(meetingID: target) }
                }
                Button("Cancel", role: .cancel) { retranscribeTarget = nil }
            } message: { _ in
                Text("A new transcript is added; the current one stays available as an earlier version. Speaker assignments for this meeting have to be confirmed again afterwards.")
            }
            .alert(
                "Rename meeting",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { meeting in
                TextField("Title", text: $renameTitle)
                Button("Rename") {
                    let target = meeting.id
                    let title = renameTitle
                    renameTarget = nil
                    Task { await model.renameMeeting(target, to: title) }
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: { _ in
                Text("The new title only affects how the meeting is displayed; the originals stay unchanged.")
            }
            .confirmationDialog(
                deleteTarget.map { "Move \u{201C}\($0.title)\u{201D} to the Trash?" } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { meeting in
                Button("Move to Trash", role: .destructive) {
                    let target = meeting.id
                    deleteTarget = nil
                    Task { await model.deleteMeeting(target) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { _ in
                Text("The entire meeting folder (audio, transcripts, runs) moves to the Trash and stays recoverable there. Speakers that are still unnamed cannot be named after deletion, because naming needs the audio file.")
            }
    }
}

private struct SidebarDragPreview: View {
    let title: String
    let systemImage: String
    var itemCount = 1

    var body: some View {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .lineLimit(1)
            if itemCount > 1 {
                Text("\(itemCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        Color(nsColor: .selectedControlTextColor)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}

private struct StatusBadge: View {
    let status: Meeting.Status

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .draft: "Draft"
        case .recording: "Recording"
        case .interrupted: "Interrupted"
        case .processing: "Processing"
        case .ready: "Ready"
        }
    }

    private var color: Color {
        switch status {
        case .draft: .secondary
        case .recording: Steno.Colors.recording
        case .interrupted: Steno.Colors.uncertain
        case .processing: Steno.Colors.running
        case .ready: Steno.Colors.confirmed
        }
    }
}
