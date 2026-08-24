import Foundation
import StenoiOSAudio
import SwiftUI
import UIKit

enum MicrophonePermissionAction: Equatable {
    case request
    case openSettings
}

/// One permission policy shared by the recording and diagnostics surfaces.
enum MicrophonePermissionPresentation {
    static let requestTitle: LocalizedStringResource = "Ask for permission"
    static let openSettingsTitle: LocalizedStringResource = "Open Settings"
    static let deniedExplanation: LocalizedStringResource =
        "Recording is blocked until microphone access is restored in Settings."
    static let openSettingsHint: LocalizedStringResource =
        "Opens Steno's system settings, where microphone access can be enabled."

    static func action(
        for status: RecordPermissionStatus
    ) -> MicrophonePermissionAction? {
        switch status {
        case .notDetermined:
            .request
        case .denied:
            .openSettings
        case .authorized:
            nil
        }
    }

    static var settingsURL: URL {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            preconditionFailure("UIApplication returned an invalid app-settings URL")
        }
        return url
    }
}
