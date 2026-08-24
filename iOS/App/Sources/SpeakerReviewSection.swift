import Foundation
import StenoDomain
import StenoIdentity
import StenoPipeline
import SwiftUI

struct NewPersonReviewContext: Identifiable {
    let id = UUID()
    let cluster: IdentityCluster
    let review: MeetingReviewData
}

/// Truthful speaker review for the iPad inspector.
///
/// There is intentionally no playback here. Every mutation goes through the
/// opaque assembler snapshot and `MeetingReviewController` owned by AppModel.
struct SpeakerReviewSection: View {
    @Environment(AppModel.self) private var app
    let meetingID: MeetingID
    let review: MeetingReviewData?
    let isDemoMeeting: Bool

    @State private var newPersonContext: NewPersonReviewContext?
    @State private var newPersonName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speakers")
                    .font(.headline)
                Spacer()
                if app.isReviewBusy(meetingID) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving speaker review")
                }
            }

            if isDemoMeeting,
               let explanation = SpeakerReviewPresentation.demoExplanation {
                Label(explanation, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let current = review {
                let clusters = sortedClusters(current)
                ForEach(Array(clusters.enumerated()), id: \.offset) { index, cluster in
                    clusterRow(cluster, review: current)
                    if index < clusters.count - 1 {
                        Divider()
                    }
                }

            }

            if let error = app.reviewError(for: meetingID) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(app.isReviewBusy(meetingID))
        .sheet(item: $newPersonContext) { context in
            newPersonSheet(context)
        }
    }

    private func sortedClusters(_ data: MeetingReviewData) -> [IdentityCluster] {
        data.clusters
            .filter { !$0.isSelf }
            .sorted { lhs, rhs in
                if lhs.speechDurationSeconds != rhs.speechDurationSeconds {
                    return lhs.speechDurationSeconds > rhs.speechDurationSeconds
                }
                if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
                return lhs.clusterID < rhs.clusterID
            }
    }

    private func clusterRow(
        _ cluster: IdentityCluster,
        review data: MeetingReviewData
    ) -> some View {
        let suggestion = SpeakerReviewPresentation.suggestion(
            for: cluster,
            in: data.suggestions,
            reviewRunID: data.runID
        )
        let actionableSuggestion = SpeakerReviewPresentation.actionableSuggestion(
            suggestion,
            persons: data.persons
        )
        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: actionableSuggestion,
            persons: data.persons,
            evidenceMutationIsAllowed: !isDemoMeeting
        )
        let presentation = SpeakerPresentationResolver.presentation(
            for: cluster,
            review: data
        )

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let color = Steno.Colors.speaker(presentation.marker) {
                            Circle()
                                .fill(color)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(
                            SpeakerDisplayLocalization.label(presentation)
                                ?? cluster.clusterID
                        )
                            .font(.callout.weight(.semibold))
                    }
                    HStack(spacing: 5) {
                        Text(durationText(cluster.speechDurationSeconds))
                        Text("·")
                        Text(channelText(cluster.channel))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let guess = SpeakerReviewPresentation.suggestionLabel(suggestion) {
                        Text(guess)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("possible-speaker-suggestion")
                    }
                }
                Spacer()
                actionControls(
                    actions,
                    cluster: cluster,
                    suggestion: actionableSuggestion,
                    review: data
                )
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionControls(
        _ actions: [SpeakerReviewPresentation.Action],
        cluster: IdentityCluster,
        suggestion: ClusterSuggestion?,
        review data: MeetingReviewData
    ) -> some View {
        HStack(spacing: 6) {
            if actions.contains(.confirmSuggestion),
               let personID = suggestion?.suggestedPersonID,
               let person = data.persons.first(where: { $0.id == personID }) {
                Button("Confirm \(person.displayName)") {
                    perform(.confirm(personID: personID), on: cluster, data: data)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if !actions.isEmpty {
                Menu {
                    actionMenu(actions, cluster: cluster, review: data)
                } label: {
                    Label("Review", systemImage: "person.crop.circle.badge.checkmark")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Review speaker")
            }
        }
    }

    @ViewBuilder
    private func actionMenu(
        _ actions: [SpeakerReviewPresentation.Action],
        cluster: IdentityCluster,
        review data: MeetingReviewData
    ) -> some View {
        if actions.contains(.assignPerson) || actions.contains(.reassignPerson) {
            let people = sortedPeople(data.persons)
            if people.isEmpty {
                Text("No saved people")
            } else {
                ForEach(people) { person in
                    Button(personEntry(person, among: people)) {
                        let action: MeetingReviewController.Action = actions.contains(
                            .reassignPerson
                        )
                            ? .reassign(personID: person.id)
                            : .confirm(personID: person.id)
                        perform(action, on: cluster, data: data)
                    }
                    .disabled(confirmedPerson(cluster) == person.id)
                }
            }
        }

        if actions.contains(.createPerson) {
            Button("New person…") {
                newPersonName = ""
                newPersonContext = NewPersonReviewContext(
                    cluster: cluster,
                    review: data
                )
            }
        }

        if actions.contains(.markMultiple) {
            Divider()
            Button("Multiple people") {
                perform(.markMultiple, on: cluster, data: data)
            }
        }

        if actions.contains(.keepGeneric) {
            Button("Keep generic") {
                perform(.keepGeneric, on: cluster, data: data)
            }
        }

        if actions.contains(.resetToGeneric) {
            Divider()
            Button("Reset to generic", role: .destructive) {
                perform(.resetToGeneric, on: cluster, data: data)
            }
        }
    }

    private func newPersonSheet(_ context: NewPersonReviewContext) -> some View {
        NavigationStack {
            Form {
                TextField("Name", text: $newPersonName)
                    .textInputAutocapitalization(.words)
                    .onSubmit { submitNewPerson(context) }
            }
            .navigationTitle("New person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        newPersonContext = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submitNewPerson(context) }
                        .disabled(trimmedNewPersonName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var trimmedNewPersonName: String {
        newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitNewPerson(_ context: NewPersonReviewContext) {
        guard !trimmedNewPersonName.isEmpty else { return }
        let name = trimmedNewPersonName
        newPersonContext = nil
        perform(
            .confirmAsNewPerson(name: name),
            on: context.cluster,
            data: context.review
        )
    }

    private func perform(
        _ action: MeetingReviewController.Action,
        on cluster: IdentityCluster,
        data: MeetingReviewData
    ) {
        Task { @MainActor in
            _ = await app.performReviewUpdate(
                action,
                on: cluster,
                data: data,
                meetingID: meetingID
            )
        }
    }

    private func sortedPeople(_ people: [Person]) -> [Person] {
        people.sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
                rhs.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private func personEntry(_ person: Person, among people: [Person]) -> String {
        let sameNameCount = people.filter {
            $0.displayName.localizedCaseInsensitiveCompare(person.displayName)
                == .orderedSame
        }.count
        let details = [person.organization, person.email].compactMap { $0 }
        if !details.isEmpty {
            return "\(person.displayName) · \(details.joined(separator: " · "))"
        }
        guard sameNameCount > 1 else { return person.displayName }
        return "\(person.displayName) · \(person.id.description.prefix(8))"
    }

    private func confirmedPerson(_ cluster: IdentityCluster) -> PersonID? {
        guard case .confirmed(let personID) = cluster.reviewState else {
            return nil
        }
        return personID
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 60 { return "\(total / 60):\(String(format: "%02d", total % 60)) min" }
        return "\(total) s"
    }

    private func channelText(_ channel: String) -> String {
        switch channel {
        case "mic", MediaAsset.Kind.micTrack.rawValue:
            "Microphone"
        case "system", MediaAsset.Kind.systemTrack.rawValue:
            "System"
        default:
            "Import"
        }
    }
}
