import AVFoundation
import Foundation
import StenoDomain

struct PreparedLegacyAudio {
    let sourceURL: URL
    let fileExtension: String
    let sampleRate: Double
    let conversion: MediaAsset.Conversion?
}

func prepareLegacyAudio(
    sourceURL: URL,
    assetID: MediaAssetID,
    workspaceDirectory: URL
) async throws -> PreparedLegacyAudio {
    if await legacyAudioIsReadable(at: sourceURL) {
        return PreparedLegacyAudio(
            sourceURL: sourceURL,
            fileExtension: sourceURL.pathExtension.isEmpty
                ? "bin"
                : sourceURL.pathExtension.lowercased(),
            sampleRate: 0,
            conversion: nil
        )
    }

    let opus = try WebMOpusReader.read(from: sourceURL)
    try FileManager.default.createDirectory(
        at: workspaceDirectory,
        withIntermediateDirectories: true
    )
    let convertedURL = workspaceDirectory.appendingPathComponent("\(assetID).caf")
    _ = try OpusCAFWriter.write(opus, to: convertedURL)
    guard await legacyAudioIsReadable(at: convertedURL) else {
        throw LegacyExchangeError.invalidFormat(
            "Converted CAF is not readable for \(sourceURL.lastPathComponent)"
        )
    }
    return PreparedLegacyAudio(
        sourceURL: convertedURL,
        fileExtension: "caf",
        sampleRate: opus.sampleRate,
        conversion: .webMOpusRepackagedToCAF
    )
}

func legacyAudioIsReadable(at url: URL) async -> Bool {
    (try? await AVURLAsset(url: url).load(.isReadable)) == true
}

func legacyMediaProvenance(
    entry: LegacyStemEntry,
    sourceURL: URL
) -> String {
    let provenanceKey = "legacy:\(entry.stem)"
    guard entry.recordings.count != 1 else { return provenanceKey }
    let pathExtension = sourceURL.pathExtension.isEmpty
        ? "bin"
        : sourceURL.pathExtension.lowercased()
    return "\(provenanceKey).\(pathExtension)"
}
