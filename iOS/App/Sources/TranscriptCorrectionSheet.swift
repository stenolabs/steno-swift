import StenoDomain
import SwiftUI

struct TranscriptCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let target: TranscriptCorrectionTarget
    let availability: TranscriptCorrectionAvailability
    let save: @MainActor (
        TranscriptCorrectionTarget,
        String
    ) async -> TranscriptCorrectionSaveResult
    let didSave: @MainActor (TranscriptRevision) -> Void
    let didEncounterConflict: @MainActor (TranscriptRevision?) async -> Void

    @State private var state: TranscriptCorrectionSheetState
    @FocusState private var editorIsFocused: Bool

    init(
        target: TranscriptCorrectionTarget,
        availability: TranscriptCorrectionAvailability,
        save: @escaping @MainActor (
            TranscriptCorrectionTarget,
            String
        ) async -> TranscriptCorrectionSaveResult,
        didSave: @escaping @MainActor (TranscriptRevision) -> Void,
        didEncounterConflict: @escaping @MainActor (
            TranscriptRevision?
        ) async -> Void
    ) {
        self.target = target
        self.availability = availability
        self.save = save
        self.didSave = didSave
        self.didEncounterConflict = didEncounterConflict
        _state = State(initialValue: TranscriptCorrectionSheetState(target: target))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Steno.Space.m) {
                    TextEditor(text: $state.draft)
                        .font(Steno.readingBody)
                        .frame(minHeight: 180)
                        .padding(Steno.Space.xs)
                        .background(.background.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.tertiary)
                        }
                        .focused($editorIsFocused)
                        .disabled(state.isSaving)
                        .accessibilityIdentifier("transcript-correction-editor")

                    Text(TranscriptCorrectionCopy.revisionNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let reason = availability.blockReason {
                        Label {
                            Text(reason.message)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }

                    if let error = state.error {
                        Label {
                            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                                Text(error.title)
                                    .font(.headline)
                                Text(error.message)
                                    .font(.callout)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding()
            }
            .navigationTitle(Text(TranscriptCorrectionCopy.sheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TranscriptCorrectionCopy.cancelTitle) {
                        dismiss()
                    }
                    .disabled(state.isSaving)
                    .accessibilityIdentifier("transcript-correction-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(TranscriptCorrectionCopy.saveTitle) {
                        submit()
                    }
                    .disabled(!state.canSave || !availability.isAvailable)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityIdentifier("transcript-correction-save")
                }
            }
        }
        // A swipe must not discard a conflict draft. The explicit Cancel
        // button is the one deliberate non-save exit from this editor.
        .interactiveDismissDisabled()
        .onAppear { editorIsFocused = true }
    }

    private func submit() {
        guard availability.isAvailable else { return }
        var startingState = state
        guard startingState.beginSave() else { return }
        state = startingState

        Task { @MainActor in
            let result = await save(target, state.draft)
            var finishedState = state
            let effect = finishedState.receive(result)
            state = finishedState

            switch effect {
            case .stayOpen:
                break
            case .reloadAfterConflict(let currentRevision):
                await didEncounterConflict(currentRevision)
            case .saved(let updatedVisibleRevision):
                didSave(updatedVisibleRevision)
                dismiss()
            }
        }
    }
}
