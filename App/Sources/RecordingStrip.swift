import SwiftUI

/// Der schmale Streifen, der waehrend einer Aufnahme immer oben steht -
/// unabhaengig davon, welches Meeting gerade geoeffnet ist.
///
/// Er ist die Gegenleistung dafuer, dass die Aufnahme die App nicht mehr
/// sperrt: wer waehrend eines Gespraechs etwas nachschlaegt, muss trotzdem
/// jederzeit sehen, dass aufgenommen wird, worin aufgenommen wird und wie
/// lange schon - und mit einem Klick zurueckfinden.
struct RecordingStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Steno.Space.m) {
            HStack(spacing: Steno.Space.s) {
                Circle()
                    .fill(Steno.Colors.recording)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                if let start = model.recordingStartedAt {
                    Text(start, style: .timer)
                        .font(.callout.monospacedDigit())
                        .accessibilityLabel("Recording time")
                }
            }

            if isElsewhere {
                // Nur wenn man woanders steht. Im Aufnahme-Meeting selbst waere
                // ein Knopf, der zum aktuellen Ort fuehrt, blosses Rauschen.
                Button {
                    model.selectedMeetingID = model.recordingMeetingID
                } label: {
                    Label(recordingTitle, systemImage: "record.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .help("Back to the recording")
            } else {
                Text(recordingTitle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            LevelMeter(label: "Microphone", level: model.levels[.microphone])
            LevelMeter(label: "System", level: model.levels[.system])

            Button("Stop") {
                Task { await model.stopRecording() }
            }
            .controlSize(.small)
            .help("Stop recording (Cmd-.)")
        }
        .padding(.horizontal, Steno.Space.m)
        .padding(.vertical, Steno.Space.s)
        .background(.background.secondary)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var isElsewhere: Bool {
        model.selectedMeetingID != model.recordingMeetingID
    }

    private var recordingTitle: String {
        model.meetings.first { $0.id == model.recordingMeetingID }?.title
            ?? "Recording"
    }
}
