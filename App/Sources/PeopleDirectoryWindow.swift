import AppKit
import StenoDomain
import StenoLibrary
import SwiftUI

/// "People Directory" window: every person appearing across the library,
/// aggregated from meeting participants by normalized name.
///
/// The index itself lives in `StenoDomain.PeopleDirectoryIndex`; this view
/// only resolves participant identifiers to display names and renders the
/// result. Meeting rows open in the main window via the persisted selection
/// key (`steno.selection.meeting`), exactly like the My Notes overview.
struct PeopleDirectoryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var people: [PersonDirectoryEntry] = []
    @State private var query = ""
    @State private var selectedPersonKey: String?

    private var filteredPeople: [PersonDirectoryEntry] {
        PeopleDirectoryIndex.search(people, query: query)
    }

    private var selectedPerson: PersonDirectoryEntry? {
        people.first { $0.id == selectedPersonKey }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPersonKey) {
                ForEach(filteredPeople) { person in
                    VStack(alignment: .leading, spacing: Steno.Space.xs) {
                        Text(person.displayName)
                        Text("\(person.noteCount) meetings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(person.id)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, prompt: "Search people")
            .navigationTitle("People Directory")
        } detail: {
            if let person = selectedPerson {
                personDetail(person)
            } else {
                ContentUnavailableView(
                    "People Directory",
                    systemImage: "person.2",
                    description: Text("Select a person to see their meetings.")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: Detail

    private func personDetail(_ person: PersonDirectoryEntry) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Steno.Space.s) {
                    Text(person.displayName)
                        .font(.title2.bold())
                    Text("\(person.noteCount) meetings")
                    if let lastDate = person.lastDate {
                        Text("Last met \(lastDate.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        askAbout(person)
                    } label: {
                        Label("Ask about \(person.displayName)", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            Section("Meetings") {
                ForEach(person.meetingIDs, id: \.rawValue) { meetingID in
                    if let meeting = model.meetings.first(where: { $0.id == meetingID }) {
                        Button {
                            openMeeting(meetingID)
                        } label: {
                            HStack {
                                Text(meeting.title)
                                Spacer()
                                Text(meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// Click-through into the main window with exactly that meeting selected.
    /// Reuses `AppModel.selectedMeetingIDs`, so a later launch restores it.
    private func openMeeting(_ meetingID: MeetingID) {
        guard model.meetings.contains(where: { $0.id == meetingID }) else { return }
        model.selectedMeetingIDs = [meetingID]
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    /// Opens Library Chat prefilled with an "Ask about <name>" draft and
    /// scoped to the person's meetings through the chat scoping seam; the
    /// window consumes and clears the pending intent on its next creation.
    private func askAbout(_ person: PersonDirectoryEntry) {
        LibraryChatModel.queueIntent(LibraryChatModel.Intent(
            presetDraft: "Ask about \(person.displayName)",
            meetingIDs: person.meetingIDs
        ))
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "library-chat")
    }

    // MARK: Data

    private func reload() async {
        guard let runtime = model.runtime else {
            people = []
            return
        }
        do {
            let store = try IdentityStore(layout: await runtime.library.layout)
            let persons = try await store.listPersons()
            let displayNames = Dictionary(
                uniqueKeysWithValues: persons.map { ($0.id, $0.displayName) }
            )
            // `model.meetings` is sorted newest first, which fixes both the
            // per-person meeting order and the deterministic tie-breaks.
            people = PeopleDirectoryIndex.build(
                meetings: model.meetings,
                displayNames: displayNames
            )
        } catch {
            people = []
        }
    }
}
