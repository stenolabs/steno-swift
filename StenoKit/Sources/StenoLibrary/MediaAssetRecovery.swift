@preconcurrency import AVFAudio
import Foundation
import StenoDomain

public struct MediaAssetRecoveryIssue: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case notReconstructable
    }

    public let meetingID: MeetingID
    public let fileName: String
    public let reason: Reason

    public init(
        meetingID: MeetingID,
        fileName: String,
        reason: Reason
    ) {
        self.meetingID = meetingID
        self.fileName = fileName
        self.reason = reason
    }
}

public struct MediaAssetRecoveryReport: Equatable, Sendable {
    public let recoveredAssets: [MediaAsset]
    public let issues: [MediaAssetRecoveryIssue]

    public init(
        recoveredAssets: [MediaAsset] = [],
        issues: [MediaAssetRecoveryIssue] = []
    ) {
        self.recoveredAssets = recoveredAssets
        self.issues = issues
    }
}

enum MediaAssetRecovery {
    private struct OrphanCandidate {
        let url: URL
        let assetID: MediaAssetID?
        let encodedKind: MediaAsset.Kind?
    }

    static func recoverAll(layout: LibraryLayout) throws -> MediaAssetRecoveryReport {
        let meetingDirectories = try FileManager.default.contentsOfDirectory(
            at: layout.meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var recovered: [MediaAsset] = []
        var issues: [MediaAssetRecoveryIssue] = []

        for meetingDirectory in meetingDirectories {
            let values = try meetingDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let meetingUUID = UUID(uuidString: meetingDirectory.lastPathComponent)
            else { continue }
            let meetingID = MeetingID(rawValue: meetingUUID)
            let mediaDirectory = layout.mediaDirectory(meetingID)
            let entries = try FileManager.default.contentsOfDirectory(
                at: mediaDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            let mediaFiles = try entries.filter { entry in
                guard entry.pathExtension != "json",
                      !entry.lastPathComponent.contains(".json.corrupt-")
                else { return false }
                return try entry.resourceValues(forKeys: [.isRegularFileKey])
                    .isRegularFile == true
            }
            guard !mediaFiles.isEmpty else { continue }

            let meeting: Meeting
            do {
                meeting = try JSONDocumentStore.read(
                    Meeting.self,
                    from: layout.meetingMetadata(meetingID),
                    currentSchemaVersion: Meeting.currentSchemaVersion,
                    schemaVersion: \.schemaVersion
                )
            } catch {
                appendIssues(
                    for: mediaFiles.map(orphanCandidate),
                    meetingID: meetingID,
                    to: &issues
                )
                continue
            }

            var existingAssets: [MediaAsset] = []
            var hasUnreadableMetadata = false
            for metadataURL in entries where metadataURL.pathExtension == "json" {
                do {
                    existingAssets.append(try JSONDocumentStore.read(
                        MediaAsset.self,
                        from: metadataURL,
                        currentSchemaVersion: MediaAsset.currentSchemaVersion,
                        schemaVersion: \.schemaVersion
                    ))
                } catch {
                    hasUnreadableMetadata = true
                }
            }
            let registeredFileNames = Set(existingAssets.map(\.fileName))
            let candidates = mediaFiles
                .filter { !registeredFileNames.contains($0.lastPathComponent) }
                .map(orphanCandidate)
            guard !candidates.isEmpty else { continue }
            guard !hasUnreadableMetadata else {
                appendIssues(for: candidates, meetingID: meetingID, to: &issues)
                continue
            }
            guard meeting.status == .recording || meeting.status == .interrupted else {
                appendIssues(for: candidates, meetingID: meetingID, to: &issues)
                continue
            }

            let selfDescribing = candidates.filter { $0.encodedKind != nil }
            for candidate in selfDescribing {
                recover(
                    candidate,
                    meetingID: meetingID,
                    existingAssets: &existingAssets,
                    recovered: &recovered,
                    issues: &issues,
                    layout: layout
                )
            }

            let legacy = candidates.filter { $0.encodedKind == nil }
            guard legacy.count <= 1 else {
                appendIssues(for: legacy, meetingID: meetingID, to: &issues)
                continue
            }
            if let candidate = legacy.first {
                recover(
                    candidate,
                    meetingID: meetingID,
                    existingAssets: &existingAssets,
                    recovered: &recovered,
                    issues: &issues,
                    layout: layout
                )
            }
        }

        return MediaAssetRecoveryReport(
            recoveredAssets: recovered,
            issues: issues
        )
    }

    private static func orphanCandidate(from url: URL) -> OrphanCandidate {
        let identity = assetIdentity(from: url)
        return OrphanCandidate(
            url: url,
            assetID: identity.assetID,
            encodedKind: identity.kind
        )
    }

    private static func assetIdentity(
        from url: URL
    ) -> (assetID: MediaAssetID?, kind: MediaAsset.Kind?) {
        let stem = url.deletingPathExtension().lastPathComponent
        if let rawValue = UUID(uuidString: stem) {
            return (MediaAssetID(rawValue: rawValue), nil)
        }
        for kind in [MediaAsset.Kind.micTrack, .systemTrack] {
            let suffix = "-\(kind.rawValue)"
            guard stem.hasSuffix(suffix) else { continue }
            let identifier = String(stem.dropLast(suffix.count))
            guard let rawValue = UUID(uuidString: identifier) else { continue }
            return (MediaAssetID(rawValue: rawValue), kind)
        }
        return (nil, nil)
    }

    private static func recover(
        _ candidate: OrphanCandidate,
        meetingID: MeetingID,
        existingAssets: inout [MediaAsset],
        recovered: inout [MediaAsset],
        issues: inout [MediaAssetRecoveryIssue],
        layout: LibraryLayout
    ) {
        guard candidate.url.pathExtension.lowercased() == "caf",
              let assetID = candidate.assetID,
              let kind = recordingKind(
                encodedKind: candidate.encodedKind,
                meetingID: meetingID,
                existingAssets: existingAssets,
                layout: layout
              )
        else {
            appendIssue(for: candidate, meetingID: meetingID, to: &issues)
            return
        }
        do {
            let audioFile = try AVAudioFile(forReading: candidate.url)
            let sampleRate = audioFile.fileFormat.sampleRate
            guard sampleRate > 0 else {
                appendIssue(for: candidate, meetingID: meetingID, to: &issues)
                return
            }
            let asset = MediaAsset(
                id: assetID,
                meetingID: meetingID,
                kind: kind,
                sampleRate: sampleRate,
                duration: Double(audioFile.length) / sampleRate,
                provenanceKey: RecordedTrackProvenanceKey.make(
                    meetingID: meetingID,
                    kind: kind,
                    sequence: RecordedTrackProvenanceKey.nextSequence(
                        for: meetingID,
                        kind: kind,
                        in: existingAssets
                    )
                ),
                fileName: candidate.url.lastPathComponent
            )
            let metadataURL = layout.mediaMetadata(meetingID, assetID: assetID)
            guard !existingAssets.contains(where: { $0.id == assetID }),
                  !FileManager.default.fileExists(atPath: metadataURL.path),
                  try JSONDocumentStore.writeWithoutReplacing(
                asset,
                to: metadataURL
            ) else {
                appendIssue(for: candidate, meetingID: meetingID, to: &issues)
                return
            }
            existingAssets.append(asset)
            recovered.append(asset)
        } catch {
            appendIssue(for: candidate, meetingID: meetingID, to: &issues)
        }
    }

    private static func recordingKind(
        encodedKind: MediaAsset.Kind?,
        meetingID: MeetingID,
        existingAssets: [MediaAsset],
        layout: LibraryLayout
    ) -> MediaAsset.Kind? {
        let recordingAssets = existingAssets.filter {
            $0.kind == .micTrack || $0.kind == .systemTrack
        }
        let recordingIDs = Set(recordingAssets.map(\.id))
        let recordingKinds = Set(recordingAssets.map(\.kind))
        let recordingFileNames = Set(recordingAssets.map(\.fileName))
        // Angehangene Aufnahmen besitzen mehrere Spuren je Typ; nur IDs und
        // Dateinamen muessen eindeutig bleiben.
        guard recordingIDs.count == recordingAssets.count,
              recordingFileNames.count == recordingAssets.count
        else { return nil }
        guard recordingAssets.allSatisfy({ asset in
            asset.meetingID == meetingID
                && RecordedTrackProvenanceKey.sequence(
                    of: asset.provenanceKey,
                    meetingID: meetingID,
                    kind: asset.kind
                ) != nil
                && isRegularBackingFile(
                    for: asset,
                    meetingID: meetingID,
                    layout: layout
                )
        }) else { return nil }
        if let encodedKind {
            // Selbstbeschreibende Kandidaten tragen ihren Typ im
            // Dateinamen; dass es den Typ schon gibt, ist bei angehangenen
            // Aufnahmen normal und kein Grund zur Verweigerung.
            return encodedKind
        }
        // Namenslose Alt-Dateien gab es hoechstens einmal je Typ; die
        // Herleitung gilt nur, solange genau ein Typ uebrig bleibt.
        let remainingKinds = Set([MediaAsset.Kind.micTrack, .systemTrack])
            .subtracting(recordingKinds)
        return remainingKinds.count == 1 ? remainingKinds.first : nil
    }

    private static func isRegularBackingFile(
        for asset: MediaAsset,
        meetingID: MeetingID,
        layout: LibraryLayout
    ) -> Bool {
        guard URL(fileURLWithPath: asset.fileName).lastPathComponent
                == asset.fileName
        else { return false }
        let fileURL = layout.mediaFile(meetingID, fileName: asset.fileName)
        return (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?
            .isRegularFile == true
    }

    private static func appendIssues(
        for candidates: [OrphanCandidate],
        meetingID: MeetingID,
        to issues: inout [MediaAssetRecoveryIssue]
    ) {
        for candidate in candidates {
            appendIssue(for: candidate, meetingID: meetingID, to: &issues)
        }
    }

    private static func appendIssue(
        for candidate: OrphanCandidate,
        meetingID: MeetingID,
        to issues: inout [MediaAssetRecoveryIssue]
    ) {
        issues.append(MediaAssetRecoveryIssue(
            meetingID: meetingID,
            fileName: candidate.url.lastPathComponent,
            reason: .notReconstructable
        ))
    }
}
