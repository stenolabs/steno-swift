import Foundation
import Testing
import StenoDomain
@testable import StenoLibrary

@Suite("Library CRUD")
struct LibraryCRUDTests {
    @Test("meeting status changes are emitted after persistence")
    func emitsMeetingStatusChanges() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Status",
                status: .processing
            )
            let changes = await library.meetingChanges()
            var iterator = changes.makeAsyncIterator()

            _ = try await library.updateMeetingStatus(meeting.id, to: .ready)

            let changedMeetingID = await iterator.next()
            #expect(changedMeetingID == meeting.id)
            #expect(try await library.loadMeeting(meeting.id).status == .ready)
        }
    }

    @Test("writing the same meeting status emits no duplicate event")
    func skipsDuplicateMeetingStatusChanges() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Status",
                status: .ready
            )
            let changes = await library.meetingChanges()
            let recorder = MeetingChangeRecorder()
            let consumer = Task {
                for await meetingID in changes {
                    await recorder.append(meetingID)
                }
            }

            _ = try await library.updateMeetingStatus(meeting.id, to: .ready)
            try await Task.sleep(for: .milliseconds(50))
            consumer.cancel()

            #expect(await recorder.values().isEmpty)
        }
    }

    @Test("open creates the versioned library and meeting documents")
    func createAndListMeetings() async throws {
        try await withTemporaryDirectory { directory in
            let root = directory.appendingPathComponent("Library", isDirectory: true)
            let library = try Library.open(at: root)
            let first = try await library.createMeeting(
                title: "Früh",
                status: .ready,
                createdAt: Date(timeIntervalSince1970: 100)
            )
            let second = try await library.createMeeting(
                title: "Spät",
                status: .recording,
                createdAt: Date(timeIntervalSince1970: 200)
            )

            let metadata = try JSONDecoder().decode(
                LibraryMetadata.self,
                from: Data(contentsOf: root.appendingPathComponent("library.json"))
            )
            let meetings = try await library.listMeetings()

            #expect(metadata.schemaVersion == 1)
            #expect(try await library.loadMeeting(first.id) == first)
            #expect(meetings.map(\.id) == [second.id, first.id])
        }
    }

    @Test("meeting creation persists an explicit source locale")
    func createMeetingPersistsSourceLocale() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let sourceLocale = try MeetingSourceLocale(
                localeIdentifier: "de-DE",
                origin: .explicit
            )

            let meeting = try await library.createMeeting(
                title: "iPad-Aufnahme",
                status: .recording,
                sourceLocale: sourceLocale
            )

            #expect(try await library.loadMeeting(meeting.id).sourceLocale == sourceLocale)
        }
    }

    @Test("open clearly rejects an unknown library schema version")
    func rejectUnknownSchema() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try Data(
                """
                {"schemaVersion":99,"futureFormat":{"isNotDecodableAsVersionOne":true}}
                """.utf8
            ).write(to: root.appendingPathComponent("library.json"))

            do {
                _ = try Library.open(at: root)
                Issue.record("Expected unsupportedSchemaVersion")
            } catch let error as LibraryError {
                guard case .unsupportedSchemaVersion(let document, let found, let supported) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(document.lastPathComponent == "library.json")
                #expect(found == 99)
                #expect(supported == 1)
            }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        }
    }

    @Test("import copies bytes and rejects matching SHA-256 provenance globally")
    func importAndRejectDuplicate() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source.m4a")
            let audio = Data("same audio bytes".utf8)
            try audio.write(to: source)
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let firstMeeting = try await library.createMeeting(title: "First", status: .ready)
            let secondMeeting = try await library.createMeeting(title: "Second", status: .ready)

            let asset = try await library.registerMediaAsset(
                for: firstMeeting.id,
                sourceURL: source,
                kind: .imported,
                sampleRate: 44_100,
                duration: 3.5
            )
            let copiedURL = library.layout.mediaFile(
                firstMeeting.id,
                fileName: asset.fileName
            )

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try Data(contentsOf: copiedURL) == audio)
            #expect(asset.provenanceKey == "aafe9f6cb200b33109672a43c8ea1e40835484abeb0520632cdc9362ce1f58a1")
            #expect(try await library.loadMediaAsset(asset.id, meetingID: firstMeeting.id) == asset)

            do {
                _ = try await library.registerMediaAsset(
                    for: secondMeeting.id,
                    sourceURL: source,
                    kind: .imported,
                    sampleRate: 44_100,
                    duration: 3.5
                )
                Issue.record("Expected duplicateProvenance")
            } catch let error as LibraryError {
                guard case .duplicateProvenance(_, let existingMeetingID) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(existingMeetingID == firstMeeting.id)
            }
        }
    }

    @Test("recording tracks use meeting and track kind as provenance")
    func recordingProvenance() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("track.caf")
            try Data("caf bytes".utf8).write(to: source)
            let library = try Library.open(at: root.appendingPathComponent("Library"))
            let meeting = try await library.createMeeting(title: "Recording", status: .recording)

            let asset = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 10
            )

            #expect(asset.provenanceKey == "\(meeting.id)/micTrack")
            #expect(asset.fileName.hasSuffix(".caf"))
        }
    }
}

private actor MeetingChangeRecorder {
    private var meetingIDs: [MeetingID] = []

    func append(_ meetingID: MeetingID) {
        meetingIDs.append(meetingID)
    }

    func values() -> [MeetingID] {
        meetingIDs
    }
}
