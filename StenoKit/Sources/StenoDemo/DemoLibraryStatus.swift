import Foundation
import StenoDomain

public enum DemoLibraryItemState: Equatable, Sendable {
    case missing
    case installed
    case modified
    case outdated(installedVersion: String)
    case conflictingMeeting
}

public struct DemoLibraryItemStatus: Equatable, Sendable {
    public let meetingID: MeetingID
    public let itemID: String
    public let state: DemoLibraryItemState

    public init(meetingID: MeetingID, itemID: String, state: DemoLibraryItemState) {
        self.meetingID = meetingID
        self.itemID = itemID
        self.state = state
    }
}

public struct DemoLibraryStatus: Equatable, Sendable {
    public let datasetID: String
    public let datasetVersion: String
    public let items: [DemoLibraryItemStatus]

    public init(datasetID: String, datasetVersion: String, items: [DemoLibraryItemStatus]) {
        self.datasetID = datasetID
        self.datasetVersion = datasetVersion
        self.items = items
    }
}

public enum DemoReplacementPolicy: Equatable, Sendable {
    case keepModifiedMeetings
    case replaceModifiedMeetings
}

public struct DemoLifecycleResult: Equatable, Sendable {
    public let completedItems: [String]
    public let skippedItems: [String]
    public let retainedItems: [String]
    public let uncertainItems: [String]
    public let remainingItems: [String]

    public init(
        completedItems: [String] = [],
        skippedItems: [String] = [],
        retainedItems: [String] = [],
        uncertainItems: [String] = [],
        remainingItems: [String] = []
    ) {
        self.completedItems = completedItems.sorted()
        self.skippedItems = skippedItems.sorted()
        self.retainedItems = retainedItems.sorted()
        self.uncertainItems = uncertainItems.sorted()
        self.remainingItems = remainingItems.sorted()
    }
}
