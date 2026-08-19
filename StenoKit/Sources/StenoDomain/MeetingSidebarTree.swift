import Foundation

public struct MeetingFolderNode: Identifiable, Equatable, Sendable {
    public let folder: Folder
    public let meetings: [Meeting]
    public let children: [MeetingFolderNode]

    public var id: FolderID { folder.id }

    public init(
        folder: Folder,
        meetings: [Meeting],
        children: [MeetingFolderNode]
    ) {
        self.folder = folder
        self.meetings = meetings
        self.children = children
    }
}

public struct MeetingSidebarTree: Equatable, Sendable {
    public let folderNodes: [MeetingFolderNode]
    public let unfiledSections: [MeetingSection]

    public init(
        folderNodes: [MeetingFolderNode],
        unfiledSections: [MeetingSection]
    ) {
        self.folderNodes = folderNodes
        self.unfiledSections = unfiledSections
    }

    public static func build(
        for meetings: [Meeting],
        folders: [Folder],
        now: Date = Date(),
        calendar: Calendar = .current,
        hidesEmptyFolders: Bool = false
    ) -> MeetingSidebarTree {
        var seenFolderIDs: Set<FolderID> = []
        let uniqueFolders = folders.filter {
            seenFolderIDs.insert($0.id).inserted
        }
        let foldersByID = Dictionary(
            uniqueKeysWithValues: uniqueFolders.map { ($0.id, $0) }
        )

        let safeChildIDs = Set(uniqueFolders.compactMap { folder -> FolderID? in
            guard let parentID = folder.parentFolderID,
                  parentID != folder.id,
                  let parent = foldersByID[parentID],
                  parent.parentFolderID == nil
            else { return nil }
            return folder.id
        })

        var seenMeetingIDs: Set<MeetingID> = []
        let uniqueMeetings = meetings.filter {
            seenMeetingIDs.insert($0.id).inserted
        }
        var meetingsByFolder: [FolderID: [Meeting]] = [:]
        var unfiled: [Meeting] = []
        for meeting in uniqueMeetings {
            if let folderID = meeting.folderID, foldersByID[folderID] != nil {
                meetingsByFolder[folderID, default: []].append(meeting)
            } else {
                unfiled.append(meeting)
            }
        }

        let rootFolders = uniqueFolders
            .filter { !safeChildIDs.contains($0.id) }
            .sorted(by: folderOrder)
        let nodes = rootFolders.compactMap { root -> MeetingFolderNode? in
            let children = uniqueFolders
                .filter {
                    safeChildIDs.contains($0.id)
                        && $0.parentFolderID == root.id
                }
                .sorted(by: folderOrder)
                .compactMap { child -> MeetingFolderNode? in
                    let childMeetings = meetingsByFolder[child.id] ?? []
                    guard !hidesEmptyFolders || !childMeetings.isEmpty else {
                        return nil
                    }
                    return MeetingFolderNode(
                        folder: child,
                        meetings: childMeetings,
                        children: []
                    )
                }
            let rootMeetings = meetingsByFolder[root.id] ?? []
            guard !hidesEmptyFolders
                    || !rootMeetings.isEmpty
                    || !children.isEmpty
            else { return nil }
            return MeetingFolderNode(
                folder: root,
                meetings: rootMeetings,
                children: children
            )
        }

        return MeetingSidebarTree(
            folderNodes: nodes,
            unfiledSections: MeetingGrouping.sections(
                for: unfiled,
                now: now,
                calendar: calendar
            )
        )
    }

    private static func folderOrder(_ lhs: Folder, _ rhs: Folder) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
