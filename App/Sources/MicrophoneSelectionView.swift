import AppKit
import StenoMacAudio
import SwiftUI

struct MicrophoneSelectionButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(label, systemImage: "mic")
        }
        .help("Choose the microphone used for new recordings")
        .disabled(model.isRecording || model.isStartingRecording)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Microphone")
                    .font(.headline)
                MicrophoneSelectionControls()
            }
            .padding(16)
            .frame(width: 380)
        }
    }

    private var label: String {
        if let microphone = model.resolvedRecordingMicrophone {
            return microphone.name
        }
        return String(localized: "Choose microphone")
    }
}

struct MicrophoneSelectionControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Input", selection: selection) {
                Text("Automatic - browser or meeting app")
                    .tag(Self.automaticSelection)
                ForEach(model.microphoneDiscovery.availableDevices) { device in
                    Text(device.name)
                        .tag(Self.deviceSelection(device.uid))
                }
            }
            .disabled(model.isRecording || model.isStartingRecording)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Refresh") {
                    Task { await model.refreshMicrophoneDiscovery() }
                }
                .controlSize(.small)
                .disabled(model.isRecording || model.isStartingRecording)
            }
        }
        .task {
            await model.refreshMicrophoneDiscovery()
        }
    }

    private static let automaticSelection = "automatic"

    private static func deviceSelection(_ uid: String) -> String {
        "device:\(uid)"
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                switch model.recordingMicrophoneMode {
                case .automatic:
                    Self.automaticSelection
                case .manual(let device):
                    Self.deviceSelection(device.uid)
                }
            },
            set: { selection in
                if selection == Self.automaticSelection {
                    model.selectAutomaticMicrophone()
                    return
                }
                guard let device = model.microphoneDiscovery.availableDevices
                    .first(where: {
                        Self.deviceSelection($0.uid) == selection
                    }) else { return }
                model.selectMicrophone(device)
            }
        )
    }

    private var statusSymbol: String {
        model.resolvedRecordingMicrophone == nil
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        model.resolvedRecordingMicrophone == nil
            ? Steno.Colors.uncertain
            : Steno.Colors.confirmed
    }

    private var statusText: String {
        if let error = model.microphoneDiscoveryError {
            return error
        }

        switch model.recordingMicrophoneMode {
        case .manual(let selected):
            if let available = model.microphoneDiscovery.availableDevices
                .first(where: { $0.uid == selected.uid }) {
                return String(localized: "Selected manually: \(available.name). Steno will not use another device.")
            }
            return String(localized: "\(selected.name) is not available. Choose another microphone before recording.")

        case .automatic:
            return automaticStatusText
        }
    }

    private var automaticStatusText: String {
        if model.microphoneDiscovery.hasUnresolvedActiveDevices {
            return String(localized: "Steno cannot identify every microphone used by active apps. Choose one manually.")
        }
        guard let detected = model.microphoneDiscovery.automaticDevice else {
            if model.microphoneDiscovery.activeDevices.isEmpty {
                return String(localized: "Join the meeting first, or choose a microphone manually. Steno will not guess.")
            }
            let names = model.microphoneDiscovery.activeDevices
                .map(\.name)
                .joined(separator: ", ")
            return String(localized: "Active apps use several microphones (\(names)). Choose one manually.")
        }

        let appNames = activeApplicationNames(using: detected.uid)
        if appNames.isEmpty {
            return String(localized: "Detected from the active browser or meeting app: \(detected.name).")
        }
        return String(localized: "Detected: \(detected.name), used by \(appNames.joined(separator: ", ")).")
    }

    private func activeApplicationNames(using deviceUID: String) -> [String] {
        let names: [String] = model.microphoneDiscovery.activeClients.compactMap {
            client -> String? in
            guard client.deviceUIDs.contains(deviceUID) else { return nil }
            if let application = NSRunningApplication(
                processIdentifier: client.processID
            ), let name = application.localizedName, !name.isEmpty {
                return name
            }
            return client.bundleIdentifier
        }
        return Array(Set(names)).sorted(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
    }
}
