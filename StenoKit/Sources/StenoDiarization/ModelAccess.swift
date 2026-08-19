import Foundation

private let diarizationModelInstallationMarkerName = ".steno-diarization-install-incomplete"

func diarizationModelInstallationIsIncomplete(in baseDirectory: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: baseDirectory
            .appendingPathComponent(diarizationModelInstallationMarkerName)
            .path
    )
}

func markDiarizationModelInstallationIncomplete(in baseDirectory: URL) throws {
    try FileManager.default.createDirectory(
        at: baseDirectory,
        withIntermediateDirectories: true
    )
    try Data("incomplete\n".utf8).write(
        to: baseDirectory.appendingPathComponent(diarizationModelInstallationMarkerName),
        options: .atomic
    )
}

func clearDiarizationModelInstallationMarker(in baseDirectory: URL) throws {
    let marker = baseDirectory.appendingPathComponent(diarizationModelInstallationMarkerName)
    guard FileManager.default.fileExists(atPath: marker.path) else { return }
    try FileManager.default.removeItem(at: marker)
}

func missingModelURLs(
    required: [URL],
    fileExists: (URL) -> Bool
) -> [URL] {
    required.filter { !fileExists($0) }
}
