import Foundation
import StenoAudioCore
import StenoMacAudio

enum RecordingMicrophoneMode: Codable, Equatable, Sendable {
    case automatic
    case manual(MicrophoneDevice)
}

enum RecordingMicrophoneSelection {
    static func resolve(
        mode: RecordingMicrophoneMode,
        discovery: MicrophoneDiscoverySnapshot
    ) throws -> MicrophoneDevice {
        switch mode {
        case .automatic:
            guard let device = discovery.automaticDevice else {
                throw AudioRecordingError.audioSourceUnavailable(
                    automaticFailureReason(discovery)
                )
            }
            return device

        case .manual(let selected):
            guard let available = discovery.availableDevices.first(where: {
                $0.uid == selected.uid
            }) else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "the selected microphone \(selected.name) is not available"
                )
            }
            return available
        }
    }

    private static func automaticFailureReason(
        _ discovery: MicrophoneDiscoverySnapshot
    ) -> String {
        if discovery.hasUnresolvedActiveDevices {
            return "not every microphone used by active apps could be identified; choose one manually"
        }
        if discovery.activeDevices.isEmpty {
            return "no other app is currently using a microphone; choose one manually"
        }
        return "active apps are using more than one microphone; choose one manually"
    }
}

struct MicrophoneSelectionStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "steno.recording.microphone.selection"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> RecordingMicrophoneMode {
        guard let data = defaults.data(forKey: key),
              let mode = try? JSONDecoder().decode(
                  RecordingMicrophoneMode.self,
                  from: data
              ) else {
            return .automatic
        }
        return mode
    }

    func save(_ mode: RecordingMicrophoneMode) {
        guard let data = try? JSONEncoder().encode(mode) else { return }
        defaults.set(data, forKey: key)
    }
}
