import Foundation
import StenoDomain
@testable import StenoIdentity

func embedding(atCosineDistance distance: Float) -> [Float] {
    let cosine = 1 - distance
    return [cosine, max(0, 1 - cosine * cosine).squareRoot()]
}

func makeCluster(
    meetingID: MeetingID,
    runID: RunID,
    channel: String = "system",
    clusterID: String,
    recordingType: RecordingType = .remote,
    distance: Float = 0,
    duration: TimeInterval = 24,
    segments: Int = 4,
    multiple: Bool = false,
    isSelf: Bool = false
) -> IdentityCluster {
    IdentityCluster(
        meetingID: meetingID,
        runID: runID,
        channel: channel,
        clusterID: clusterID,
        recordingType: recordingType,
        embedding: embedding(atCosineDistance: distance),
        speechDurationSeconds: duration,
        segmentCount: segments,
        containsMultipleSpeakers: multiple,
        isSelf: isSelf
    )
}

func makePrototype(
    personID: PersonID,
    meetingID: MeetingID?,
    runID: RunID? = RunID(),
    channel: String = "system",
    clusterID: String = "enrollment",
    recordingType: RecordingType = .remote,
    distance: Float = 0
) -> SpeakerPrototype {
    SpeakerPrototype(
        personID: personID,
        embedding: embedding(atCosineDistance: distance),
        recordingType: recordingType,
        channel: channel,
        meetingID: meetingID,
        runID: runID,
        clusterID: clusterID,
        speechDurationSeconds: 24,
        segmentCount: 4,
        source: .userConfirmed
    )
}

func makeKnownPerson(
    name: String,
    prototypeDistances: [Float] = [0],
    meetingIDs: [MeetingID]? = nil,
    recordingType: RecordingType = .remote
) -> Person {
    let personID = PersonID()
    let meetings = meetingIDs ?? prototypeDistances.map { _ in MeetingID() }
    return Person(
        id: personID,
        displayName: name,
        prototypes: zip(prototypeDistances, meetings).enumerated().map { index, pair in
            makePrototype(
                personID: personID,
                meetingID: pair.1,
                clusterID: "prototype-\(index)",
                recordingType: recordingType,
                distance: pair.0
            )
        }
    )
}

func person(_ id: PersonID, in state: IdentityReviewState) -> Person? {
    state.persons.first { $0.id == id }
}
