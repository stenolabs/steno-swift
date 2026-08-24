import StenoDomain
import StenoIdentity
import StenoPipeline
import SwiftUI

enum SpeakerReviewPresentation {
    struct ReviewProgress: Equatable {
        let reviewed: Int
        let total: Int
    }

    static func reviewProgress(
        for clusters: [IdentityCluster]
    ) -> ReviewProgress? {
        let relevant = clusters.filter { !$0.isSelf }
        guard !relevant.isEmpty else { return nil }
        return ReviewProgress(
            reviewed: relevant.filter { $0.reviewState != .unreviewed }.count,
            total: relevant.count
        )
    }

    static func canLeaveGeneric(_ cluster: IdentityCluster) -> Bool {
        !cluster.isSelf
            && !cluster.containsMultipleSpeakers
            && cluster.reviewState == .unreviewed
    }
}

/// Sprecher-Panel im Meeting-Detail: Cluster nach Sprechzeit absteigend,
/// Vorschlag samt Status, Aktionen. Nichts wird automatisch benannt.
struct SpeakerReviewSection: View {
    @Environment(AppModel.self) private var model
    let meetingID: MeetingID
    let revision: TranscriptRevision?
    @Binding var review: MeetingReviewData?
    var isDemo = false

    @State private var newPersonName = ""
    @State private var newPersonCluster: IdentityCluster?

    var body: some View {
        if let review {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Speakers")
                        .font(.headline)
                    // Wiederholte Routinearbeit braucht ein sichtbares Ende.
                    if isDemo {
                        if let progress = SpeakerReviewPresentation.reviewProgress(
                            for: review.clusters
                        ) {
                            Text(DemoDataPresentation.reviewProgressTitle(progress))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else if let progress = assignmentProgress(review) {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if isDemo {
                    Label(
                        DemoDataPresentation.voiceEvidenceExplanation,
                        systemImage: "person.crop.circle.badge.xmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(sortedClusters(review), id: \.id) { cluster in
                    clusterRow(cluster, review: review)
                }
                if let error = model.reviewError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Steno.Colors.error)
                }
            }
            .sheet(item: $newPersonCluster) { cluster in
                newPersonSheet(cluster)
            }
            .onDisappear { model.stopSamplePlayback() }
        }
    }

    private func assignmentProgress(_ review: MeetingReviewData) -> String? {
        let nameable = review.clusters.filter {
            !$0.isSelf && !$0.containsMultipleSpeakers
        }
        guard !nameable.isEmpty else { return nil }
        let confirmed = nameable.filter { isConfirmed($0) }.count
        return confirmed == nameable.count
            ? "all assigned"
            : "\(confirmed) of \(nameable.count) assigned"
    }

    private func sortedClusters(_ review: MeetingReviewData) -> [IdentityCluster] {
        review.clusters
            .filter { !$0.isSelf }
            .sorted { $0.speechDurationSeconds > $1.speechDurationSeconds }
    }

    private func clusterRow(
        _ cluster: IdentityCluster,
        review: MeetingReviewData
    ) -> some View {
        let suggestion = review.suggestions.first {
            $0.clusterID == cluster.clusterID && $0.channel == cluster.channel
        }
        let presentation = SpeakerPresentationResolver.presentation(for: cluster, review: review)
        let samples = revision.map {
            SpeakerSampleSelector.samples(
                for: cluster,
                revision: $0,
                resolutions: review.resolutions
            )
        } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
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
                    }
                    HStack(spacing: 6) {
                        Text(durationText(cluster.speechDurationSeconds))
                        Text("·")
                        Text(channelText(cluster.channel))
                        if case .unreviewed = cluster.reviewState,
                           let suggestion, suggestion.status == .possible,
                           let name = suggestion.suggestedName {
                            Text("·")
                            Text("Maybe \(name)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                actions(for: cluster, suggestion: suggestion, review: review)
            }
            if let first = samples.first {
                SampleRow(sample: first, meetingID: meetingID)
                if samples.count > 1 {
                    DisclosureGroup("More voice samples (\(samples.count - 1))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(samples.dropFirst()) { sample in
                                SampleRow(sample: sample, meetingID: meetingID)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actions(
        for cluster: IdentityCluster,
        suggestion: ClusterSuggestion?,
        review: MeetingReviewData
    ) -> some View {
        if isDemo {
            if SpeakerReviewPresentation.canLeaveGeneric(cluster) {
                Button(DemoDataPresentation.leaveGenericAction) {
                    perform(.keepGeneric, on: cluster)
                }
                .controlSize(.small)
            }
        } else if cluster.containsMultipleSpeakers {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                // Ein bestätigter Cluster zeigt seinen Zustand und behält das
                // Menü: Wer im Routinetempo danebenklickt, braucht einen
                // sichtbaren Rückweg, und die Fehlzuordnung hängt Prototypen
                // an die falsche Person.
                if isConfirmed(cluster) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Steno.Colors.confirmed)
                        .accessibilityLabel("Confirmed")
                        .help("Confirmed - correctable from the menu")
                } else if let suggestion,
                          suggestion.status == .confirmed || suggestion.status == .possible,
                          let personID = suggestion.suggestedPersonID,
                          let name = suggestion.suggestedName {
                    // Auch ein unsicherer Vorschlag ist mit einem Klick
                    // bestätigbar; die Sicherheit steckt in der Betonung des
                    // Knopfes, nicht darin, ob es ihn gibt.
                    confirmButton(
                        name: name,
                        personID: personID,
                        cluster: cluster,
                        isSure: suggestion.status == .confirmed
                    )
                }
                Menu {
                    assignmentMenu(for: cluster, review: review)
                } label: {
                    Label(
                        isConfirmed(cluster) ? "Change" : "Assign",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    /// Sicherer Vorschlag betont, unsicherer schlicht - beide mit einem Klick.
    @ViewBuilder
    private func confirmButton(
        name: String,
        personID: PersonID,
        cluster: IdentityCluster,
        isSure: Bool
    ) -> some View {
        let action = { perform(.confirm(personID: personID), on: cluster) }
        let hint = isSure
            ? "Confident suggestion from the voice comparison"
            : "Lower-confidence suggestion - worth listening first"
        if isSure {
            Button("Confirm as \(name)", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(hint)
        } else {
            Button("Confirm as \(name)", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(hint)
        }
    }

    private func isConfirmed(_ cluster: IdentityCluster) -> Bool {
        if case .confirmed = cluster.reviewState { return true }
        return false
    }

    @ViewBuilder
    private func assignmentMenu(
        for cluster: IdentityCluster,
        review: MeetingReviewData
    ) -> some View {
        // Bereits in diesem Meeting bestätigte Personen zuerst: die faule
        // Alternative "Neue Person" würde eine Stimme als zwei Personen
        // speichern und sie zum Hard Negative gegen sich selbst machen.
        let confirmedHere = Set(review.clusters.compactMap { other -> PersonID? in
            if case .confirmed(let id) = other.reviewState { return id }
            return nil
        })
        let ordered = review.persons.sorted { lhs, rhs in
            let lhsHere = confirmedHere.contains(lhs.id)
            let rhsHere = confirmedHere.contains(rhs.id)
            if lhsHere != rhsHere { return lhsHere }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        ForEach(ordered, id: \.id) { person in
            Button {
                // Umhängen ist nur eine Korrektur einer bestehenden
                // Zuordnung; ein noch unbestätigter Cluster wird bestätigt.
                // Sonst schlägt die Aktion mit "nichts zum Umhängen" fehl.
                perform(
                    isConfirmed(cluster)
                        ? .reassign(personID: person.id)
                        : .confirm(personID: person.id),
                    on: cluster
                )
            } label: {
                if person.id == confirmedPerson(cluster) {
                    Label("\(entry(person)) (current)", systemImage: "checkmark")
                } else if confirmedHere.contains(person.id) {
                    Text("\(entry(person)) (in this meeting)")
                } else {
                    Text(entry(person))
                }
            }
            // Dieselbe Person erneut zuzuweisen wäre kein Umhängen; die
            // Engine lehnt es mit "nichts zum Umhängen" ab.
            .disabled(person.id == confirmedPerson(cluster))
        }
        if !ordered.isEmpty { Divider() }
        Button("New person…") {
            newPersonName = ""
            newPersonCluster = cluster
        }
        Divider()
        Button("Multiple people in this cluster") {
            perform(.markMultiple, on: cluster)
        }
        // Zwei verschiedene Dinge, die gleich klingen: "generisch belassen"
        // setzt bei einem unbestätigten Cluster nur den Zustand um, während
        // "Zuordnung zurücknehmen" die Evidenz einer bestätigten Person
        // ausnimmt und die abgeleiteten Negative neu aufbaut. Vorher blieb
        // dafür nur der Umweg über "mehrere Personen" - eine Aussage über den
        // Cluster, die gar nicht stimmen musste.
        if isConfirmed(cluster) {
            Button("Reset to generic") {
                perform(.resetToGeneric, on: cluster)
            }
        } else if SpeakerReviewPresentation.canLeaveGeneric(cluster) {
            Button("Leave generic") {
                perform(.keepGeneric, on: cluster)
            }
        }
    }

    /// Wird die Personenliste lang, reicht der Name nicht mehr: Zwei Menschen
    /// gleichen Namens sind in einer wachsenden Stimmdatenbank der Normalfall,
    /// nicht die Ausnahme. Die Adresse steht deshalb direkt neben dem Namen -
    /// sie ist hier Unterscheidungsmerkmal, nicht Kontaktdatum.
    private func entry(_ person: Person) -> String {
        let marks = [person.organization, person.email].compactMap { $0 }
        guard !marks.isEmpty else { return person.displayName }
        return "\(person.displayName)  ·  \(marks.joined(separator: "  ·  "))"
    }

    private func confirmedPerson(_ cluster: IdentityCluster) -> PersonID? {
        if case .confirmed(let personID) = cluster.reviewState { return personID }
        return nil
    }

    private func newPersonSheet(_ cluster: IdentityCluster) -> some View {
        VStack(spacing: 12) {
            Text("Name new person")
                .font(.headline)
            TextField("Name", text: $newPersonName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { submitNewPerson(cluster) }
            HStack {
                Button("Cancel") { newPersonCluster = nil }
                Button("Create and confirm") { submitNewPerson(cluster) }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func submitNewPerson(_ cluster: IdentityCluster) {
        let name = newPersonName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newPersonCluster = nil
        perform(.confirmAsNewPerson(name: name), on: cluster)
    }

    private func perform(
        _ action: MeetingReviewController.Action,
        on cluster: IdentityCluster
    ) {
        guard let current = review else { return }
        Task {
            if let updated = await model.performReview(
                action,
                on: cluster,
                data: current,
                meetingID: meetingID
            ) {
                review = updated
            }
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60
            ? String(format: "%d:%02d min", total / 60, total % 60)
            : "\(total) s"
    }

    private func channelText(_ channel: String) -> String {
        switch channel {
        case MediaAsset.Kind.micTrack.rawValue: "Microphone"
        case MediaAsset.Kind.systemTrack.rawValue: "System"
        default: "Import"
        }
    }
}

/// Eine Hörprobe: Play/Stop, Zeitstempel, Zitat. Text und Audio kommen aus
/// demselben Turn der Revision.
struct SampleRow: View {
    @Environment(AppModel.self) private var model
    let sample: SpeakerSample
    let meetingID: MeetingID

    var body: some View {
        // Oben ausrichten statt an der Grundlinie: Bei mehrzeiligem Zitat
        // berechnet die Grundlinien-Ausrichtung die Zeilenhoehe nur nach der
        // ersten Zeile, die Folgezeilen ueberlappen dann die naechste Zeile.
        HStack(alignment: .top, spacing: 8) {
            if model.meetingsWithAudio.contains(meetingID) {
                Button {
                    Task { await model.toggleSample(sample, meetingID: meetingID) }
                } label: {
                    Image(systemName: isPlaying
                        ? "stop.circle.fill"
                        : "play.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(isPlaying ? Steno.Colors.recording : .secondary)
                // Abspielen liefe ueber den Systemaudio-Tap in die laufende
                // Aufnahme hinein.
                .disabled(model.isRecording)
                .help(model.isRecording
                    ? "Not while recording - it would be captured into the recording"
                    : (isPlaying ? "Stop playback" : "Play sample"))
                .accessibilityLabel(isPlaying ? "Stop playback" : "Play voice sample")
            }
            Text(timestamp(sample.clipStart))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text("\u{201E}\(sample.text)\u{201C}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isPlaying: Bool { model.playingSampleID == sample.id }

    private func timestamp(_ seconds: TimeInterval) -> String {
        // Ab einer Stunde ist "1:12:45" lesbar, "72:45" nicht mehr.
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

extension IdentityCluster: @retroactive Identifiable {
    public var id: String { "\(channel)/\(clusterID)" }
}
