import StenoDomain
import SwiftUI

/// Shared native menu contents for moving a meeting.
///
/// The store remains the final authority after a tap. This view only keeps
/// every discoverable surface honest about the same destinations and no-ops.
struct IOSMeetingMoveActions: View {
    private let destinations: [IOSSidebarMoveDestination]
    private let move: (FolderID?) -> Void

    init(
        policy: IOSSidebarMeetingActionPolicy,
        move: @escaping (FolderID?) -> Void
    ) {
        destinations = Self.destinations(for: policy)
        self.move = move
    }

    nonisolated static func destinations(
        for policy: IOSSidebarMeetingActionPolicy
    ) -> [IOSSidebarMoveDestination] {
        policy.moveDestinations
    }

    var body: some View {
        ForEach(destinations) { destination in
            Button(destination.title) {
                move(destination.folderID)
            }
            .disabled(destination.isCurrent)
        }
    }
}
