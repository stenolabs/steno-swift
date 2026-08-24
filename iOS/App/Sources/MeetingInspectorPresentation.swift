import StenoDomain

/// Keeps the one-time automatic opening policy separate from SwiftUI's
/// presentation binding. Ordinary meetings leave the existing inspector state
/// alone; a newly loaded draft brings its notes into view once.
///
/// A draft is a meeting without a recording yet: nothing to show but notes,
/// so opening the inspector is the whole point of loading it. Any other
/// meeting is left exactly as the user left the inspector - a draft opening
/// once must never turn into every meeting reopening it on every reload.
struct MeetingInspectorPresentation {
    private var automaticallyConsideredMeetingIDs: Set<MeetingID> = []

    static func shouldOpenAutomatically(status: Meeting.Status?) -> Bool {
        status == .draft
    }

    mutating func shouldOpen(
        for meetingID: MeetingID,
        status: Meeting.Status?,
        inspectorWasAlreadyPresented: Bool = false
    ) -> Bool {
        guard automaticallyConsideredMeetingIDs.insert(meetingID).inserted else {
            return false
        }
        return !inspectorWasAlreadyPresented
            && Self.shouldOpenAutomatically(status: status)
    }
}
