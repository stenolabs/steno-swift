import StenoDomain
import StenoIdentity
import StenoPipeline
import SwiftUI

/// Teilnehmer als Chips: Wer nachweislich gesprochen hat, steht fest;
/// stille Anwesende ergänzt der Benutzer selbst und kann sie wieder
/// entfernen. Die Liste wandert so auch ins Protokoll.
struct ParticipantsSection: View {
    @Environment(AppModel.self) private var model
    let meetingID: MeetingID
    let review: MeetingReviewData?

    @State private var speaking: [Person] = []
    @State private var silent: [Person] = []
    @State private var knownPersons: [Person] = []
    @State private var showAdd = false
    @State private var newName = ""
    /// Person, deren Kontaktdaten gerade offen sind.
    @State private var contactPerson: Person?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Participants")
                    .font(.headline)
                Spacer()
                Button {
                    newName = ""
                    showAdd = true
                } label: {
                    Label("Add", systemImage: "person.badge.plus")
                }
                .controlSize(.small)
            }
            if speaking.isEmpty, silent.isEmpty {
                Text("No participants yet. Confirmed speakers appear automatically; add anyone who attended without speaking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(speaking, id: \.id) { person in
                        chip(person, systemImage: "waveform", removable: false)
                    }
                    ForEach(silent, id: \.id) { person in
                        chip(person, systemImage: "person", removable: true) {
                            Task {
                                await model.removeAdditionalParticipant(
                                    person.id,
                                    meetingID: meetingID
                                )
                                await reload()
                            }
                        }
                    }
                }
            }
        }
        .task(id: reloadKey) { await reload() }
        .popover(isPresented: $showAdd, arrowEdge: .bottom) { addPopover }
        .popover(item: $contactPerson, arrowEdge: .bottom) { person in
            contactPopover(person)
        }
    }

    /// Lädt neu, sobald sich eine Zuordnung ändert. Reine Anzahlen genügen
    /// nicht: Einen Sprecher zu bestätigen ändert weder die Cluster- noch
    /// die Personenzahl, macht die Person aber zur Teilnehmerin.
    private var reloadKey: String {
        let assignments = (review?.clusters ?? [])
            .compactMap { cluster -> String? in
                guard case .confirmed(let personID) = cluster.reviewState else {
                    return nil
                }
                return "\(cluster.channel)/\(cluster.clusterID):\(personID.rawValue)"
            }
            .sorted()
            .joined(separator: ",")
        return "\(meetingID.rawValue)|\(review?.persons.count ?? 0)|\(assignments)"
    }

    @ViewBuilder
    private func chip(
        _ person: Person,
        systemImage: String,
        removable: Bool,
        remove: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(person.displayName) { contactPerson = person }
                .buttonStyle(.plain)
                .font(.callout)
            // Ein stiller Hinweis, dass eine Adresse hinterlegt ist - ohne
            // sie anzuzeigen, denn die Chipleiste ist kein Adressbuch.
            if person.email != nil {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has an e-mail address")
            }
            if removable {
                Button {
                    remove?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove participant")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            removable ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint.opacity(0.18)),
            in: Capsule()
        )
        .help(removable
            ? "Added manually: no detected speech - click the name for contact details"
            : "Verifiably spoke in this meeting - click the name for contact details")
    }

    /// Kontaktdaten einer Person. Bewusst schlicht: Die Adresse dient dem
    /// spaeteren Protokollversand und geht nie in einen Prompt oder in die
    /// Teilnehmerliste, die ein Modell zu sehen bekommt.
    private func contactPopover(_ person: Person) -> some View {
        ContactEditor(person: person) { email, organization in
            // Firma zuerst: Sie kann nicht abgelehnt werden, die Adresse
            // schon - so geht bei einer Fehleingabe nichts verloren.
            await model.setPersonOrganization(person.id, to: organization)
            let saved = await model.setPersonEmail(person.id, to: email)
            if saved {
                contactPerson = nil
                await reload()
            }
            return saved
        }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add participant")
                .font(.headline)
            Text("For attendees without detected speech.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let selectable = knownPersons.filter { person in
                !speaking.contains { $0.id == person.id }
                    && !silent.contains { $0.id == person.id }
            }
            if !selectable.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(selectable, id: \.id) { person in
                            Button(entry(person)) {
                                Task {
                                    await model.addAdditionalParticipant(
                                        person.id,
                                        name: nil,
                                        meetingID: meetingID
                                    )
                                    showAdd = false
                                    await reload()
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 160)
                Divider()
            }
            HStack {
                TextField("New person", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNewPerson() }
                Button("Create") { addNewPerson() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    /// Name plus Adresse, damit zwei gleichnamige Personen unterscheidbar sind.
    private func entry(_ person: Person) -> String {
        let marks = [person.organization, person.email].compactMap { $0 }
        guard !marks.isEmpty else { return person.displayName }
        return "\(person.displayName)  ·  \(marks.joined(separator: "  ·  "))"
    }

    private func addNewPerson() {
        let name = newName
        Task {
            await model.addAdditionalParticipant(nil, name: name, meetingID: meetingID)
            newName = ""
            showAdd = false
            await reload()
        }
    }

    private func reload() async {
        knownPersons = await model.allPersons()
        guard let meeting = await model.meeting(meetingID) else { return }
        let byID = Dictionary(uniqueKeysWithValues: knownPersons.map { ($0.id, $0) })
        speaking = meeting.participantIDs.compactMap { byID[$0] }
        // Wer als still ergaenzt und spaeter als Sprecherin bestaetigt wird,
        // steht in beiden Listen: die Bibliothek filtert nur beim Schreiben
        // der stillen Liste, und diese Bestaetigung kommt danach. Ohne den
        // Filter stuende der Name zweimal in der Chipleiste.
        let speakingIDs = Set(meeting.participantIDs)
        silent = meeting.additionalParticipantIDs
            .filter { !speakingIDs.contains($0) }
            .compactMap { byID[$0] }
    }
}

/// Einfaches Umbruch-Layout für die Chips; SwiftUI bringt für macOS
/// nichts Passendes mit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Kontaktdaten einer Person. Die Adresse ist Bibliotheksdatei fuer den
/// spaeteren Protokollversand; sie verlaesst die Bibliothek nie Richtung
/// Modell.
private struct ContactEditor: View {
    let person: Person
    /// Gibt zurueck, ob gespeichert wurde - bei einer abgelehnten Adresse
    /// bleibt das Popover offen, damit die Eingabe nicht verloren geht.
    let save: (String?, String?) async -> Bool

    @State private var email = ""
    @State private var organization = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Text(person.displayName)
                .font(.headline)
            Text("Used to tell people apart as the voice database grows - two people with the same name are normal there. Both stay in your library and never reach a language model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Organization", text: $organization, prompt: Text("Example GmbH"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            TextField("E-mail", text: $email, prompt: Text("name@example.org"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (email == (person.email ?? "")
                        && organization == (person.organization ?? "")))
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 300)
        .task {
            email = person.email ?? ""
            organization = person.organization ?? ""
        }
    }

    private func commit() {
        guard !saving else { return }
        saving = true
        Task {
            _ = await save(email, organization)
            saving = false
        }
    }
}
