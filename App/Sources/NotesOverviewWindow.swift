import AppKit
import StenoDomain
import StenoLibrary
import SwiftUI

/// Read-only overview of every meeting's user note, newest meeting first.
///
/// Notes stay editable exclusively in the meeting detail view; this window is
/// a scanning surface. It never renders transcript content and never logs
/// anything - note bodies live only in this view.
struct NotesOverviewWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// One entry per meeting that actually carries a non-empty note.
    @State private var entries: [NoteOverviewEntry] = []
    @State private var expandedEntryIDs: Set<MeetingID> = []

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Notes Yet"),
                    systemImage: "note.text",
                    description: Text("Notes you write about a meeting appear here, newest first.")
                )
            } else {
                List(entries) { entry in
                    NoteOverviewRow(
                        entry: entry,
                        isExpanded: expandedEntryIDs.contains(entry.meetingID),
                        toggleExpanded: { toggleExpanded(entry.meetingID) },
                        openMeeting: { openMeeting(entry.meetingID) }
                    )
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(String(localized: "My Notes"))
        .frame(minWidth: 380, minHeight: 300)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func toggleExpanded(_ meetingID: MeetingID) {
        if expandedEntryIDs.contains(meetingID) {
            expandedEntryIDs.remove(meetingID)
        } else {
            expandedEntryIDs.insert(meetingID)
        }
    }

    /// Click-through into the main window with exactly that meeting selected.
    /// Reuses the persisted selection defaults key (`steno.selection.meeting`)
    /// through `AppModel.selectedMeetingIDs`, so a later launch restores it.
    private func openMeeting(_ meetingID: MeetingID) {
        guard model.meetings.contains(where: { $0.id == meetingID }) else { return }
        model.selectedMeetingIDs = [meetingID]
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func reload() async {
        guard let runtime = model.runtime else {
            entries = []
            return
        }
        let store = MeetingNotesStore(layout: runtime.library.layout)
        // `model.meetings` is already sorted reverse-chronologically by
        // createdAt; keep that order for meetings that carry a note.
        var loaded: [NoteOverviewEntry] = []
        for meeting in model.meetings {
            guard let note = try? await store.notes(meeting.id), !note.isEmpty else {
                continue
            }
            loaded.append(NoteOverviewEntry(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                meetingCreatedAt: meeting.createdAt,
                note: note
            ))
        }
        entries = loaded
    }
}

private struct NoteOverviewEntry: Identifiable {
    var id: MeetingID { meetingID }

    let meetingID: MeetingID
    let meetingTitle: String
    let meetingCreatedAt: Date
    let note: String

    /// Three-line preview: first lines of the note, whitespace-normalized.
    var preview: String {
        note.split(whereSeparator: \.isNewline)
            .prefix(3)
            .joined(separator: " ")
    }
}

private struct NoteOverviewRow: View {
    let entry: NoteOverviewEntry
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let openMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: toggleExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.meetingTitle)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        Text(entry.meetingCreatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isExpanded {
                // Full note, still read-only here.
                Text(entry.note)
                    .textSelection(.enabled)
                Button(String(localized: "Open Meeting"), action: openMeeting)
                    .controlSize(.small)
            } else {
                Button(action: openMeeting) {
                    Text(entry.preview)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open this meeting"))
            }
        }
        .padding(.vertical, 2)
    }
}
