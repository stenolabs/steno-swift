import Foundation
import StenoDomain

enum MeetingSidebarSelectionPolicy {
    static func singleID(in selection: Set<MeetingID>) -> MeetingID? {
        guard selection.count == 1 else { return nil }
        return selection.first
    }

    static func pruned(
        _ selection: Set<MeetingID>,
        to visibleOrExisting: Set<MeetingID>
    ) -> Set<MeetingID> {
        selection.intersection(visibleOrExisting)
    }

    static func draggedIDs(
        startingAt meetingID: MeetingID,
        selection: Set<MeetingID>
    ) -> Set<MeetingID> {
        selection.contains(meetingID) ? selection : Set([meetingID])
    }
}

enum MeetingSidebarAction: Equatable {
    case rename
    case moveMeetings
    case retranscribe
    case export
    case trash
}

enum MeetingSidebarActionPolicy {
    static func actions(
        for meetingIDs: Set<MeetingID>
    ) -> [MeetingSidebarAction] {
        switch meetingIDs.count {
        case 0:
            []
        case 1:
            [.rename, .moveMeetings, .retranscribe, .export, .trash]
        default:
            [.moveMeetings]
        }
    }
}

enum MeetingSidebarVisibility {
    static func effectiveExpandedFolderIDs(
        in tree: MeetingSidebarTree,
        persisted: Set<FolderID>,
        isSearching: Bool
    ) -> Set<FolderID> {
        guard isSearching else { return persisted }
        return tree.folderNodes.reduce(into: persisted) { result, root in
            result.insert(root.id)
            result.formUnion(root.children.map(\.id))
        }
    }

    static func visibleMeetingIDs(
        in tree: MeetingSidebarTree,
        expandedFolderIDs: Set<FolderID>
    ) -> Set<MeetingID> {
        var visible = Set(
            tree.unfiledSections.flatMap(\.meetings).map(\.id)
        )
        for root in tree.folderNodes
        where expandedFolderIDs.contains(root.id) {
            visible.formUnion(root.meetings.map(\.id))
            for child in root.children
            where expandedFolderIDs.contains(child.id) {
                visible.formUnion(child.meetings.map(\.id))
            }
        }
        return visible
    }

    static func prunedSelection(
        _ selection: Set<MeetingID>,
        in tree: MeetingSidebarTree,
        expandedFolderIDs: Set<FolderID>
    ) -> Set<MeetingID> {
        MeetingSidebarSelectionPolicy.pruned(
            selection,
            to: visibleMeetingIDs(
                in: tree,
                expandedFolderIDs: expandedFolderIDs
            )
        )
    }

    static func expandedFolderIDs(
        _ persisted: Set<FolderID>,
        revealing folderID: FolderID,
        folders: [Folder]
    ) -> Set<FolderID> {
        guard let folder = folders.first(where: { $0.id == folderID }) else {
            return persisted
        }
        var expanded = persisted
        expanded.insert(folder.id)
        if let parentFolderID = folder.parentFolderID {
            expanded.insert(parentFolderID)
        }
        return expanded
    }
}

enum MeetingSidebarFolderMenuPolicy {
    static func nestingDestinations(
        for folder: Folder,
        folders: [Folder]
    ) -> [Folder] {
        if folder.parentFolderID == nil,
           folders.contains(where: { $0.parentFolderID == folder.id }) {
            return []
        }
        return folders.filter {
            $0.parentFolderID == nil
                && $0.id != folder.id
                && $0.id != folder.parentFolderID
        }
    }
}

enum MeetingSidebarDropPolicy {
    static func canNegotiateLocalMove(
        itemCount: Int,
        hasLocalSession: Bool,
        suggestsMove: Bool,
        targetExists: Bool
    ) -> Bool {
        itemCount == 1
            && hasLocalSession
            && suggestsMove
            && targetExists
    }

    static func meetingIDsToAttempt(
        _ payload: SidebarDragPayload
    ) -> Set<MeetingID>? {
        guard case let .meetings(payloadMeetingIDs) = payload else {
            return nil
        }
        let meetingIDs = Set(payloadMeetingIDs)
        guard !meetingIDs.isEmpty,
              meetingIDs.count == payloadMeetingIDs.count
        else { return nil }
        return meetingIDs
    }

    static func canMove(
        folder folderID: FolderID,
        onto parentFolderID: FolderID,
        folders: [Folder]
    ) -> Bool {
        guard folderID != parentFolderID,
              let folder = folders.first(where: { $0.id == folderID }),
              let parent = folders.first(where: { $0.id == parentFolderID }),
              parent.parentFolderID == nil,
              !folders.contains(where: { $0.parentFolderID == folderID })
        else { return false }

        return folder.parentFolderID != parentFolderID
    }

    static func canPromote(
        folder folderID: FolderID,
        folders: [Folder]
    ) -> Bool {
        folders.first(where: { $0.id == folderID })?.parentFolderID != nil
    }
}

enum MeetingSidebarDropPresentation {
    static let symbolName = "folder"

    static func isTargeted(
        _ folderID: FolderID,
        targetedFolderID: FolderID?
    ) -> Bool {
        folderID == targetedFolderID
    }
}

struct FolderDisclosureStore {
    private static let key = "steno.sidebar.expandedFolders"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Set<FolderID> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap { raw in
            UUID(uuidString: raw).map(FolderID.init(rawValue:))
        })
    }

    func save(_ folderIDs: Set<FolderID>) {
        defaults.set(
            folderIDs.map(\.description).sorted(),
            forKey: Self.key
        )
    }

    func remove(_ folderID: FolderID) {
        var folderIDs = load()
        folderIDs.remove(folderID)
        save(folderIDs)
    }
}
