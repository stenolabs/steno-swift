import StenoDomain
import StenoIdentity
import StenoPipeline
import SwiftUI

/// Participant summary for the iPad inspector. Evidence-backed speakers and
/// manually added attendees stay visibly separate; only the latter can be
/// removed in the editor.
struct MeetingParticipantsSection: View {
    @Environment(AppModel.self) private var app
    let meeting: Meeting?
    let review: MeetingReviewData?

    @State private var allPersons: [Person] = []
    @State private var loadState = MeetingParticipantsLoadState()
    @State private var isShowingEditor = false

    var body: some View {
        let currentReloadKey = reloadKey
        let isLoading = loadState.isLoading(currentKey: currentReloadKey)
        let sections = MeetingParticipantsPresentation.sections(
            meeting: meeting,
            persons: allPersons,
            clusters: review?.clusters ?? [],
            reviewRunID: review?.runID
        )
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Participants")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingEditor = true
                } label: {
                    Label(
                        "Edit Participants",
                        systemImage: "person.2.badge.gearshape"
                    )
                    .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(meeting == nil || isLoading)
                .accessibilityIdentifier("edit-participants")
            }

            if let error = loadState.error(for: currentReloadKey) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    loadState.retry(key: currentReloadKey)
                }
                .buttonStyle(.bordered)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading participants…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if sections.isEmpty, !sections.hasUnresolvedPeople {
                Text("No confirmed or saved participants yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !sections.isEmpty {
                participantRows(sections)
            }

            if !isLoading, sections.hasUnresolvedPeople {
                Label(
                    "Some saved participants could not be found.",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: loadState.taskID(currentKey: currentReloadKey)) {
            let load = loadState.begin(key: currentReloadKey)
            do {
                let persons = try await app.allPersons()
                guard !Task.isCancelled else {
                    loadState.cancel(load)
                    return
                }
                guard loadState.succeed(
                    load,
                    currentKey: reloadKey
                ) else { return }
                allPersons = persons
            } catch {
                guard !Task.isCancelled else {
                    loadState.cancel(load)
                    return
                }
                loadState.fail(
                    load,
                    currentKey: reloadKey,
                    message: "Participants could not be loaded: "
                        + error.localizedDescription
                )
            }
        }
        .sheet(isPresented: $isShowingEditor) {
            if let meeting {
                MeetingParticipantEditorSheet(meetingID: meeting.id)
            }
        }
    }

    @ViewBuilder
    private func participantRows(
        _ sections: MeetingParticipantSections
    ) -> some View {
        if !sections.speakers.isEmpty {
            Text("Speakers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sections.speakers) { participant in
                participantLabel(participant, systemImage: "waveform")
            }
        }
        if !sections.additional.isEmpty {
            Text("Additional")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, sections.speakers.isEmpty ? 0 : 4)
            ForEach(sections.additional) { participant in
                participantLabel(participant, systemImage: "person")
            }
        }
    }

    private func participantLabel(
        _ participant: MeetingParticipantRow,
        systemImage: String
    ) -> some View {
        Label(participant.name, systemImage: systemImage)
            .font(.callout)
            .accessibilityIdentifier("participant-\(participant.personID)")
    }

    private var reloadKey: String {
        let meetingIDs = (meeting?.participantIDs ?? [])
            + (meeting?.additionalParticipantIDs ?? [])
        let confirmed = (review?.clusters ?? []).compactMap { cluster -> String? in
            guard MeetingParticipantsPresentation.isNamedParticipant(
                cluster,
                meetingID: meeting?.id,
                reviewRunID: review?.runID
            ),
                  case .confirmed(let personID) = cluster.reviewState else { return nil }
            return "\(cluster.runID)/\(cluster.channel)/\(cluster.clusterID)/\(personID)"
        }
        let personsRevision = review?.personsRevision?.uuidString ?? ""
        return (meetingIDs.map(\.description) + confirmed + [personsRevision])
            .sorted()
            .joined(separator: "|")
    }
}

struct MeetingParticipantsLoadState: Equatable {
    struct Load: Equatable, Sendable {
        let key: String
        let generation: UInt64
    }

    private(set) var loadedKey: String?
    private var activeLoad: Load?
    private var failedKey: String?
    private var failureMessage: String?
    private var retryGeneration: UInt64 = 0
    private var nextLoadGeneration: UInt64 = 0

    func taskID(currentKey: String) -> String {
        "\(currentKey)#\(retryGeneration)"
    }

    func isLoading(currentKey: String) -> Bool {
        activeLoad?.key == currentKey
            || (loadedKey != currentKey && failedKey != currentKey)
    }

    func error(for key: String) -> String? {
        failedKey == key ? failureMessage : nil
    }

    mutating func begin(key: String) -> Load {
        nextLoadGeneration &+= 1
        let load = Load(key: key, generation: nextLoadGeneration)
        activeLoad = load
        if failedKey == key {
            failedKey = nil
            failureMessage = nil
        }
        return load
    }

    @discardableResult
    mutating func succeed(_ load: Load, currentKey: String) -> Bool {
        guard activeLoad == load, load.key == currentKey else { return false }
        loadedKey = load.key
        activeLoad = nil
        if failedKey == load.key {
            failedKey = nil
            failureMessage = nil
        }
        return true
    }

    @discardableResult
    mutating func fail(
        _ load: Load,
        currentKey: String,
        message: String
    ) -> Bool {
        guard activeLoad == load, load.key == currentKey else { return false }
        activeLoad = nil
        failedKey = load.key
        failureMessage = message
        return true
    }

    mutating func cancel(_ load: Load) {
        guard activeLoad == load else { return }
        activeLoad = nil
    }

    mutating func retry(key: String) {
        if failedKey == key {
            failedKey = nil
            failureMessage = nil
        }
        retryGeneration &+= 1
    }
}

enum MeetingParticipantRole: Equatable, Sendable {
    case speaker
    case additional
}

struct MeetingParticipantRow: Equatable, Identifiable, Sendable {
    let personID: PersonID
    let name: String
    let role: MeetingParticipantRole

    var id: PersonID { personID }
    var canRemove: Bool { role == .additional }
}

struct MeetingParticipantSections: Equatable, Sendable {
    let speakers: [MeetingParticipantRow]
    let additional: [MeetingParticipantRow]
    let hasUnresolvedPeople: Bool

    var isEmpty: Bool { speakers.isEmpty && additional.isEmpty }
}

enum MeetingParticipantsPresentation {

    static func isLoading(loadedKey: String?, currentKey: String) -> Bool {
        loadedKey != currentKey
    }

    static func sections(
        meeting: Meeting?,
        review: MeetingReviewData?
    ) -> MeetingParticipantSections {
        guard let review else {
            return sections(
                meeting: meeting,
                persons: [],
                clusters: [],
                reviewRunID: nil
            )
        }
        return sections(
            meeting: meeting,
            persons: review.persons,
            clusters: review.clusters,
            reviewRunID: review.runID
        )
    }

    static func sections(
        meeting: Meeting?,
        persons: [Person],
        clusters: [IdentityCluster],
        reviewRunID: RunID?
    ) -> MeetingParticipantSections {
        let confirmedIDs = clusters.compactMap { cluster -> PersonID? in
            guard isNamedParticipant(
                cluster,
                meetingID: meeting?.id,
                reviewRunID: reviewRunID
            ), case .confirmed(let personID) = cluster.reviewState
            else { return nil }
            return personID
        }
        let requestedSpeakerIDs = (meeting?.participantIDs ?? []) + confirmedIDs
        let speakerIDs = deduplicated(requestedSpeakerIDs)
        let speakerSet = Set(speakerIDs)
        let additionalIDs = deduplicated(
            meeting?.additionalParticipantIDs ?? []
        ).filter { !speakerSet.contains($0) }

        let peopleByID = persons.reduce(into: [PersonID: Person]()) {
            $0[$1.id] = $1
        }
        let speakers = sortedRows(
            speakerIDs.compactMap { personID in
                peopleByID[personID].map {
                    MeetingParticipantRow(
                        personID: personID,
                        name: $0.displayName,
                        role: .speaker
                    )
                }
            }
        )
        let additional = sortedRows(
            additionalIDs.compactMap { personID in
                peopleByID[personID].map {
                    MeetingParticipantRow(
                        personID: personID,
                        name: $0.displayName,
                        role: .additional
                    )
                }
            }
        )
        let requestedIDs = speakerIDs + additionalIDs
        return MeetingParticipantSections(
            speakers: speakers,
            additional: additional,
            hasUnresolvedPeople: requestedIDs.contains {
                peopleByID[$0] == nil
            }
        )
    }

    private static func sortedRows(
        _ rows: [MeetingParticipantRow]
    ) -> [MeetingParticipantRow] {
        rows.sorted { lhs, rhs in
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.personID < rhs.personID
        }
    }

    private static func deduplicated(
        _ personIDs: [PersonID]
    ) -> [PersonID] {
        var seen: Set<PersonID> = []
        return personIDs.filter {
            seen.insert($0).inserted
        }
    }

    static func isNamedParticipant(
        _ cluster: IdentityCluster,
        meetingID: MeetingID?,
        reviewRunID: RunID?
    ) -> Bool {
        guard let reviewRunID,
              cluster.runID == reviewRunID,
              meetingID.map({ cluster.meetingID == $0 }) ?? true,
              case .confirmed = cluster.reviewState
        else { return false }
        return !cluster.isSelf
            && !cluster.containsMultipleSpeakers
    }
}
