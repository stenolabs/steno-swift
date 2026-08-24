import SwiftUI

/// The narrow bar that sits above everything while a recording runs.
///
/// It is the price of letting a recording continue while the user goes
/// somewhere else in the app. Whoever looks something up mid-conversation must
/// still see at a glance that recording is happening, how long it has been
/// going, and that the microphone is alive - and get back with one tap.
///
/// Follows `steno-macos/App/Sources/RecordingStrip.swift`, with two changes
/// forced by the platform: the level is one meter because iOS captures one
/// track, and the tap target is a full-height button instead of a link.
struct RecordingStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Called when the user wants to get back to the recording screen.
    let returnToRecording: () -> Void

    var body: some View {
        let axis = IOSAdaptiveStackAxis.axis(for: dynamicTypeSize)
        Group {
            if axis == .horizontal {
                horizontalContents
            } else {
                verticalContents
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var horizontalContents: some View {
        HStack(spacing: 12) {
            recordingStatus
            Spacer(minLength: 8)
            actions(axis: .horizontal)
        }
    }

    private var verticalContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingStatus
            actions(axis: .vertical)
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            Text(durationText(app.recording.elapsed))
                .font(.callout.monospacedDigit())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(RecordingAccessibilityPresentation.durationLabel))
                .accessibilityValue(
                    RecordingAccessibilityPresentation.durationValue(for: app.recording.elapsed)
                )

            // A silent microphone outranks everything else this bar could say,
            // and it is the whole reason the bar shows a level at all.
            if app.recording.isSilenceAlarming {
                Label("no sound", systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                LevelMeter(
                    level: app.recording.level,
                    isActive: true,
                    showsCaption: false
                )
                .frame(maxWidth: 120)
            }
        }
    }

    private func actions(axis: Axis) -> some View {
        IOSAdaptiveStack(
            axis: axis,
            spacing: 12,
            verticalAlignment: .leading
        ) {
            backButton
            stopButton
        }
    }

    private var backButton: some View {
        Button("Back", action: returnToRecording)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text(RecordingAccessibilityPresentation.backLabel))
            .accessibilityHint(Text(RecordingAccessibilityPresentation.backHint))
            .accessibilityIdentifier("recording-back")
    }

    private var stopButton: some View {
        Button("Stop") {
            Task { await app.recording.stop() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.red)
        .accessibilityLabel(Text(RecordingAccessibilityPresentation.stopLabel))
        .accessibilityHint(Text(RecordingAccessibilityPresentation.stopHint))
        .accessibilityIdentifier("recording-stop")
    }

    private var dotColor: Color {
        app.recording.isSilenceAlarming ? .red : .red.opacity(0.85)
    }
}
