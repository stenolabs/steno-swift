import AVFoundation
import Foundation
import StenoDomain

enum AudioAssetReadability {
    static func isReadable(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? await AVURLAsset(url: url).load(.isReadable)) == true
    }
}

struct AudioExportDialogRequest: Equatable {
    let meeting: Meeting
    let options: [AudioExportOption]

    @MainActor
    static func load(
        for meeting: Meeting,
        options loadOptions: (MeetingID) async -> [AudioExportOption]
    ) async -> AudioExportDialogRequest? {
        let options = await loadOptions(meeting.id)
        guard !options.isEmpty else { return nil }
        return AudioExportDialogRequest(meeting: meeting, options: options)
    }
}

enum AudioExportOptionKind: Equatable {
    case original
    case stereoM4A
}

enum AudioExportOption: Identifiable, Equatable {
    case original(asset: MediaAsset, label: String)
    case stereoM4A(microphone: MediaAsset, system: MediaAsset)

    var id: String {
        switch self {
        case let .original(asset, _):
            "original:\(asset.id)"
        case let .stereoM4A(microphone, system):
            "stereo:\(microphone.id):\(system.id)"
        }
    }

    var kind: AudioExportOptionKind {
        switch self {
        case .original: .original
        case .stereoM4A: .stereoM4A
        }
    }

    var label: String {
        switch self {
        case let .original(_, label): label
        case .stereoM4A: "Both tracks - stereo M4A"
        }
    }
}

enum AudioExportPresentation {
    static func stereoFileName(for meeting: Meeting) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let slug = meeting.title
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let safeTitle = slug.isEmpty ? "meeting" : String(slug.prefix(80))
        return "\(safeTitle) - Microphone left, System right.m4a"
    }

    static func options(for assets: [MediaAsset]) -> [AudioExportOption] {
        var options = assets.map { asset in
            AudioExportOption.original(
                asset: asset,
                label: ChannelLabel.trackName(asset.kind.rawValue)
            )
        }
        let microphones = assets.filter { $0.kind == .micTrack }
        let systemTracks = assets.filter { $0.kind == .systemTrack }
        if microphones.count == 1,
           systemTracks.count == 1,
           let microphone = microphones.first,
           let system = systemTracks.first
        {
            options.append(.stereoM4A(microphone: microphone, system: system))
        }
        return options
    }

    static func options(
        for assets: [MediaAsset],
        resolvingURLWith urlForAsset: @Sendable (MediaAsset) -> URL
    ) async -> [AudioExportOption] {
        var readableAssets: [MediaAsset] = []
        for asset in assets where await AudioAssetReadability.isReadable(
            urlForAsset(asset)
        ) {
            readableAssets.append(asset)
        }
        return options(for: readableAssets)
    }
}
