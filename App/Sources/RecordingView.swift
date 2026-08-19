import StenoAudioCore
import StenoDomain
import StenoMacAudio
import SwiftUI

struct RecordingTrackPresentation: Equatable {
    let actionTitle: String?
    let actionIcon: String?
    let warning: String?
    let isPaused: Bool

    init(status: RecordingTrackStatus?) {
        let status = status ?? RecordingTrackStatus()
        let name = status.deviceName ?? "Microphone"
        if !status.deviceAvailable {
            actionTitle = nil
            actionIcon = nil
            warning = "\(name) disconnected. The microphone track is paused; system audio continues."
            isPaused = true
        } else if status.sourceStalled {
            actionTitle = nil
            actionIcon = nil
            warning = "\(name) is not responding. The microphone track is paused; system audio continues."
            isPaused = true
        } else if status.userPaused {
            actionTitle = "Resume microphone"
            actionIcon = "play.circle"
            warning = "Microphone paused. System audio continues."
            isPaused = true
        } else {
            actionTitle = "Pause microphone"
            actionIcon = "pause.circle"
            warning = nil
            isPaused = false
        }
    }
}

struct RecordingView: View {
    @Environment(AppModel.self) private var model
    /// Mitschreiben ist der Hauptfall, also steht das Feld von selbst offen.
    /// Die Entscheidung des Benutzers ueberlebt aber den Neustart: Wer es
    /// zuklappt, schreibt nicht mit und soll nicht jedesmal neu zuklappen.
    @AppStorage("steno.recording.notesOpen") private var showNotes = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        // Mitschreiben waehrend der Aufnahme ist der Hauptfall fuer Notizen,
        // nicht die Ausnahme.
        .inspector(isPresented: $showNotes) {
            Group {
                if let meetingID = model.recordingMeetingID {
                    ScrollView {
                        NotesSection(meetingID: meetingID)
                            .padding(Steno.Space.l)
                    }
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showNotes) {
                    Label("Notes", systemImage: "square.and.pencil")
                }
                .help("Take notes while recording")
            }
        }
    }

    private var header: some View {
        let microphone = RecordingTrackPresentation(
            status: model.microphoneStatus
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Steno.Colors.recording)
                        .frame(width: 10, height: 10)
                    if let start = model.recordingStartedAt {
                        Text(start, style: .timer)
                            .font(.title3.monospacedDigit())
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    LevelMeter(
                        label: "Microphone",
                        level: microphone.isPaused ? .silence : model.levels[.microphone]
                    )
                    if let title = microphone.actionTitle,
                       let icon = microphone.actionIcon {
                        Button {
                            Task {
                                await model.setMicrophonePaused(!microphone.isPaused)
                            }
                        } label: {
                            Label(title, systemImage: icon)
                        }
                        .buttonStyle(.borderless)
                        .help(title)
                    }
                }
                LevelMeter(label: "System", level: model.levels[.system])
                Spacer()
            }
            if let warning = microphone.warning {
                Label(warning, systemImage: "mic.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background.secondary)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.liveFinalLines) { line in
                        TranscriptLineView(
                            speaker: line.speaker,
                            text: line.text,
                            isVolatile: false
                        )
                        .id(line.id)
                    }
                    ForEach(
                        AudioTrack.allCases.filter {
                            !(model.liveVolatileText[$0] ?? "").isEmpty
                        },
                        id: \.self
                    ) { track in
                        TranscriptLineView(
                            speaker: ChannelLabel.speakerLabel(track == .microphone ? "Ich" : "Andere"),
                            text: model.liveVolatileText[track] ?? "",
                            isVolatile: true
                        )
                        .id("volatile-\(track.rawValue)")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.liveFinalLines.count) {
                if let last = model.liveFinalLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .overlay {
            if model.liveFinalLines.isEmpty
                && model.liveVolatileText.values.allSatisfy(\.isEmpty) {
                ContentUnavailableView(
                    "Waiting for speech",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("The live transcript appears here as soon as someone speaks.")
                )
            }
        }
        // Aufnahmefehler laufen in die zentrale Meldungsleiste am Fenster.
        // Hier zu melden half nur, solange eine Aufnahme lief - also gerade
        // nicht in den Faellen, die zaehlen (Start scheitert, Mikro
        // verweigert, Aufnahme beendet).
    }
}

struct TranscriptLineView: View {
    let speaker: String
    let text: String
    let isVolatile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(isVolatile ? .secondary : .primary)
                .italic(isVolatile)
                .textSelection(.enabled)
        }
    }
}

struct LevelMeter: View {
    let label: String
    let level: AudioLevels?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(Steno.Colors.brand)
                        .frame(width: geometry.size.width * CGFloat(normalized))
                }
            }
            .frame(width: 120, height: 6)
        }
        // "Kommt ueberhaupt Signal an" ist die kritischste Information zu
        // Aufnahmebeginn und war fuer VoiceOver bisher unsichtbar.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue("\(Int(normalized * 100)) percent")
    }

    /// RMS grob auf 0...1 abgebildet; -50 dB gilt als Stille.
    private var normalized: Float {
        guard let level, level.rms > 0 else { return 0 }
        let db = 20 * log10(level.rms)
        return max(0, min(1, (db + 50) / 50))
    }
}
