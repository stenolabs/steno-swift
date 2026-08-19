import AVFoundation
import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import Synchronization
import Testing
@testable import StenoExchange

@Suite("Legacy importer")
struct LegacyImporterTests {
    private let berlin = LegacyTimestampParser(
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )

    @Test("imports a complete synthetic installation without touching its source")
    func fullImport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        let sourceAudio = try makeLegacyInstallation(at: source)
        let originalAudio = try Data(contentsOf: sourceAudio)
        let library = try Library.open(at: root.appending(path: "Library"))
        let folders = try FolderStore.open(layout: library.layout)

        let report = try await LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: folders,
            timestampParser: berlin
        ).performImport()

        #expect(report.meetingsCreated == 2)
        #expect(report.audioCopied == 1)
        #expect(report.audioMissing == 1)
        #expect(report.revisionsCreated == 2)
        #expect(report.clustersCreated == 2)
        #expect(report.personsCreated == 1)
        #expect(report.prototypesCreated == 3)
        #expect(report.reportsCreated == 4)
        #expect(report.notesCreated == 1)
        #expect(report.duplicates.isEmpty)
        #expect(report.orphans == [
            LegacyOrphan(stem: "orphan", kind: .recordingWithoutSidecars),
        ])
        #expect(report.pendingDeleteFindings.map(\.lastPathComponent) == ["stale_summary.md"])
        #expect(report.warnings.contains { $0.contains("dangling-meeting") })

        let meetings = try await library.listMeetings()
        let diarized = try #require(meetings.first { $0.title == "Import Planung" })
        let plain = try #require(meetings.first { $0.title == "Ohne Audio" })
        #expect(diarized.createdAt == Date(timeIntervalSince1970: 1_785_933_296))
        #expect(diarized.metadata?.legacyProvenanceKey == "legacy:sysaudio-1785933296000-Planung")
        #expect(diarized.metadata?.legacyFolders == ["Arbeit"])
        // Der Ordner entsteht beim Import selbst. Die einmalige Uebernahme des
        // Altbestands hilft hier nicht: sie ist beim zweiten Import laengst
        // gelaufen, und ohne das kaeme jedes spaeter importierte Meeting ohne
        // Ordner an.
        let storedFolders = try await folders.listFolders()
        #expect(storedFolders.map(\.name) == ["Arbeit"])
        #expect(diarized.folderID == storedFolders.first?.id)
        #expect(plain.folderID == nil)
        #expect(plain.metadata?.legacyProvenanceKey == "legacy:Ohne Audio")
        #expect(plain.createdAt == berlin.date(fromISO8601: "2026-08-05T12:34:56"))

        let assets = try await library.listMediaAssets(meetingID: diarized.id)
        let asset = try #require(assets.first)
        #expect(asset.kind == .imported)
        #expect(asset.provenanceKey == "legacy:sysaudio-1785933296000-Planung")
        #expect(asset.fileName.hasSuffix(".wav"))
        #expect(asset.conversion == nil)
        #expect(try await AVURLAsset(
            url: library.layout.mediaFile(diarized.id, fileName: asset.fileName)
        ).load(.isReadable))
        #expect(try Data(contentsOf: library.layout.mediaFile(diarized.id, fileName: asset.fileName)) == originalAudio)
        #expect(FileManager.default.fileExists(atPath: sourceAudio.path))

        let revision = try await library.loadCurrentRevision(meetingID: diarized.id)
        let maybeRun = try legacyDiarizationRun(
            in: library.layout,
            meetingID: diarized.id
        )
        let run = try #require(maybeRun)
        #expect(revision.origin == .legacyImport)
        #expect(revision.createdAt == diarized.createdAt)
        #expect(revision.turns.count == 2)
        #expect(revision.turns[0].start == 5)
        #expect(revision.turns[0].end == 65)
        #expect(revision.turns[0].speaker == .cluster(
            runID: run.id,
            clusterID: "mic/SPEAKER_0"
        ))
        #expect(revision.turns[1].end == 66)
        #expect(revision.turns[1].segments.first?.words.isEmpty == true)

        #expect(run.kind == .diarization)
        #expect(run.status == .finished)
        #expect(run.engine.name == "legacy-stenoai")
        let clusterArtifact = try JSONDecoder().decode(
            LegacyDiarizationArtifact.self,
            from: Data(contentsOf: library.layout.runDiarization(diarized.id, runID: run.id))
        )
        #expect(clusterArtifact.clusters.map(\.clusterID) == ["mic/SPEAKER_0", "system/SPEAKER_0"])
        #expect(clusterArtifact.clusters.allSatisfy { $0.embedding.count == 256 })
        #expect(clusterArtifact.clusters.first?.containsMultipleSpeakers == true)
        #expect(clusterArtifact.segmentsByClusterID["mic/SPEAKER_0"] == [
            LegacySpeakerSegment(start: 5, end: 11),
        ])

        let plainRevision = try await library.loadCurrentRevision(meetingID: plain.id)
        #expect(plainRevision.turns.count == 2)
        #expect(plainRevision.turns.allSatisfy { $0.speaker == nil })
        #expect(try await library.listMediaAssets(meetingID: plain.id).isEmpty)

        let results = try storedTemplateResults(in: library.layout, meetingID: diarized.id)
        #expect(results.count == 3)
        let standard = try #require(results.first { $0.template.id == "standard" })
        #expect(standard.markdown.contains("Vom Nutzer geändert"))
        #expect(!standard.markdown.contains("Ursprüngliche Zusammenfassung"))
        #expect(results.allSatisfy { $0.engine.name == "legacy-stenoai" })
        #expect(results.first { $0.template.id == "detailed" }?.template.name == "Aus Config")
        #expect(try String(
            contentsOf: library.layout.notesDirectory(diarized.id)
                .appending(path: "legacy-user-notes.md"),
            encoding: .utf8
        ) == "Nur lokal behalten.")

        let persons = try await IdentityStore(layout: library.layout).listPersons()
        let ada = try #require(persons.first)
        #expect(ada.displayName == "Ada")
        #expect(ada.prototypes.count == 2)
        #expect(ada.prototypes.first?.sampleCount == 3)
        #expect(ada.prototypes.first?.qualityScore == 0.9)
        #expect(ada.prototypes.first?.meetingID == diarized.id)
        #expect(ada.prototypes.first?.runID == run.id)
        #expect(ada.hardNegatives.count == 1)
        #expect(ada.hardNegatives.first?.meetingID == nil)
        #expect(ada.hardNegatives.first?.runID == nil)
        #expect(ada.hardNegatives.first?.channel == nil)

        let queuedJobs = try FileManager.default.contentsOfDirectory(
            at: library.layout.jobsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(queuedJobs.isEmpty)
    }

    @Test("keeps transcript labels as channels when the speaker manifest is absent")
    func diarizedTranscriptWithoutManifest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        let stem = "Ohne Manifest"
        try writeFixture(
            "import_diarized_transcript",
            extension: "txt",
            to: source.appending(path: "transcripts/\(stem)_transcript.txt")
        )
        try writeFixture(
            "import_summary",
            extension: "md",
            to: source.appending(path: "output/\(stem)_summary.md")
        )
        try writeFixture(
            "legacy_speakers_without_lines",
            extension: "json",
            to: source.appending(path: "output/\(stem)_speakers.json")
        )
        let library = try Library.open(at: root.appending(path: "Library"))

        let report = try await LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: try FolderStore.open(layout: library.layout),
            timestampParser: berlin
        ).performImport()

        let meeting = try #require(try await library.listMeetings().first)
        let revision = try await library.loadCurrentRevision(meetingID: meeting.id)
        #expect(report.meetingsCreated == 1)
        #expect(revision.turns.map(\.speaker) == [
            .channel("You"),
            .channel("Speaker 2"),
        ])
    }

    @Test("uses extension-qualified provenance for colliding recording stems")
    func recordingStemCollision() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        _ = try makeLegacyInstallation(at: source)
        let stem = "sysaudio-1785933296000-Planung"
        try writeSyntheticReadableAudio(
            to: source.appending(path: "recordings/\(stem).caf")
        )
        let library = try Library.open(at: root.appending(path: "Library"))

        let report = try await LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: try FolderStore.open(layout: library.layout),
            timestampParser: berlin
        ).performImport()

        let meeting = try #require(try await library.listMeetings().first {
            $0.title == "Import Planung"
        })
        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        #expect(report.audioCopied == 2)
        #expect(Set(assets.map(\.provenanceKey)) == [
            "legacy:\(stem).wav",
            "legacy:\(stem).caf",
        ])
    }

    @Test("repackages an unreadable legacy WebM as a readable CAF")
    func importsWebMAsReadableCAF() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        let stem = "WebM Import"
        let sourceAudio = try makeLegacyAudioInstallation(
            at: source,
            stem: stem,
            audio: makeSyntheticImportWebM()
        )
        let originalWebM = try Data(contentsOf: sourceAudio)
        let library = try Library.open(at: root.appending(path: "Library"))

        let report = try await LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: try FolderStore.open(layout: library.layout),
            timestampParser: berlin
        ).performImport()

        let meeting = try #require(try await library.listMeetings().first)
        let asset = try #require(try await library.listMediaAssets(meetingID: meeting.id).first)
        let storedURL = library.layout.mediaFile(meeting.id, fileName: asset.fileName)
        #expect(report.audioCopied == 1)
        #expect(report.audioMissing == 0)
        #expect(asset.fileName.hasSuffix(".caf"))
        #expect(asset.provenanceKey == "legacy:\(stem)")
        #expect(asset.conversion == .webMOpusRepackagedToCAF)
        #expect(try await AVURLAsset(url: storedURL).load(.isReadable))
        #expect(try Data(contentsOf: sourceAudio) == originalWebM)
    }

    @Test("omits an unconvertible WebM and reports the missing audio")
    func omitsUnconvertibleWebM() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        let stem = "Defektes WebM"
        _ = try makeLegacyAudioInstallation(
            at: source,
            stem: stem,
            audio: Data("not a WebM file".utf8)
        )
        let library = try Library.open(at: root.appending(path: "Library"))

        let report = try await LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: try FolderStore.open(layout: library.layout),
            timestampParser: berlin
        ).performImport()

        let meeting = try #require(try await library.listMeetings().first)
        #expect(report.meetingsCreated == 1)
        #expect(report.audioCopied == 0)
        #expect(report.audioMissing == 1)
        #expect(report.warnings.contains {
            $0.contains(stem) && $0.contains("could not be converted")
        })
        #expect(try await library.listMediaAssets(meetingID: meeting.id).isEmpty)
    }

    @Test("repairs an unreadable legacy asset without changing its identity")
    func repairsUnreadableExistingAsset() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scenario = try await makeLegacyRepairScenario(
            root: root,
            stem: "Reparatur"
        )

        let report = try await LegacyImporter(
            sourceRoot: scenario.source,
            library: scenario.library,
            folders: try FolderStore.open(layout: scenario.library.layout),
            timestampParser: berlin
        ).performImport()

        let assets = try await scenario.library.listMediaAssets(
            meetingID: scenario.meetingID
        )
        let repaired = try #require(assets.first)
        let repairedURL = scenario.library.layout.mediaFile(
            scenario.meetingID,
            fileName: repaired.fileName
        )
        #expect(report.meetingsCreated == 0)
        #expect(report.audioRepaired == 1)
        #expect(report.duplicates == ["Reparatur"])
        #expect(repaired.id == scenario.assetID)
        #expect(repaired.provenanceKey == "legacy:Reparatur")
        #expect(repaired.fileName == "\(scenario.assetID).caf")
        #expect(repaired.conversion == .webMOpusRepackagedToCAF)
        #expect(try await AVURLAsset(url: repairedURL).load(.isReadable))
        #expect(!FileManager.default.fileExists(atPath: scenario.oldMediaURL.path))
    }

    @Test("does not rewrite an asset on the import after a successful repair")
    func repairedAssetIsIdempotent() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scenario = try await makeLegacyRepairScenario(
            root: root,
            stem: "Idempotente Reparatur"
        )
        let importer = LegacyImporter(
            sourceRoot: scenario.source,
            library: scenario.library,
            folders: try FolderStore.open(layout: scenario.library.layout),
            timestampParser: berlin
        )
        let first = try await importer.performImport()
        let firstAsset = try #require(try await scenario.library.listMediaAssets(
            meetingID: scenario.meetingID
        ).first)
        let firstURL = scenario.library.layout.mediaFile(
            scenario.meetingID,
            fileName: firstAsset.fileName
        )
        let firstBytes = try Data(contentsOf: firstURL)

        let second = try await importer.performImport()

        let secondAsset = try #require(try await scenario.library.listMediaAssets(
            meetingID: scenario.meetingID
        ).first)
        #expect(first.audioRepaired == 1)
        #expect(second.audioRepaired == 0)
        #expect(second.audioCopied == 0)
        #expect(second.meetingsCreated == 0)
        #expect(secondAsset == firstAsset)
        #expect(try Data(contentsOf: firstURL) == firstBytes)
    }

    @Test("a repeated import skips every known stem and adds no identity evidence")
    func repeatedImportIsIdempotent() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        _ = try makeLegacyInstallation(at: source)
        let library = try Library.open(at: root.appending(path: "Library"))
        let folders = try FolderStore.open(layout: library.layout)
        let importer = LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: folders,
            timestampParser: berlin
        )
        _ = try await importer.performImport()

        let repeated = try await importer.performImport()

        #expect(repeated.meetingsCreated == 0)
        #expect(repeated.audioCopied == 0)
        #expect(repeated.revisionsCreated == 0)
        #expect(repeated.personsCreated == 0)
        #expect(repeated.prototypesCreated == 0)
        #expect(repeated.duplicates == ["Ohne Audio", "sysaudio-1785933296000-Planung"])
        #expect(try await library.listMeetings().count == 2)
        let people = try await IdentityStore(layout: library.layout).listPersons()
        #expect(people.first?.prototypes.count == 2)
        #expect(people.first?.hardNegatives.count == 1)
    }

    @Test("an uncertain library commit aborts without reporting legacy success")
    func uncertainCommitDoesNotCountAsCreated() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        let stem = "Ungewisser Commit"
        try makeLegacyTextInstallation(at: source, stem: stem)
        let library = try Library.open(at: root.appending(path: "Library"))
        let committedMeetingID = Mutex<MeetingID?>(nil)
        let progress = Mutex<[LegacyImportProgress]>([])

        do {
            _ = try await LegacyImporter(
                sourceRoot: source,
                library: library,
                folders: try FolderStore.open(layout: library.layout),
                timestampParser: berlin,
                commitPreparedMeeting: { _, prepared in
                    committedMeetingID.withLock { $0 = prepared.meeting.id }
                    return .commitOutcomeUncertain(prepared.meeting.id)
                }
            ).performImport { update in
                progress.withLock { $0.append(update) }
            }
            Issue.record("expected an uncertain legacy commit error")
        } catch let error as LegacyImportError {
            let meetingID = try #require(committedMeetingID.withLock { $0 })
            #expect(error == .commitOutcomeUncertain(stem: stem, meetingID: meetingID))
        }

        #expect(progress.withLock { $0 }.isEmpty)
        #expect(try await library.listMeetings().isEmpty)
    }

    @Test("an already-present library result follows legacy duplicate semantics")
    func alreadyPresentCommitCountsAsDuplicate() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        let stem = "Paralleles Duplikat"
        try makeLegacyTextInstallation(at: source, stem: stem)
        let library = try Library.open(at: root.appending(path: "Library"))
        let existing = Meeting(title: "Existing", status: .ready)
        _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
            meeting: existing,
            media: [],
            revision: TranscriptRevision(
                meetingID: existing.id,
                origin: .legacyImport,
                turns: []
            )
        ))

        let report = try await LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: try FolderStore.open(layout: library.layout),
            timestampParser: berlin,
            commitPreparedMeeting: { _, _ in .alreadyPresent(existing.id) }
        ).performImport()

        #expect(report.meetingsCreated == 0)
        #expect(report.audioCopied == 0)
        #expect(report.revisionsCreated == 0)
        #expect(report.duplicates == [stem])
        #expect(try await library.listMeetings().map(\.id) == [existing.id])
    }

    @Test("merges profiles by normalized name and prototype id")
    func mergesExistingPerson() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        _ = try makeLegacyInstallation(at: source)
        let library = try Library.open(at: root.appending(path: "Library"))
        let store = try IdentityStore(layout: library.layout)
        let existingID = PersonID()
        let duplicateEvidenceID = SpeakerEvidenceID(
            rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )
        try await store.replacePersons([
            Person(
                id: existingID,
                displayName: "ADA",
                prototypes: [SpeakerPrototype(
                    id: duplicateEvidenceID,
                    personID: existingID,
                    embedding: Array(repeating: 0, count: 256),
                    recordingType: .remote,
                    channel: nil,
                    meetingID: nil,
                    runID: nil,
                    clusterID: "old",
                    speechDurationSeconds: 1,
                    segmentCount: 1,
                    source: .userConfirmed
                )]
            ),
        ])

        let report = try await LegacyImporter(
            sourceRoot: source,
            library: library,
            folders: try FolderStore.open(layout: library.layout),
            timestampParser: berlin
        ).performImport()

        let people = try await store.listPersons()
        #expect(report.personsCreated == 0)
        #expect(report.prototypesCreated == 2)
        #expect(people.count == 1)
        #expect(people[0].id == existingID)
        #expect(Set(people[0].prototypes.map(\.id)).count == 2)
        #expect(people[0].hardNegatives.count == 1)
    }

    @Test("preserves and reports an unmarked legacy staging directory")
    func preservesUnmarkedInterruptedStem() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
        _ = try makeLegacyInstallation(at: source)
        let library = try Library.open(at: root.appending(path: "Library"))
        let stale = library.layout.meetingsDirectory
            .appending(
                path: ".meeting-import-\(UUID().uuidString).tmp",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stale.appending(path: "meeting.json"))

        do {
            _ = try await LegacyImporter(
                sourceRoot: source,
                library: library,
                folders: try FolderStore.open(layout: library.layout),
                timestampParser: berlin
            ).performImport()
            Issue.record("expected an unsafe abandoned import report")
        } catch let error as LibraryError {
            guard case .abandonedMeetingImportsRequireAttention(let paths) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(
                paths.map { $0.resolvingSymlinksInPath() }
                    == [stale.resolvingSymlinksInPath()]
            )
        }
        #expect(FileManager.default.fileExists(atPath: stale.path))
        #expect(try Data(contentsOf: stale.appending(path: "meeting.json")) == Data("partial".utf8))
        #expect(try await library.listMeetings().isEmpty)
    }

    @Test("legacy origin and optional meeting metadata remain Codable-compatible")
    func domainCompatibility() throws {
        let origin = try JSONDecoder().decode(
            TranscriptOrigin.self,
            from: JSONEncoder().encode(TranscriptOrigin.legacyImport)
        )
        #expect(origin == .legacyImport)

        let oldMeeting = Meeting(title: "Alt", status: .ready)
        let oldData = try JSONEncoder().encode(oldMeeting)
        let decodedOld = try JSONDecoder().decode(Meeting.self, from: oldData)
        #expect(decodedOld.metadata == nil)

        let newMeeting = Meeting(
            title: "Import",
            status: .ready,
            metadata: MeetingMetadata(
                legacyProvenanceKey: "legacy:test",
                legacyFolders: ["Arbeit"]
            )
        )
        #expect(try JSONDecoder().decode(
            Meeting.self,
            from: JSONEncoder().encode(newMeeting)
        ) == newMeeting)

        let oldAsset = MediaAsset(
            meetingID: oldMeeting.id,
            kind: .imported,
            sampleRate: 48_000,
            duration: 1,
            provenanceKey: "legacy:old-audio",
            fileName: "old.wav"
        )
        var oldAssetObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(oldAsset)
            ) as? [String: Any]
        )
        oldAssetObject.removeValue(forKey: "conversion")
        let decodedOldAsset = try JSONDecoder().decode(
            MediaAsset.self,
            from: JSONSerialization.data(withJSONObject: oldAssetObject)
        )
        #expect(decodedOldAsset.conversion == nil)
    }
}

private func makeLegacyInstallation(at root: URL) throws -> URL {
    let stem = "sysaudio-1785933296000-Planung"
    let audio = root.appending(path: "recordings/\(stem).wav")
    try writeSyntheticReadableAudio(to: audio)
    try writeFixture(
        "import_diarized_transcript",
        extension: "txt",
        to: root.appending(path: "transcripts/\(stem)_transcript.txt")
    )
    try writeFixture(
        "import_summary",
        extension: "md",
        to: root.appending(path: "output/\(stem)_summary.md")
    )
    try writeFixture(
        "legacy_speakers",
        extension: "json",
        to: root.appending(path: "output/\(stem)_speakers.json")
    )
    try writeFixture(
        "legacy_reports",
        extension: "json",
        to: root.appending(path: "output/\(stem)_reports.json")
    )
    try writeFixture(
        "legacy_overrides",
        extension: "json",
        to: root.appending(path: "output/\(stem)_overrides.json")
    )
    try writeFixture(
        "plain_transcript",
        extension: "txt",
        to: root.appending(path: "transcripts/Ohne Audio_transcript.txt")
    )
    try writeFixture(
        "import_missing_audio_summary",
        extension: "md",
        to: root.appending(path: "output/Ohne Audio_summary.md")
    )
    try writeFixture(
        "store_orphan_audio",
        extension: "webm",
        to: root.appending(path: "recordings/orphan.webm")
    )
    try writeFixture("legacy_folders", extension: "json", to: root.appending(path: "folders.json"))
    try writeFixture("import_config", extension: "json", to: root.appending(path: "config.json"))
    try writeFixture(
        "store_unicode_summary",
        extension: "md",
        to: root.appending(path: "output/.pending-delete/stale_summary.md")
    )
    return audio
}

private func makeLegacyTextInstallation(at root: URL, stem: String) throws {
    try writeFixture(
        "plain_transcript",
        extension: "txt",
        to: root.appending(path: "transcripts/\(stem)_transcript.txt")
    )
    try writeFixture(
        "import_missing_audio_summary",
        extension: "md",
        to: root.appending(path: "output/\(stem)_summary.md")
    )
}

private func makeLegacyAudioInstallation(
    at root: URL,
    stem: String,
    audio: Data
) throws -> URL {
    let audioURL = root.appending(path: "recordings/\(stem).webm")
    try FileManager.default.createDirectory(
        at: audioURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try audio.write(to: audioURL)
    try writeFixture(
        "plain_transcript",
        extension: "txt",
        to: root.appending(path: "transcripts/\(stem)_transcript.txt")
    )
    try writeFixture(
        "import_missing_audio_summary",
        extension: "md",
        to: root.appending(path: "output/\(stem)_summary.md")
    )
    return audioURL
}

private func writeSyntheticReadableAudio(to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let sampleRate = 48_000.0
    let frameCount: AVAudioFrameCount = 960
    let format = try #require(AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 1
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    buffer.floatChannelData?[0].update(
        repeating: 0,
        count: Int(frameCount)
    )

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private struct LegacyRepairScenario {
    let source: URL
    let library: Library
    let meetingID: MeetingID
    let assetID: MediaAssetID
    let oldMediaURL: URL
}

private func makeLegacyRepairScenario(
    root: URL,
    stem: String
) async throws -> LegacyRepairScenario {
    let source = root.appending(path: "Legacy", directoryHint: .isDirectory)
    _ = try makeLegacyAudioInstallation(
        at: source,
        stem: stem,
        audio: makeSyntheticImportWebM()
    )
    let staleSource = root.appending(path: "stale.webm")
    try Data("unreadable legacy WebM".utf8).write(to: staleSource)
    let library = try Library.open(at: root.appending(path: "Library"))
    let meeting = Meeting(
        title: stem,
        status: .ready,
        metadata: MeetingMetadata(
            legacyProvenanceKey: "legacy:\(stem)",
            legacyFolders: []
        )
    )
    let assetID = MediaAssetID()
    let oldFileName = "\(assetID).webm"
    let asset = MediaAsset(
        id: assetID,
        meetingID: meeting.id,
        kind: .imported,
        sampleRate: 0,
        duration: 1,
        provenanceKey: "legacy:\(stem)",
        fileName: oldFileName
    )
    try await library.commitPreparedMeeting(PreparedMeetingImport(
        meeting: meeting,
        media: [PreparedMediaImport(asset: asset, sourceURL: staleSource)],
        revision: TranscriptRevision(
            meetingID: meeting.id,
            origin: .legacyImport,
            turns: []
        )
    ))
    return LegacyRepairScenario(
        source: source,
        library: library,
        meetingID: meeting.id,
        assetID: assetID,
        oldMediaURL: library.layout.mediaFile(meeting.id, fileName: oldFileName)
    )
}

private func legacyDiarizationRun(
    in layout: LibraryLayout,
    meetingID: MeetingID
) throws -> ProcessingRun? {
    let directories = try FileManager.default.contentsOfDirectory(
        at: layout.runsDirectory(meetingID),
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    let runs: [ProcessingRun] = try directories.compactMap { directory -> ProcessingRun? in
        let url = directory.appending(path: "run.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let run = try JSONDecoder().decode(ProcessingRun.self, from: Data(contentsOf: url))
        return run.kind == .diarization ? run : nil
    }
    return runs.first
}

private func storedTemplateResults(
    in layout: LibraryLayout,
    meetingID: MeetingID
) throws -> [TemplateResult] {
    try FileManager.default.contentsOfDirectory(
        at: layout.reportsDirectory(meetingID),
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }.map {
        try JSONDecoder().decode(TemplateResult.self, from: Data(contentsOf: $0))
    }
}
