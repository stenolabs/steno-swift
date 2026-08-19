import StenoDomain
import StenoLibrary
import SwiftUI

/// Notizen zum Meeting: Kontext vor dem Termin, Mitschrieb waehrend der
/// Aufnahme, Nachtraege danach.
///
/// Editor und Zeitmarken verwenden dieselbe Bearbeitungssitzung. Dadurch kann
/// ein verzoegerter Autosave keinen gerade gesetzten Marker ueberschreiben.
struct NotesSection: View {
    @Environment(AppModel.self) private var model
    let meetingID: MeetingID

    @State private var session: MeetingNotesEditingSession?

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                if session?.isSaving == true {
                    Text("Saving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = session?.errorMessage {
                Text("Notes could not be saved: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            TextEditor(text: textBinding)
                .font(Steno.readingBody)
                .scrollContentBackground(.hidden)
                // macOS zeigt am TextEditor sonst dauerhaft einen Scroller,
                // auch im leeren Feld.
                .scrollIndicators(.never)
                .padding(Steno.Space.s)
                .frame(minHeight: 120)
                .background(
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: Steno.cardRadius)
                )
                .overlay(alignment: .topLeading) {
                    if session?.text.isEmpty != false {
                        Text("Names, companies, agenda - anything that helps you later.")
                            .font(Steno.readingBody)
                            .foregroundStyle(.tertiary)
                            .padding(Steno.Space.m)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Meeting notes")
                .disabled(session == nil)
        }
        .task(id: meetingID) {
            await session?.flush()
            session = await model.notesSession(for: meetingID)
        }
        .onDisappear {
            let currentSession = session
            Task { await currentSession?.flush() }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { session?.text ?? "" },
            set: { session?.update($0) }
        )
    }
}
