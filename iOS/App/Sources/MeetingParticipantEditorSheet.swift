import StenoDomain
import StenoIdentity
import StenoPipeline
import SwiftUI

struct MeetingParticipantEditorReloadTask: Hashable, Sendable {
    let meetingID: MeetingID
    let publicationIdentity: MeetingReviewPublicationIdentity?

    var loadKey: String {
        publicationIdentity?.loadKey ?? "\(meetingID)|publication-missing"
    }
}

struct MeetingParticipantEditorPersonLoadCoordinator: Equatable {
    struct Request: Equatable, Sendable {
        let task: MeetingParticipantEditorReloadTask
        fileprivate let load: MeetingParticipantsLoadState.Load
    }

    private var loadState = MeetingParticipantsLoadState()

    func isLoading(for task: MeetingParticipantEditorReloadTask) -> Bool {
        loadState.isLoading(currentKey: task.loadKey)
    }

    mutating func begin(
        _ task: MeetingParticipantEditorReloadTask
    ) -> Request {
        Request(task: task, load: loadState.begin(key: task.loadKey))
    }

    @discardableResult
    mutating func accept(
        _ request: Request,
        currentTask: MeetingParticipantEditorReloadTask
    ) -> Bool {
        guard request.task == currentTask else { return false }
        return loadState.succeed(request.load, currentKey: currentTask.loadKey)
    }

    @discardableResult
    mutating func fail(
        _ request: Request,
        currentTask: MeetingParticipantEditorReloadTask,
        message: String
    ) -> Bool {
        guard request.task == currentTask else { return false }
        return loadState.fail(
            request.load,
            currentKey: currentTask.loadKey,
            message: message
        )
    }

    mutating func cancel(_ request: Request) {
        loadState.cancel(request.load)
    }
}

/// Edits only manual attendance. Speaker-backed participants are deliberately
/// read-only here because changing them belongs to speaker review and may
/// create or exempt voice evidence.
struct MeetingParticipantEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let meetingID: MeetingID

    @State private var persons: [Person] = []
    @State private var newName = ""
    @State private var errorMessage: String?
    @State private var personLoadError: String?
    @State private var personLoadCoordinator =
        MeetingParticipantEditorPersonLoadCoordinator()
    @State private var isMutating = false
    @FocusState private var newNameIsFocused: Bool

    private var publication: AppModel.MeetingReviewPublication? {
        app.meetingReviewPublication(for: meetingID)
    }

    private var publicationIdentity: MeetingReviewPublicationIdentity? {
        app.meetingReviewPublicationIdentity(for: meetingID)
    }

    private var reloadTask: MeetingParticipantEditorReloadTask {
        MeetingParticipantEditorReloadTask(
            meetingID: meetingID,
            publicationIdentity: publicationIdentity
        )
    }

    private var meeting: Meeting? { publication?.meeting }
    private var review: MeetingReviewData? { publication?.review }

    private var sections: MeetingParticipantSections {
        MeetingParticipantsPresentation.sections(
            meeting: meeting,
            persons: persons,
            clusters: review?.clusters ?? [],
            reviewRunID: review?.runID
        )
    }

    private var includedPersonIDs: Set<PersonID> {
        Set(
            sections.speakers.map(\.personID)
                + sections.additional.map(\.personID)
        )
    }

    private var selectablePersons: [Person] {
        persons.filter { !includedPersonIDs.contains($0.id) }
    }

    private var actionIsInFlight: Bool {
        isMutating || app.isReviewBusy(meetingID)
    }

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let currentReloadTask = reloadTask
        let isLoadingPersons = personLoadCoordinator.isLoading(
            for: currentReloadTask
        )
        let presentedError = errorMessage ?? personLoadError
        NavigationStack {
            List {
                Section {
                    Text(
                        "Speakers come from confirmed speaker assignments. Additional participants do not create or change voice profiles."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if let presentedError {
                    Section {
                        Label(presentedError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Steno.Colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("participant-editor-error")
                    }
                }

                if isLoadingPersons {
                    Section {
                        HStack(spacing: Steno.Space.s) {
                            ProgressView()
                            Text("Loading people…")
                        }
                        .foregroundStyle(.secondary)
                    }
                } else if meeting == nil {
                    Section {
                        Text("The current meeting could not be loaded.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    speakerSection
                    additionalSection
                    knownPeopleSection
                    if meeting?.isDemo == true {
                        demoPersonCreationSection
                    } else {
                        createPersonSection
                    }
                }
            }
            .navigationTitle("Edit Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(actionIsInFlight)
                        .accessibilityIdentifier("participant-editor-done")
                }
            }
        }
        .interactiveDismissDisabled(actionIsInFlight)
        .task(id: currentReloadTask) {
            await loadCurrentState(expectedTask: currentReloadTask)
        }
    }

    private var speakerSection: some View {
        Section("Speakers") {
            if sections.speakers.isEmpty {
                Text("No confirmed speakers.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sections.speakers) { participant in
                    participantLabel(participant, systemImage: "waveform")
                        .accessibilityIdentifier(
                            "participant-editor-speaker-\(participant.personID)"
                        )
                }
            }
        }
    }

    private var additionalSection: some View {
        Section("Additional") {
            if sections.additional.isEmpty {
                Text("No additional participants.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sections.additional) { participant in
                    HStack(spacing: Steno.Space.s) {
                        participantLabel(participant, systemImage: "person")
                        Spacer()
                        if participant.canRemove {
                            Button(role: .destructive) {
                                remove(participant.personID)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                                    .frame(minHeight: 44)
                            }
                            .disabled(actionIsInFlight)
                            .accessibilityLabel(
                                "Remove \(accessibleName(for: participant))"
                            )
                            .accessibilityIdentifier(
                                "participant-remove-\(participant.personID)"
                            )
                        }
                    }
                }
            }
        }
    }

    private var knownPeopleSection: some View {
        Section("Add known person") {
            if selectablePersons.isEmpty {
                Text("Everyone in the people library is already included.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectablePersons) { person in
                    Button {
                        addKnownPerson(person.id)
                    } label: {
                        HStack(spacing: Steno.Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName)
                                if let detail = disambiguation(for: person) {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(actionIsInFlight)
                    .accessibilityIdentifier("participant-add-\(person.id)")
                }
            }
        }
    }

    private var createPersonSection: some View {
        Section("Create and add") {
            TextField("Name", text: $newName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($newNameIsFocused)
                .disabled(actionIsInFlight)
                .onSubmit(createAndAddPerson)
                .accessibilityIdentifier("participant-new-name")
            Button {
                createAndAddPerson()
            } label: {
                Label("Create and Add", systemImage: "person.badge.plus")
                    .frame(minHeight: 44)
            }
            .disabled(trimmedNewName.isEmpty || actionIsInFlight)
            .accessibilityIdentifier("participant-create")
        }
    }

    private var demoPersonCreationSection: some View {
        Section("Create and add") {
            Text(
                "Demo meetings can add people already in your library, but cannot create a new person."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func participantLabel(
        _ participant: MeetingParticipantRow,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(participant.name, systemImage: systemImage)
            if let person = persons.first(where: { $0.id == participant.personID }),
               let detail = disambiguation(for: person) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibleName(
        for participant: MeetingParticipantRow
    ) -> String {
        guard let person = persons.first(where: { $0.id == participant.personID }),
              let detail = disambiguation(for: person)
        else { return participant.name }
        return "\(participant.name), \(detail)"
    }

    /// A publication change can originate in another iPad window without a
    /// review-generation change. Reload both halves against the exact meeting
    /// and publication ID so the sheet never combines a newer meeting with an
    /// older local person list.
    private func loadCurrentState(
        expectedTask: MeetingParticipantEditorReloadTask
    ) async {
        let task: MeetingParticipantEditorReloadTask
        if expectedTask.publicationIdentity != nil {
            task = expectedTask
        } else {
            guard await app.loadMeetingReviewPublication(
                for: meetingID
            ) != nil,
                  !Task.isCancelled,
                  reloadTask.publicationIdentity != nil
            else { return }
            task = reloadTask
        }
        guard !Task.isCancelled,
              reloadTask == task
        else { return }
        await reloadPersons(for: task)
    }

    private func reloadPersons(
        for task: MeetingParticipantEditorReloadTask
    ) async {
        let request = personLoadCoordinator.begin(task)
        do {
            let loadedPersons = try await app.allPersons()
            guard !Task.isCancelled else {
                personLoadCoordinator.cancel(request)
                return
            }
            guard personLoadCoordinator.accept(
                request,
                currentTask: reloadTask
            )
            else { return }
            persons = loadedPersons
            personLoadError = nil
        } catch {
            guard !Task.isCancelled else {
                personLoadCoordinator.cancel(request)
                return
            }
            let message = String(localized: "People could not be loaded: \(error.localizedDescription)")
            if personLoadCoordinator.fail(
                request,
                currentTask: reloadTask,
                message: message
            ) {
                personLoadError = message
            }
        }
    }

    private func addKnownPerson(_ personID: PersonID) {
        guard !actionIsInFlight else { return }
        isMutating = true
        errorMessage = nil
        Task { @MainActor in
            let result = await app.addAdditionalParticipantResult(
                personID,
                name: nil,
                meetingID: meetingID
            )
            let mutationError = result.error
            if reloadTask.publicationIdentity != nil {
                await reloadPersons(for: reloadTask)
            }
            errorMessage = mutationError?.localizedDescription
            isMutating = false
        }
    }

    private func createAndAddPerson() {
        let name = trimmedNewName
        guard !name.isEmpty, !actionIsInFlight else { return }
        isMutating = true
        errorMessage = nil
        newNameIsFocused = false
        Task { @MainActor in
            let result = await app.addAdditionalParticipantResult(
                nil,
                name: name,
                meetingID: meetingID
            )
            let mutationError = result.error
            if reloadTask.publicationIdentity != nil {
                await reloadPersons(for: reloadTask)
            }
            if result.succeeded {
                newName = ""
            }
            errorMessage = mutationError?.localizedDescription
            isMutating = false
        }
    }

    private func remove(_ personID: PersonID) {
        guard !actionIsInFlight else { return }
        isMutating = true
        errorMessage = nil
        Task { @MainActor in
            let result = await app.removeAdditionalParticipantResult(
                personID,
                meetingID: meetingID
            )
            let mutationError = result.error
            if reloadTask.publicationIdentity != nil {
                await reloadPersons(for: reloadTask)
            }
            errorMessage = mutationError?.localizedDescription
            isMutating = false
        }
    }

    /// Contact data is local-only disambiguation. Equal names always receive
    /// a unique ID suffix as well because their contact data may also match.
    private func disambiguation(for person: Person) -> String? {
        let equalNames = persons.filter {
            $0.displayName.localizedCaseInsensitiveCompare(person.displayName)
                == .orderedSame
        }
        var details = [person.organization, person.email].compactMap { $0 }
        if equalNames.count > 1 {
            details.append(
                "Person ID \(uniqueIDSuffix(for: person, among: equalNames))"
            )
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    /// UUIDv7 prefixes mostly encode time, so use the shortest suffix of at
    /// least eight characters that is actually unique in this name group.
    private func uniqueIDSuffix(
        for person: Person,
        among candidates: [Person]
    ) -> Substring {
        let description = person.id.description
        for length in 8...description.count {
            let suffix = description.suffix(length)
            let isUnique = candidates.allSatisfy { candidate in
                candidate.id == person.id
                    || !candidate.id.description.hasSuffix(suffix)
            }
            if isUnique { return suffix }
        }
        return description[...]
    }
}
