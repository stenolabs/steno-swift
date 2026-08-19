import Foundation
import StenoDomain
import StenoLibrary

public struct LegacyImporter: Sendable {
    typealias CommitPreparedMeeting = @Sendable (
        Library,
        PreparedMeetingImport
    ) async throws -> PreparedMeetingCommitResult

    public let sourceRoot: URL
    public let library: Library
    public let folders: FolderStore
    public let timestampParser: LegacyTimestampParser
    private let commitPreparedMeeting: CommitPreparedMeeting

    public init(
        sourceRoot: URL,
        library: Library,
        folders: FolderStore,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser()
    ) {
        self.sourceRoot = sourceRoot
        self.library = library
        self.folders = folders
        self.timestampParser = timestampParser
        commitPreparedMeeting = { library, prepared in
            try await library.commitPreparedMeeting(prepared)
        }
    }

    init(
        sourceRoot: URL,
        library: Library,
        folders: FolderStore,
        timestampParser: LegacyTimestampParser = LegacyTimestampParser(),
        commitPreparedMeeting: @escaping CommitPreparedMeeting
    ) {
        self.sourceRoot = sourceRoot
        self.library = library
        self.folders = folders
        self.timestampParser = timestampParser
        self.commitPreparedMeeting = commitPreparedMeeting
    }

    public func performImport(
        progress: (@Sendable (LegacyImportProgress) -> Void)? = nil
    ) async throws -> ImportReport {
        let audioWorkspaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "StenoLegacyImport-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: audioWorkspaceDirectory) }
        let snapshot = try LegacyStore(rootURL: sourceRoot).scan()
        var report = ImportReport(
            orphans: snapshot.orphans,
            pendingDeleteFindings: snapshot.pendingDeleteFiles
        )
        let importable = snapshot.entries.filter {
            $0.summary != nil && $0.transcript != nil
        }
        var completed = 0
        let folderNames = try readFolderNames()
        let customTemplateNames = try readCustomTemplateNames()
        var meetingIDsByStem: [String: MeetingID] = [:]
        var runIDsByStem: [String: RunID] = [:]

        // Fortschritt wird erst nach erfolgreicher Verarbeitung gemeldet:
        // Ein defer würde auch einen abbrechenden Stem als erledigt zeigen.
        func reportProgress(_ stem: String) {
            completed += 1
            progress?(LegacyImportProgress(
                completed: completed,
                total: importable.count,
                stem: stem
            ))
        }

        for entry in importable {
            let provenanceKey = "legacy:\(entry.stem)"
            if let existingMeetingID = try await library.meetingID(
                forProvenanceKey: provenanceKey
            ) {
                report.duplicates.append(entry.stem)
                meetingIDsByStem[entry.stem] = existingMeetingID
                let repair = try await repairUnreadableAudio(
                    entry: entry,
                    meetingID: existingMeetingID,
                    audioWorkspaceDirectory: audioWorkspaceDirectory
                )
                report.audioRepaired += repair.repaired
                report.audioMissing += repair.missing
                report.warnings.append(contentsOf: repair.warnings)
                if let runID = try legacyRunID(
                    layout: library.layout,
                    meetingID: existingMeetingID
                ) {
                    runIDsByStem[entry.stem] = runID
                }
                reportProgress(entry.stem)
                continue
            }

            let prepared = try await prepareLegacyMeeting(
                entry: entry,
                folderNames: folderNames,
                customTemplateNames: customTemplateNames,
                timestampParser: timestampParser,
                audioWorkspaceDirectory: audioWorkspaceDirectory
            )
            let commitResult = try await commitPreparedMeeting(library, prepared.bundle)
            switch commitResult {
            case .imported:
                break
            case .alreadyPresent(let existingMeetingID, _):
                report.duplicates.append(entry.stem)
                meetingIDsByStem[entry.stem] = existingMeetingID
                let repair = try await repairUnreadableAudio(
                    entry: entry,
                    meetingID: existingMeetingID,
                    audioWorkspaceDirectory: audioWorkspaceDirectory
                )
                report.audioRepaired += repair.repaired
                report.audioMissing += repair.missing
                report.warnings.append(contentsOf: repair.warnings)
                if let runID = try legacyRunID(
                    layout: library.layout,
                    meetingID: existingMeetingID
                ) {
                    runIDsByStem[entry.stem] = runID
                }
                reportProgress(entry.stem)
                continue
            case .commitOutcomeUncertain(let meetingID, _):
                throw LegacyImportError.commitOutcomeUncertain(
                    stem: entry.stem,
                    meetingID: meetingID
                )
            }
            // Der Ordner wird sofort gesetzt und nicht der einmaligen
            // Uebernahme ueberlassen: die ist beim zweiten Import laengst
            // gelaufen, und ohne das kaeme jedes spaeter importierte Meeting
            // ohne Ordner an.
            await fileIntoLegacyFolder(prepared.bundle.meeting)
            meetingIDsByStem[entry.stem] = prepared.bundle.meeting.id
            if let runID = prepared.diarizationRunID {
                runIDsByStem[entry.stem] = runID
            }
            report.meetingsCreated += 1
            report.audioCopied += prepared.bundle.media.count
            if prepared.bundle.media.isEmpty { report.audioMissing += 1 }
            report.revisionsCreated += 1
            report.clustersCreated += prepared.clusterCount
            report.reportsCreated += prepared.bundle.templateResults.count
            report.notesCreated += prepared.bundle.notes.count
            report.warnings.append(contentsOf: prepared.warnings)
            reportProgress(entry.stem)
        }

        try await importPersonProfiles(
            meetingIDsByStem: meetingIDsByStem,
            runIDsByStem: runIDsByStem,
            report: &report
        )
        report.duplicates.sort()
        report.warnings.sort()
        return report
    }

    /// Legt das frisch importierte Meeting in den Ordner, den es aus der alten
    /// App mitbringt. Bei mehreren gewinnt der erste; die vollstaendige Liste
    /// bleibt in `metadata.legacyFolders` erhalten, es geht also nichts
    /// verloren.
    ///
    /// Bewusst ohne Fehler nach aussen: ein Meeting ohne Ordner ist ein
    /// Schoenheitsfehler, ein abgebrochener Import waere einer mit Folgen.
    private func fileIntoLegacyFolder(_ meeting: Meeting) async {
        guard let name = meeting.metadata?.legacyFolders.first,
              let folder = try? await folders.folder(named: name)
        else { return }
        _ = try? await library.setMeetingFolder(meeting.id, folderID: folder.id)
    }

    private func readFolderNames() throws -> [String: String] {
        let url = sourceRoot.appending(path: "folders.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return Dictionary(uniqueKeysWithValues: try LegacyFolders.read(
            from: url,
            timestampParser: timestampParser
        ).folders.map { ($0.id, $0.name) })
    }

    private func repairUnreadableAudio(
        entry: LegacyStemEntry,
        meetingID: MeetingID,
        audioWorkspaceDirectory: URL
    ) async throws -> LegacyAudioRepairResult {
        let assets = try await library.listMediaAssets(meetingID: meetingID)
        var repaired = 0
        var warnings: [String] = []
        var encounteredUnreadableAsset = false
        var hasReadableAsset = false

        for asset in assets {
            guard let sourceURL = entry.recordings.first(where: {
                legacyMediaProvenance(entry: entry, sourceURL: $0)
                    == asset.provenanceKey
            }) else {
                // Ein Meeting kann nach dem Altimport weitere Medien erhalten
                // haben. Der Reparaturlauf darf nur Assets dieses Legacy-Stems
                // anfassen.
                continue
            }
            let existingURL = library.layout.mediaFile(
                meetingID,
                fileName: asset.fileName
            )
            if await legacyAudioIsReadable(at: existingURL) {
                hasReadableAsset = true
                continue
            }
            encounteredUnreadableAsset = true

            do {
                let preparedAudio = try await prepareLegacyAudio(
                    sourceURL: sourceURL,
                    assetID: asset.id,
                    workspaceDirectory: audioWorkspaceDirectory
                )
                let replacement = MediaAsset(
                    schemaVersion: asset.schemaVersion,
                    id: asset.id,
                    meetingID: asset.meetingID,
                    kind: asset.kind,
                    sampleRate: preparedAudio.sampleRate,
                    duration: asset.duration,
                    provenanceKey: asset.provenanceKey,
                    fileName: "\(asset.id).\(preparedAudio.fileExtension)",
                    conversion: preparedAudio.conversion
                )
                _ = try await library.replaceMediaAssetAtomically(
                    PreparedMediaImport(
                        asset: replacement,
                        sourceURL: preparedAudio.sourceURL
                    )
                )
                repaired += 1
                hasReadableAsset = true
            } catch {
                warnings.append(
                    "Stem \(entry.stem) audio \(sourceURL.lastPathComponent) "
                        + "could not be repaired: \(error)"
                )
            }
        }
        return LegacyAudioRepairResult(
            repaired: repaired,
            missing: encounteredUnreadableAsset && !hasReadableAsset ? 1 : 0,
            warnings: warnings
        )
    }

    private func readCustomTemplateNames() throws -> [String: String] {
        let url = sourceRoot.appending(path: "config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return Dictionary(uniqueKeysWithValues: try LegacyPersonProfiles.read(
            from: url
        ).customTemplates.map { ($0.id, $0.name) })
    }

    private func importPersonProfiles(
        meetingIDsByStem: [String: MeetingID],
        runIDsByStem: [String: RunID],
        report: inout ImportReport
    ) async throws {
        let configURL = sourceRoot.appending(path: "config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let legacyProfiles = try LegacyPersonProfiles.read(from: configURL).profiles
        let store = try IdentityStore(layout: library.layout)
        var persons = try await store.listPersons()
        var changed = false

        for legacy in legacyProfiles {
            let key = normalizedPersonName(legacy.displayName)
            let existingIndex = persons.firstIndex {
                normalizedPersonName($0.displayName) == key
            }
            let personID: PersonID
            let index: Int
            if let existingIndex {
                personID = persons[existingIndex].id
                index = existingIndex
            } else {
                personID = UUID(uuidString: legacy.personID)
                    .map(PersonID.init(rawValue:)) ?? PersonID()
                persons.append(Person(
                    id: personID,
                    displayName: legacy.displayName,
                    createdAt: legacy.createdAt,
                    updatedAt: legacy.updatedAt
                ))
                index = persons.index(before: persons.endIndex)
                report.personsCreated += 1
                changed = true
            }

            var evidenceIDs = Set(persons[index].prototypes.map(\.id))
            evidenceIDs.formUnion(persons[index].hardNegatives.map(\.id))
            for prototype in legacy.prototypes {
                guard let evidence = makePrototype(
                    prototype,
                    personID: personID,
                    meetingIDsByStem: meetingIDsByStem,
                    runIDsByStem: runIDsByStem,
                    warnings: &report.warnings
                ), evidenceIDs.insert(evidence.id).inserted else { continue }
                persons[index].prototypes.append(evidence)
                report.prototypesCreated += 1
                changed = true
            }
            for negative in legacy.hardNegatives {
                guard let evidence = makeHardNegative(
                    negative,
                    personID: personID,
                    meetingIDsByStem: meetingIDsByStem,
                    runIDsByStem: runIDsByStem,
                    warnings: &report.warnings
                ), evidenceIDs.insert(evidence.id).inserted else { continue }
                persons[index].hardNegatives.append(evidence)
                report.prototypesCreated += 1
                changed = true
            }
            if legacy.updatedAt > persons[index].updatedAt {
                persons[index].updatedAt = legacy.updatedAt
                changed = true
            }
        }
        if changed {
            try await store.replacePersons(persons)
        }
    }
}

private struct LegacyAudioRepairResult {
    let repaired: Int
    let missing: Int
    let warnings: [String]
}

private func normalizedPersonName(_ name: String) -> String {
    name.split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}

private func makePrototype(
    _ legacy: LegacySpeakerPrototype,
    personID: PersonID,
    meetingIDsByStem: [String: MeetingID],
    runIDsByStem: [String: RunID],
    warnings: inout [String]
) -> SpeakerPrototype? {
    guard legacy.embeddingMean.count == 256 else {
        warnings.append("Prototype \(legacy.prototypeID) has \(legacy.embeddingMean.count) dimensions")
        return nil
    }
    guard let uuid = UUID(uuidString: legacy.prototypeID) else {
        warnings.append("Prototype has invalid id \(legacy.prototypeID)")
        return nil
    }
    let meetingID = meetingIDsByStem[legacy.meetingID]
    let runID = runIDsByStem[legacy.meetingID]
    if meetingID == nil {
        warnings.append("Prototype \(legacy.prototypeID) has dangling meeting \(legacy.meetingID)")
    }
    return SpeakerPrototype(
        id: SpeakerEvidenceID(rawValue: uuid),
        personID: personID,
        embedding: legacy.embeddingMean,
        sampleCount: legacy.sampleCount,
        qualityScore: legacy.qualityScore,
        recordingType: legacy.recordingType,
        channel: legacy.channel,
        meetingID: meetingID,
        runID: runID,
        clusterID: prefixedClusterID(
            channel: legacy.channel,
            speakerID: legacy.diarizationSpeakerID
        ),
        speechDurationSeconds: legacy.speechDurationSeconds,
        segmentCount: legacy.segmentCount,
        source: legacy.createdFrom,
        createdAt: legacy.createdAt
    )
}

private func makeHardNegative(
    _ legacy: LegacySpeakerPrototype,
    personID: PersonID,
    meetingIDsByStem: [String: MeetingID],
    runIDsByStem: [String: RunID],
    warnings: inout [String]
) -> HardNegative? {
    guard legacy.embeddingMean.count == 256 else {
        warnings.append("Hard negative \(legacy.prototypeID) has \(legacy.embeddingMean.count) dimensions")
        return nil
    }
    guard let uuid = UUID(uuidString: legacy.prototypeID) else {
        warnings.append("Hard negative has invalid id \(legacy.prototypeID)")
        return nil
    }
    let meetingID = meetingIDsByStem[legacy.meetingID]
    let runID = runIDsByStem[legacy.meetingID]
    if meetingID == nil {
        warnings.append("Hard negative \(legacy.prototypeID) has dangling meeting \(legacy.meetingID)")
    }
    return HardNegative(
        id: SpeakerEvidenceID(rawValue: uuid),
        personID: personID,
        embedding: legacy.embeddingMean,
        sampleCount: legacy.sampleCount,
        qualityScore: legacy.qualityScore,
        recordingType: legacy.recordingType,
        channel: legacy.channel,
        meetingID: meetingID,
        runID: runID,
        clusterID: prefixedClusterID(
            channel: legacy.channel,
            speakerID: legacy.diarizationSpeakerID
        ),
        speechDurationSeconds: legacy.speechDurationSeconds,
        segmentCount: legacy.segmentCount,
        source: legacy.createdFrom,
        createdAt: legacy.createdAt
    )
}

private func prefixedClusterID(channel: String?, speakerID: String) -> String {
    guard let channel, !channel.isEmpty else { return speakerID }
    return "\(channel)/\(speakerID)"
}

private func legacyRunID(layout: LibraryLayout, meetingID: MeetingID) throws -> RunID? {
    let directories = try FileManager.default.contentsOfDirectory(
        at: layout.runsDirectory(meetingID),
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    for directory in directories {
        let url = directory.appending(path: "run.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let run = try? JSONDecoder().decode(
                ProcessingRun.self,
                from: Data(contentsOf: url)
              ),
              run.kind == .diarization,
              run.engine.name == "legacy-stenoai" else { continue }
        return run.id
    }
    return nil
}
