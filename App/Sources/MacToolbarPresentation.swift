import SwiftUI

enum MacToolbarID: String, CaseIterable {
    case main
    case sidebar
    case meetingDetail
    case recording
}

enum MacToolbarItemID: String, CaseIterable {
    case recording
    case microphoneSelection
    case newMeeting
    case importMeeting
    case newFolder
    case findTranscript
    case inspector
    case shareMeeting
    case continueRecording
    case recordingNotes
}

enum MacToolbarContext {
    case main
    case sidebar
    case meetingDetail
    case recording
}

enum MacToolbarPresentation {
    /// Import remains one menu because the three formats are alternatives,
    /// not three independent primary actions.
    static let importSurfaceCount = 1

    static func showsByDefault(
        _ item: MacToolbarItemID,
        in context: MacToolbarContext
    ) -> Bool {
        switch (item, context) {
        case (.recording, .main),
             (.importMeeting, .main),
             (.inspector, .meetingDetail):
            true
        case (.microphoneSelection, .main),
             (.newMeeting, .main),
             (.recordingNotes, .recording),
             (.newFolder, .sidebar),
             (.findTranscript, .meetingDetail),
             (.shareMeeting, .meetingDetail),
             (.recordingNotes, .recording):
            false
        case (.continueRecording, .meetingDetail):
            true
        default:
            false
        }
    }

    static func defaultCustomization(
        for item: MacToolbarItemID,
        in context: MacToolbarContext
    ) -> Visibility {
        showsByDefault(item, in: context) ? .visible : .hidden
    }
}
