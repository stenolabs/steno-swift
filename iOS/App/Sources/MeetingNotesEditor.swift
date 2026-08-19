import StenoDomain
import StenoLibrary
import SwiftUI

/// Thin iOS surface for the shared notes editing and persistence session.
struct MeetingNotesEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let meetingID: MeetingID
    let meetingTitle: String

    @State private var session: MeetingNotesEditingSession?
    @State private var didLoad = false
    @State private var isClosing = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    editor(session)
                } else if didLoad {
                    ContentUnavailableView(
                        "Notes unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The library is not open.")
                    )
                } else {
                    ProgressView("Opening notes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        close()
                    }
                    .disabled(session == nil || isClosing)
                }
            }
        }
        .task(id: meetingID) {
            session = await app.notesSession(for: meetingID)
            didLoad = true
            editorFocused = session != nil
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            flush()
        }
        .onDisappear {
            flush()
        }
        .interactiveDismissDisabled(session?.isSaving == true || isClosing)
    }

    private func editor(_ session: MeetingNotesEditingSession) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Text(meetingTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            TextEditor(text: textBinding)
                .font(Steno.readingBody)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(Steno.Space.s)
                .background(
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: Steno.cardRadius)
                )
                .overlay(alignment: .topLeading) {
                    if session.text.isEmpty {
                        Text("Names, decisions, follow-ups, and context for later.")
                            .font(Steno.readingBody)
                            .foregroundStyle(.tertiary)
                            .padding(Steno.Space.m)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Meeting notes")

            saveStatus(session)
        }
        .padding()
    }

    @ViewBuilder
    private func saveStatus(_ session: MeetingNotesEditingSession) -> some View {
        if let error = session.errorMessage {
            Label(
                "Notes could not be saved: \(error)",
                systemImage: "exclamationmark.triangle"
            )
                .font(.caption)
                .foregroundStyle(.red)
        } else if session.isSaving {
            HStack(spacing: Steno.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving notes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Saved on this device", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { session?.text ?? "" },
            set: { session?.update($0) }
        )
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        let currentSession = session
        Task {
            await currentSession?.flush()
            if currentSession?.errorMessage == nil {
                dismiss()
            } else {
                isClosing = false
            }
        }
    }

    private func flush() {
        let currentSession = session
        Task { await currentSession?.flush() }
    }
}
