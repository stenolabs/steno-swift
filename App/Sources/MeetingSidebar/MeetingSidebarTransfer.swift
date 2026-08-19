import CoreTransferable
import StenoDomain
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let stenoSidebarItem = UTType(exportedAs: "org.steno.sidebar-item")
}

enum MeetingSidebarDragContract {
    static let sourceAllowsMove = true
    static let destinationOperation: DropOperation = .move

    static var sourceConfiguration: DragConfiguration {
        DragConfiguration(allowMove: sourceAllowsMove)
    }
}

enum SidebarDragPayload: Codable, Hashable, Identifiable, Transferable {
    case meetings([MeetingID])
    case folder(FolderID)

    var id: String {
        switch self {
        case let .meetings(meetingIDs):
            "meetings:" + meetingIDs.map(\.description).joined(separator: ",")
        case let .folder(folderID):
            "folder:" + folderID.description
        }
    }

    init<S: Sequence>(meetingIDs: S) where S.Element == MeetingID {
        self = .meetings(meetingIDs.sorted())
    }

    init(folderID: FolderID) {
        self = .folder(folderID)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stenoSidebarItem)
    }
}
