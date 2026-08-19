import StenoAudioCore
import StenoTranscription
import StenoiOSAudio
import SwiftUI

/// The recording screen, for phone and tablet.
///
/// Built to be consulted, not watched: during a meeting the device lies on the
/// table and gets glances of one to three seconds, one-handed. The rules come
/// from `steno-macos/docs/UX-REVIEW.md`, addendum "Was waehrend einer laufenden
/// Aufnahme zaehlt", and they include what is deliberately absent:
///
/// - No pause button. Forgetting to resume destroys the recording, and a
///   control whose omission is that costly does not belong here.
/// - No speaker names while recording. There is only one channel; a guessed
///   name would create exactly the false certainty the final run corrects.
/// - No live summary, no waveform, no animation beyond the level. Movement
///   draws the eye and says nothing the level does not.
/// - No sounds and no notifications. A banner over a shared screen would be
///   worse than any problem it reports.
///
/// Width changes the arrangement, never the content. On a wide screen the
/// controls stop being stretched across an arm's length of glass and the text
/// keeps a readable measure; nothing appears that a phone does not get.
struct RecordingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var notesFocused: Bool
    let showReadiness: () -> Void

    /// The longest line of text still comfortable to read, and the width the
    /// controls stop growing at. Beyond this a wider window only adds margin.
    private static let readableWidth: CGFloat = 720

    private var model: RecordingModel { app.recording }
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            footer
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header: state, duration, level

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isWide {
                // Side by side: a level meter drawn across a full iPad column
                // is a line, not a meter - the shape of the movement is the
                // whole information, and stretching it flattens it away.
                HStack(alignment: .center, spacing: 24) {
                    timer
                    LevelMeter(level: model.level, isActive: isRecording)
                        .frame(maxWidth: 320)
                }
            } else {
                timer
                LevelMeter(level: model.level, isActive: isRecording)
            }

            if let message = statusMessage {
                Label(message.text, systemImage: message.symbol)
                    .font(.subheadline)
                    .foregroundStyle(message.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if app.models.isReady(for: app.language.locale) == false {
                Button("Open audio readiness", action: showReadiness)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: Self.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.bar)
    }

    private var timer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isRecording ? .red : .secondary)
                .frame(width: 12, height: 12)
            Text(durationText(model.elapsed))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var isRecording: Bool {
        if case .recording = model.state { return true }
        return false
    }

    private struct StatusMessage {
        let text: String
        let symbol: String
        let tint: Color
    }

    private var statusMessage: StatusMessage? {
        // The dead microphone is the worst outcome, so it outranks everything
        // else that could be shown here.
        if model.isSilenceAlarming, isRecording {
            return StatusMessage(
                text: "Nothing heard for \(Int(model.silentSeconds)) seconds. "
                    + "Check the microphone.",
                symbol: "mic.slash",
                tint: .red
            )
        }
        switch model.state {
        case .interrupted(let reason, let at):
            return StatusMessage(
                text: "Interrupted because \(reason). "
                    + "Audio up to \(durationText(at)) is intact.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        case .failed(let message):
            return StatusMessage(
                text: message,
                symbol: "xmark.octagon.fill",
                tint: .red
            )
        case .preparing:
            return StatusMessage(
                text: "Preparing the recogniser…",
                symbol: "hourglass",
                tint: .secondary
            )
        case .idle, .recording:
            // Ranked below the states above but above the buffer counter: the
            // audio is fine, so this is a loss of comfort, not of the meeting.
            // Der beendete Lauf zuerst. Er schlaegt den fehlenden Live-Text,
            // weil "Recording. No live transcript" den Nutzer weiter in ein
            // Mikrofon sprechen liesse, das nichts mehr schreibt. Faellt
            // beides zusammen - erst ASR weg, dann Platte voll -, ist das
            // Ende die Nachricht.
            // The session ends itself before it would lose audio, so this is
            // never "some samples went missing" but always "the run is over".
            if let reason = model.involuntaryStop {
                return StatusMessage(
                    text: involuntaryStopText(reason),
                    symbol: "exclamationmark.triangle.fill",
                    tint: .red
                )
            }
            if let message = RecordingPresentation.modelMessage(
                isRecording: isRecording,
                transcriptionFailure: model.transcriptionFailure,
                modelReady: app.models.isReady(for: app.language.locale)
            ) {
                return StatusMessage(
                    text: message,
                    symbol: "text.badge.xmark",
                    tint: .orange
                )
            }
            // Zuletzt, weil es nichts verhindert - aber vor der ersten
            // Aufnahme, weil danach der Schaden schon da ist: eine falsch
            // erkannte Sprache liest sich plausibel und faellt oft erst
            // Tage spaeter auf.
            if !app.language.recordingSelection.effectiveLocaleWasChosenExplicitly,
               !app.language.available.isEmpty {
                return StatusMessage(
                    text: "Transcription language is guessed as "
                        + "\(app.language.selectedDisplayName). Confirm it under "
                        + "Audio readiness before you rely on a transcript.",
                    symbol: "questionmark.circle",
                    tint: .orange
                )
            }
            return nil
        }
    }

    private func involuntaryStopText(_ reason: RecordingStopReason) -> String {
        switch reason {
        case .requested:
            "Recording ended."
        case .lowDiskSpace:
            "Recording stopped: the device ran out of space. "
                + "Everything up to that point is saved."
        case .writerFailure:
            "Recording stopped: the audio file could not be written. "
                + "Everything up to that point is saved."
        case .ringBufferOverflow:
            "Recording stopped: audio arrived faster than it could be written. "
                + "Everything up to that point is saved."
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if model.finalText.isEmpty && model.volatileText.isEmpty {
            // Kept out of the scroll view: with a bottom anchor an empty state
            // would cling to the lower edge, which reads as a layout fault.
            VStack(spacing: 8) {
                Spacer()
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
                if model.transcriptionFailure != nil, isRecording {
                    Text("The audio is being captured either way.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            transcriptText
        }
    }

    private var emptyStateText: String {
        guard isRecording else { return "Not recording." }
        return model.transcriptionFailure == nil
            ? "Listening…"
            : "No live transcript on this device."
    }

    private var transcriptText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.finalText)
                // Volatile text is visibly lighter, and the caption below
                // never goes away: the live transcript is a catch-up aid, not
                // something to quote from.
                Text(model.volatileText)
                    .foregroundStyle(.secondary)
                if isRecording {
                    Text("Preliminary, corrected after the recording.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: Self.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .textSelection(.enabled)
        }
        // Keeps the newest line in view while the user is at the bottom, and
        // leaves them alone once they scroll up. To verify on device.
        .defaultScrollAnchor(.bottom)
    }

    // MARK: - Notes and controls

    private var footer: some View {
        VStack(spacing: 0) {
            notes
            controls
        }
        // Left-aligned like the header and the transcript. Centring just this
        // block made it look shifted against everything above it.
        .frame(maxWidth: Self.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Note")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Open, not behind a button: tapping a small field mid-conversation
            // is already too much motor work.
            TextField("Why this mattered", text: notesBinding, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .focused($notesFocused)
                .disabled(!model.canEditAnnotations)
            if let message = RecordingPresentation.annotationMessage(
                hasContent: !model.notes.isEmpty || !model.markers.isEmpty,
                isSaving: model.isSavingAnnotations,
                failure: model.annotationFailure
            ) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.annotationFailure == nil ? Color.secondary : Color.red)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var notesBinding: Binding<String> {
        Binding(get: { model.notes }, set: { model.updateNotes($0) })
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.mark() }
            } label: {
                Label(markerLabel, systemImage: "bookmark.fill")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(!isRecording)

            Button {
                Task {
                    if model.isActive {
                        await app.stopRecording()
                        // The finished meeting has to reach the sidebar, or it
                        // looks like the recording went nowhere.
                    } else {
                        _ = await app.startRecording()
                        await app.reloadMeetings()
                    }
                }
            } label: {
                Label(
                    model.isActive ? "Stop" : "Record",
                    systemImage: model.isActive ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isActive ? .red : .accentColor)
            // Nothing to record into until the library is open.
            .disabled(!app.canStartRecording)
        }
        .padding()
    }

    private var markerLabel: String {
        model.markers.isEmpty
            ? "Mark"
            : "Mark (\(model.markers.count))"
    }
}

enum RecordingPresentation {
    static func modelMessage(
        isRecording: Bool,
        transcriptionFailure: String?,
        modelReady: Bool?
    ) -> String? {
        if let transcriptionFailure {
            return "Recording. No live transcript: \(transcriptionFailure)"
        }
        guard modelReady == false else { return nil }
        return isRecording
            ? "Recording without transcription. The speech model is not installed."
            : "The speech model is not installed. Recording still works."
    }

    static func annotationMessage(
        hasContent: Bool,
        isSaving: Bool,
        failure: String?
    ) -> String? {
        if let failure {
            return "Notes could not be saved: \(failure)"
        }
        guard hasContent, isSaving else { return nil }
        return "Saving notes…"
    }
}
