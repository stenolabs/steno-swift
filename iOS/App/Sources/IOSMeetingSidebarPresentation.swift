import CoreTransferable
import Foundation
import StenoDomain
import UniformTypeIdentifiers

/// Reine Darstellungs- und Drop-Vorprüfung für die iOS-Meeting-Sidebar.
///
/// Die Hierarchie selbst entsteht ausschließlich im gemeinsamen
/// `MeetingSidebarTree`. Diese Fassade ergänzt nur den UI-Zustand, der nicht
/// persistiert werden darf, und lehnt klar ungültige lokale Drops ab. Der
/// `FolderStore` bleibt für jede Änderung die letzte Instanz der Wahrheit.
struct IOSMeetingSidebarPresentation: Equatable {
    let tree: MeetingSidebarTree

    private let folders: [Folder]
    private let meetingsByID: [MeetingID: Meeting]
    private let isSearching: Bool
    private let unsearchedTree: MeetingSidebarTree

    init(
        folders: [Folder],
        meetings: [Meeting],
        query: String,
        now: Date = Date()
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !normalizedQuery.isEmpty

        self.folders = folders
        meetingsByID = meetings.reduce(into: [:]) { result, meeting in
            result[meeting.id] = result[meeting.id] ?? meeting
        }
        self.isSearching = isSearching
        let unsearchedTree = MeetingSidebarTree.build(
            for: meetings,
            folders: folders,
            now: now
        )
        self.unsearchedTree = unsearchedTree
        tree = isSearching
            ? MeetingSidebarTree.build(
                for: MeetingSearch.matching(meetings, query: normalizedQuery),
                folders: folders,
                now: now,
                hidesEmptyFolders: true
            )
            : unsearchedTree
    }

    static func emptyMeetingMessage(
        isReady: Bool,
        query: String
    ) -> LocalizedStringResource {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty else {
            return "No meeting titles match \u{201c}\(normalizedQuery)\u{201d}."
        }
        return isReady ? "No recordings yet." : "Opening the library\u{2026}"
    }

    /// Eine Suche öffnet nur für die Dauer ihrer Anzeige die sichtbaren
    /// Knoten. Die übergebene gespeicherte Menge wird dabei nie verändert.
    func effectiveExpandedFolderIDs(persisted: Set<FolderID>) -> Set<FolderID> {
        guard isSearching else { return persisted }
        return tree.folderNodes.reduce(into: persisted) { result, root in
            result.insert(root.id)
            result.formUnion(root.children.map(\.id))
        }
    }

    /// Die feste Folder-Kopfzeile ist immer ein erreichbares Ziel fuer
    /// `No folder`. Sichtbare Datumsabschnitte bieten dasselbe Ziel zusaetzlich
    /// dort an, wo ungeordnete Meetings bereits erscheinen.
    var noFolderDropSurfaces: [IOSSidebarNoFolderDropSurface] {
        [.foldersHeading] + tree.unfiledSections.map {
            .unfiledSection($0.id)
        }
    }

    /// Macht einen Zielordner nach einem erfolgreichen Transfer sichtbar,
    /// ohne für eine inzwischen gelöschte Kennung einen Phantomzustand zu
    /// speichern.
    func expandedFolderIDs(
        revealing folderID: FolderID,
        persisted: Set<FolderID>
    ) -> Set<FolderID> {
        guard let folder = folder(for: folderID) else { return persisted }
        var expanded = persisted
        expanded.insert(folder.id)
        if let parentFolderID = folder.parentFolderID,
           rootNode(for: parentFolderID)?.children.contains(where: { $0.id == folder.id }) == true {
            expanded.insert(parentFolderID)
        }
        return expanded
    }

    /// Navigation keeps the existing meeting route and only augments the
    /// persisted disclosure state with the meeting's confirmed tree path.
    /// Missing meetings are not guessed from a stale transfer request.
    func navigationReveal(
        for meetingID: MeetingID,
        persisted: Set<FolderID>
    ) -> IOSSidebarNavigationReveal? {
        guard let meeting = meetingsByID[meetingID] else { return nil }
        let expanded = meeting.folderID.map {
            expandedFolderIDs(revealing: $0, persisted: persisted)
        } ?? persisted
        return IOSSidebarNavigationReveal(
            selection: .meeting(meetingID),
            expandedFolderIDs: expanded
        )
    }

    /// Menüs zeigen jedes im gemeinsamen Baum sichtbare Ziel genau einmal.
    /// Auch bei einem zwischenzeitlich gelöschten Meeting bleibt die Auswahl
    /// verfügbar, damit die Store-Operation ihren echten aktuellen Zustand
    /// prüfen kann.
    func moveDestinations(for _: MeetingID) -> [Folder] {
        unsearchedTree.folderNodes.flatMap { root in
            [root.folder] + root.children.map(\.folder)
        }
    }

    /// The context menu intentionally includes the current destination and
    /// "No folder". The UI can show the complete model and disable the no-op,
    /// while every accepted meeting drop has the same explicit menu route.
    func meetingActionPolicy(
        for meetingID: MeetingID,
        locale: Locale = .current
    ) -> IOSSidebarMeetingActionPolicy {
        let currentFolderID = meetingsByID[meetingID]?.folderID
        let destinations = unsearchedTree.folderNodes.flatMap { root in
            [IOSSidebarMoveDestination(
                folderID: root.id,
                title: root.folder.name,
                isCurrent: currentFolderID == root.id
            )] + root.children.map { child in
                IOSSidebarMoveDestination(
                    folderID: child.id,
                    title: "\(root.folder.name) / \(child.folder.name)",
                    isCurrent: currentFolderID == child.id
                )
            }
        } + [IOSSidebarMoveDestination(
            folderID: nil,
            title: localized("No folder", locale: locale),
            isCurrent: currentFolderID == nil && meetingsByID[meetingID] != nil
        )]
        return IOSSidebarMeetingActionPolicy(moveDestinations: destinations)
    }

    private func localized(
        _ resource: LocalizedStringResource,
        locale: Locale
    ) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// Ein Hauptordner mit Kindern würde beim Verschachteln eine dritte Ebene
    /// erzeugen. Gleiches gilt nie für einen Unterordner, der nur auf einen
    /// anderen Hauptordner verschoben werden kann.
    func nestingDestinations(for folderID: FolderID) -> [Folder] {
        guard let folder = folder(for: folderID),
              !(folder.parentFolderID == nil && hasSharedChild(folderID))
        else { return [] }

        return unsearchedTree.folderNodes.map(\.folder).filter {
            $0.id != folderID && $0.id != folder.parentFolderID
        }
    }

    func folderActionPolicy(
        for folderID: FolderID
    ) -> IOSSidebarFolderActionPolicy? {
        guard let folder = folder(for: folderID),
              let siblingIDs = orderedSiblingIDs(for: folderID),
              let siblingIndex = siblingIDs.firstIndex(of: folderID)
        else { return nil }

        return IOSSidebarFolderActionPolicy(
            canCreateChild: folder.parentFolderID == nil,
            canMoveUp: siblingIndex > siblingIDs.startIndex,
            canMoveDown: siblingIndex < siblingIDs.index(before: siblingIDs.endIndex),
            parentDestinations: nestingDestinations(for: folderID).map {
                IOSSidebarMoveDestination(
                    folderID: $0.id,
                    title: $0.name,
                    isCurrent: false
                )
            },
            canMoveToRoot: folder.parentFolderID != nil
        )
    }

    func folderDeletionConfirmation(
        for folderID: FolderID
    ) -> IOSSidebarFolderDeletionConfirmation? {
        guard let folder = folder(for: folderID) else { return nil }
        let message: LocalizedStringResource
        if hasSharedChild(folderID) {
            message = "Only the folder goes away. Its direct meetings stay in the library and move to No folder. Its subfolders move to the top level."
        } else {
            message = "Only the folder goes away. Its direct meetings stay in the library and move to No folder."
        }
        return IOSSidebarFolderDeletionConfirmation(
            title: "Delete \u{201c}\(folder.name)\u{201d}?",
            message: message
        )
    }

    /// Liefert nur eine lokale Vorentscheidung. Das Ziel kann nach Start des
    /// Drags verschwunden oder im Store anderweitig verändert worden sein, was
    /// die aufrufende AppModel-Operation erneut und verbindlich validiert.
    func dropDecision(
        for payload: IOSSidebarDragPayload,
        ontoFolder destinationFolderID: FolderID
    ) -> IOSSidebarDropDecision {
        switch payload {
        case let .meeting(meetingID):
            guard folder(for: destinationFolderID) != nil,
                  meetingsByID[meetingID]?.folderID != destinationFolderID
            else { return .reject }
            return .moveMeeting(meetingID, destinationFolderID)

        case let .folder(folderID):
            guard let sourceFolder = folder(for: folderID) else { return .reject }
            guard let destination = folder(for: destinationFolderID),
                  destination.parentFolderID == nil,
                  folderID != destinationFolderID,
                  sourceFolder.parentFolderID != destinationFolderID,
                  !hasSharedChild(folderID)
            else { return .reject }
            return .moveFolder(folderID, destinationFolderID)
        }
    }

    /// Die Kopfzeile repraesentiert zwei ausdrueckliche Aktionen, ein
    /// Datumsabschnitt dagegen nur `No folder` fuer Meetings.
    func dropDecision(
        for payload: IOSSidebarDragPayload,
        onto surface: IOSSidebarNoFolderDropSurface
    ) -> IOSSidebarDropDecision {
        switch surface {
        case .foldersHeading:
            switch payload {
            case let .meeting(meetingID):
                return noFolderMeetingDropDecision(meetingID)
            case let .folder(folderID):
                guard let sourceFolder = folder(for: folderID) else { return .reject }
                return sourceFolder.parentFolderID == nil
                    ? .reject
                    : .moveFolder(folderID, nil)
            }
        case .unfiledSection:
            guard case let .meeting(meetingID) = payload else { return .reject }
            return noFolderMeetingDropDecision(meetingID)
        }
    }

    private func noFolderMeetingDropDecision(
        _ meetingID: MeetingID
    ) -> IOSSidebarDropDecision {
        if let meeting = meetingsByID[meetingID], meeting.folderID == nil {
            return .reject
        }
        return .moveMeeting(meetingID, nil)
    }

    private func folder(for folderID: FolderID) -> Folder? {
        folders.first { $0.id == folderID }
    }

    private func rootNode(for folderID: FolderID) -> MeetingFolderNode? {
        unsearchedTree.folderNodes.first { $0.id == folderID }
    }

    private func orderedSiblingIDs(for folderID: FolderID) -> [FolderID]? {
        if unsearchedTree.folderNodes.contains(where: { $0.id == folderID }) {
            return unsearchedTree.folderNodes.map(\.id)
        }
        return unsearchedTree.folderNodes.first(where: { root in
            root.children.contains(where: { $0.id == folderID })
        })?.children.map(\.id)
    }

    private func hasSharedChild(_ folderID: FolderID) -> Bool {
        !(rootNode(for: folderID)?.children.isEmpty ?? true)
    }
}

struct IOSSidebarNavigationReveal: Equatable {
    let selection: SidebarItem
    let expandedFolderIDs: Set<FolderID>
}

struct IOSSidebarRevealRequest: Equatable, Identifiable {
    let id: UUID
    let meetingID: MeetingID

    init(id: UUID = UUID(), meetingID: MeetingID) {
        self.id = id
        self.meetingID = meetingID
    }
}

struct IOSSidebarRevealEventState: Equatable {
    private(set) var pending: IOSSidebarRevealRequest?

    @discardableResult
    mutating func request(
        _ meetingID: MeetingID,
        requestID: UUID = UUID()
    ) -> IOSSidebarRevealRequest {
        let request = IOSSidebarRevealRequest(
            id: requestID,
            meetingID: meetingID
        )
        pending = request
        return request
    }

    @discardableResult
    mutating func consume(_ request: IOSSidebarRevealRequest) -> Bool {
        guard pending?.id == request.id else { return false }
        pending = nil
        return true
    }
}

enum IOSSidebarNoFolderDropSurface: Equatable, Identifiable {
    case foldersHeading
    case unfiledSection(String)

    var id: String {
        switch self {
        case .foldersHeading:
            "folders-heading"
        case .unfiledSection(let sectionID):
            "unfiled:\(sectionID)"
        }
    }

    var accessibilityHint: LocalizedStringResource {
        switch self {
        case .foldersHeading:
            "Drop a meeting here to move it to No folder. Drop a subfolder here to move it to the top level."
        case .unfiledSection:
            "Drop a meeting here to move it to No folder."
        }
    }
}

struct IOSSidebarMoveDestination: Equatable, Identifiable {
    let folderID: FolderID?
    let title: String
    let isCurrent: Bool

    var id: String {
        folderID.map { "folder:\($0.description)" } ?? "unfiled"
    }
}

struct IOSSidebarMeetingActionPolicy: Equatable {
    let moveDestinations: [IOSSidebarMoveDestination]
}

struct IOSSidebarFolderActionPolicy: Equatable {
    let canCreateChild: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let parentDestinations: [IOSSidebarMoveDestination]
    let canMoveToRoot: Bool
}

struct IOSSidebarFolderDeletionConfirmation: Equatable {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
}

private extension UTType {
    static let stenoIOSSidebarMeeting = UTType(
        exportedAs: "org.steno.ios-sidebar-meeting",
        conformingTo: .data
    )
    static let stenoIOSSidebarFolder = UTType(
        exportedAs: "org.steno.ios-sidebar-folder",
        conformingTo: .data
    )
}

/// Lokale Drag-Nutzlast ohne Meetinginhalt. Die Codierung enthält genau den
/// Fall und die rohe stabile Kennung, damit weder Titel noch Pfade oder
/// Transkriptbestandteile die Prozessgrenze verlassen können.
enum IOSSidebarDragPayload: Codable, Equatable, Sendable, Transferable {
    case meeting(MeetingID)
    case folder(FolderID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stenoIOSSidebarMeeting)
            .exportingCondition { payload in
                if case .meeting = payload { return true }
                return false
            }
        CodableRepresentation(contentType: .stenoIOSSidebarFolder)
            .exportingCondition { payload in
                if case .folder = payload { return true }
                return false
            }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case meeting
        case folder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let rawID = try container.decode(UUID.self, forKey: .id)
        switch kind {
        case .meeting:
            self = .meeting(MeetingID(rawValue: rawID))
        case .folder:
            self = .folder(FolderID(rawValue: rawID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .meeting(meetingID):
            try container.encode(Kind.meeting, forKey: .kind)
            try container.encode(meetingID.rawValue, forKey: .id)
        case let .folder(folderID):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(folderID.rawValue, forKey: .id)
        }
    }
}

enum IOSSidebarDropDecision: Equatable {
    case moveMeeting(MeetingID, FolderID?)
    case moveFolder(FolderID, FolderID?)
    case reject
}
