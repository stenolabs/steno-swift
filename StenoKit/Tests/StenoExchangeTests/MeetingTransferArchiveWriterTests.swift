import Darwin
import Foundation
import StenoDomain
import Synchronization
import Testing
@testable import StenoExchange

@Suite("Meeting transfer archive writer")
struct MeetingTransferArchiveWriterTests {
    @Test("writer produces one regular uncompressed archive and validates it")
    func writerRoundTripsTextPackage() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let exportRoot = makeTransferTestRoot(under: base, name: "export")
        let validationRoot = makeTransferTestRoot(under: base, name: "validation")
        let content = try makeTransferTextContent()

        let url = try await MeetingTransferArchiveWriter().write(content, to: exportRoot)
        let validated = try await MeetingTransferArchiveReader().validate(
            at: url,
            validationRoot: validationRoot
        )
        defer { try? validated.close() }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        #expect(values.isRegularFile == true)
        #expect(values.isDirectory == false)
        #expect(try Data(contentsOf: url).prefix(4) == Data("AA01".utf8))
        #expect(validated.manifest.capabilities == [.notes, .transcript])
        #expect(validated.notes == "Plan\n[00:12:34] Beschluss")
        #expect(validated.entryPaths == [
            "manifest.json", "meeting.json", "notes.md", "transcript.json",
        ])
        let independentDigest = try await MeetingTransferDigest.sha256(of: url)
        #expect(validated.transportDigest == independentDigest)
    }

    @Test("writer preserves source revision and app version metadata")
    func writerPreservesExportMetadata() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let revisionID = RevisionID(
            rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000032")!
        )

        let url = try await MeetingTransferArchiveWriter().write(
            makeTransferTextContent(),
            sourceRevisionID: revisionID,
            sourceAppVersion: "Steno/Test-4",
            to: makeTransferTestRoot(under: base, name: "export")
        )
        let validated = try await MeetingTransferArchiveReader().validate(
            at: url,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
        defer { try? validated.close() }

        #expect(validated.manifest.sourceRevisionID == revisionID)
        #expect(validated.manifest.sourceAppVersion == "Steno/Test-4")
    }

    @Test("writer round-trips two bound audio sources without persisting local URLs")
    func writerRoundTripsTwoAudioTracks() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstURL = base.appendingPathComponent("private-microphone-name.caf")
        let secondURL = base.appendingPathComponent("private-system-name.caf")
        try makeTransferCAF(at: firstURL, channelCount: 1, frameCount: 80)
        try makeTransferCAF(at: secondURL, channelCount: 2, frameCount: 160)
        let first = try await makeTransferAudioDocument(
            logicalTrackID: "mic",
            kind: .micTrack,
            sourceURL: firstURL
        )
        let second = try await makeTransferAudioDocument(
            logicalTrackID: "system",
            kind: .systemTrack,
            sourceURL: secondURL,
            channelCount: 2,
            duration: 0.02
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [first, second]
        )
        let exportRoot = makeTransferTestRoot(under: base, name: "export")
        let url = try await MeetingTransferArchiveWriter().write(
            content,
            audioSources: [
                .init(logicalTrackID: "mic", sourceURL: firstURL),
                .init(logicalTrackID: "system", sourceURL: secondURL),
            ],
            to: exportRoot
        )
        let validated = try await MeetingTransferArchiveReader().validate(
            at: url,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
        defer { try? validated.close() }

        #expect(validated.audio.map { $0.logicalTrackID } == ["mic", "system"])
        #expect(validated.audio.map { $0.kind } == [.micTrack, .systemTrack])
        #expect(validated.audio.map { $0.channelCount } == [1, 2])
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data(firstURL.lastPathComponent.utf8)) == nil)
        #expect(bytes.range(of: Data(secondURL.lastPathComponent.utf8)) == nil)
        #expect(bytes.range(of: Data(firstURL.path.utf8)) == nil)
    }

    @Test("writer rejects a readable non-CAF audio source")
    func writerRejectsReadableNonCAFSource() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.wav")
        try makeTransferCAF(at: source)
        #expect(try Data(contentsOf: source).prefix(4) == Data("RIFF".utf8))
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "not-caf",
            kind: .micTrack,
            sourceURL: source
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [document]
        )

        await #expect(throws: MeetingTransferArchiveWriterError.self) {
            try await MeetingTransferArchiveWriter().write(
                content,
                audioSources: [.init(logicalTrackID: "not-caf", sourceURL: source)],
                to: makeTransferTestRoot(under: base, name: "export")
            )
        }
    }

    @Test("writer rejects a FIFO source without waiting for a writer")
    func writerRejectsFIFOSourcePromptly() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.caf")
        try makeTransferCAF(at: source)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "fifo",
            kind: .micTrack,
            sourceURL: source
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [document]
        )
        try FileManager.default.removeItem(at: source)
        guard mkfifo(source.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let writerOpened = Mutex(false)
        let delayedUnblocker = Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let descriptor = open(source.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            writerOpened.withLock { $0 = true }
            _ = Darwin.close(descriptor)
        }
        let exportRoot = makeTransferTestRoot(under: base, name: "fifo-export")
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: MeetingTransferArchiveWriterError.sourceNotRegularFile("fifo")) {
            try await MeetingTransferArchiveWriter().write(
                content,
                audioSources: [.init(logicalTrackID: "fifo", sourceURL: source)],
                to: exportRoot
            )
        }
        let elapsed = started.duration(to: clock.now)
        delayedUnblocker.cancel()
        await delayedUnblocker.value

        #expect(elapsed < .milliseconds(250))
        #expect(!writerOpened.withLock { $0 })
        #expect(try transferDirectoryContents(exportRoot).isEmpty)
    }

    @Test("writer emits only TYP PAT SIZ and DAT with exact field types")
    func writerUsesClosedHeaderAllowlist() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try await MeetingTransferArchiveWriter().write(
            makeTransferTextContent(),
            to: makeTransferTestRoot(under: base, name: "export")
        )

        let headers = try readTransferArchiveHeaders(at: url)
        #expect(!headers.isEmpty)
        for fields in headers {
            #expect(fields.map { $0.0 } == ["TYP", "PAT", "SIZ", "DAT"])
            #expect(fields.map { $0.1 } == ["uint", "string", "uint", "blob"])
        }
    }

    @Test("writer rejects missing extra and duplicate ephemeral audio bindings", arguments: [
        BindingCase.missing,
        .extra,
        .duplicate,
    ])
    func writerRejectsInvalidAudioBindings(testCase: BindingCase) async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let audioURL = base.appendingPathComponent("audio.caf")
        try makeTransferCAF(at: audioURL)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "selected",
            kind: .micTrack,
            sourceURL: audioURL
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [document]
        )

        do {
            _ = try await MeetingTransferArchiveWriter().write(
                content,
                audioSources: testCase.bindings(sourceURL: audioURL),
                to: makeTransferTestRoot(under: base, name: "export")
            )
            Issue.record("Writer accepted \(testCase)")
        } catch let error as MeetingTransferArchiveWriterError {
            #expect(error == testCase.expectedError)
        }
    }

    @Test("writer never replaces an existing final target and removes only its staging file")
    func writerUsesNoReplaceRenameAndScopedCleanup() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let exportRootURL = makeTransferTestRoot(under: base, name: "export")
        let root = try MeetingTransferPrivateRoot.prepareAndVerify(at: exportRootURL)
        let finalURL = exportRootURL.appendingPathComponent(
            "Meeting-\(transferTestMeetingID).stenomeeting"
        )
        let existing = Data("existing-target".utf8)
        try existing.write(to: finalURL)
        let unrelated = exportRootURL.appendingPathComponent(".stenomeeting-staging-not-owned")
        try Data("unrelated".utf8).write(to: unrelated)
        _ = root

        await #expect(throws: MeetingTransferArchiveWriterError.destinationAlreadyExists) {
            try await MeetingTransferArchiveWriter().write(
                makeTransferTextContent(),
                to: exportRootURL
            )
        }
        #expect(try Data(contentsOf: finalURL) == existing)
        #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
        let names = try transferDirectoryContents(exportRootURL)
        #expect(names == [
            ".stenomeeting-staging-not-owned",
            "Meeting-\(transferTestMeetingID).stenomeeting",
        ])
    }

    @Test("writer never publishes or removes a name-swapped staging replacement")
    func writerRejectsStagingNameSwap() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let exportRoot = makeTransferTestRoot(under: base, name: "export")
        let didSwap = Mutex(false)
        let swapFailure = Mutex<String?>(nil)
        let savedStaging = exportRoot.appendingPathComponent("saved-owned-staging")
        let replacementBytes = Data("must-survive".utf8)

        await #expect(throws: MeetingTransferArchiveWriterError.stagingIdentityMismatch) {
            try await MeetingTransferArchiveWriter().write(
                makeTransferTextContent(),
                to: exportRoot,
                progress: { progress in
                    guard progress.phase == .writing else { return }
                    do {
                        try didSwap.withLock { swapped in
                            guard !swapped else { return }
                            let stagingName = try #require(
                                transferDirectoryContents(exportRoot).first {
                                    $0.hasPrefix(".stenomeeting-staging-")
                                }
                            )
                            let staging = exportRoot.appendingPathComponent(stagingName)
                            try FileManager.default.moveItem(at: staging, to: savedStaging)
                            try replacementBytes.write(to: staging)
                            guard chmod(staging.path, S_IRUSR | S_IWUSR) == 0 else {
                                throw POSIXError(.init(rawValue: errno) ?? .EIO)
                            }
                            swapped = true
                        }
                    } catch {
                        swapFailure.withLock { $0 = String(describing: error) }
                    }
                }
            )
        }

        #expect(swapFailure.withLock { $0 } == nil)
        #expect(didSwap.withLock { $0 })
        let replacement = try #require(
            try transferDirectoryContents(exportRoot).first {
                $0.hasPrefix(".stenomeeting-staging-")
            }
        )
        #expect(
            try Data(contentsOf: exportRoot.appendingPathComponent(replacement))
                == replacementBytes
        )
        #expect(FileManager.default.fileExists(atPath: savedStaging.path))
        #expect(!FileManager.default.fileExists(
            atPath: exportRoot.appendingPathComponent(
                "Meeting-\(transferTestMeetingID).stenomeeting"
            ).path
        ))
    }

    @Test("writer never publishes a staging name swapped after final verification")
    func writerRejectsSwapBetweenFinalVerificationAndPublish() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let exportRoot = makeTransferTestRoot(under: base, name: "export-publish-gap")
        let didSwap = Mutex(false)
        let swappedName = Mutex<String?>(nil)
        let savedStaging = exportRoot.appendingPathComponent("saved-verified-staging")
        let replacementBytes = Data("replacement-must-survive".utf8)
        let writer = MeetingTransferArchiveWriter(namespaceCheckpoint: { checkpoint in
            guard case let .beforeWriterPublish(currentName) = checkpoint else { return }
            try didSwap.withLock { swapped in
                guard !swapped else { return }
                let current = exportRoot.appendingPathComponent(currentName)
                try FileManager.default.moveItem(at: current, to: savedStaging)
                try replacementBytes.write(to: current)
                guard chmod(current.path, S_IRUSR | S_IWUSR) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                swappedName.withLock { $0 = currentName }
                swapped = true
            }
        })

        await #expect(throws: MeetingTransferArchiveWriterError.stagingIdentityMismatch) {
            try await writer.write(makeTransferTextContent(), to: exportRoot)
        }

        let currentName = try #require(swappedName.withLock { $0 })
        #expect(
            try Data(contentsOf: exportRoot.appendingPathComponent(currentName))
                == replacementBytes
        )
        #expect(FileManager.default.fileExists(atPath: savedStaging.path))
        #expect(!FileManager.default.fileExists(
            atPath: exportRoot.appendingPathComponent(
                "Meeting-\(transferTestMeetingID).stenomeeting"
            ).path
        ))
    }

    @Test("writer validates its owned archive without creating a second snapshot")
    func writerDoesNotCreateSecondSnapshot() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let exportRoot = makeTransferTestRoot(under: base, name: "export")

        let output = try await MeetingTransferArchiveWriter().write(
            makeTransferTextContent(),
            to: exportRoot
        )

        let names = try transferDirectoryContents(exportRoot)
        #expect(names == [output.lastPathComponent])
        #expect(!names.contains { $0.contains("snapshot") })
    }

    @Test("writer checks complete archive capacity plus reserve before staging")
    func writerRejectsInsufficientCapacityBeforeStaging() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let exportRoot = makeTransferTestRoot(under: base, name: "export")
        let content = try makeTransferTextContent()
        let checkedBytes = Mutex<Int64?>(nil)
        let writer = MeetingTransferArchiveWriter(capacityCheck: { requiredBytes in
            checkedBytes.withLock { $0 = requiredBytes }
            throw MeetingTransferArchiveWriterError.insufficientCapacity
        })

        await #expect(throws: MeetingTransferArchiveWriterError.insufficientCapacity) {
            try await writer.write(content, to: exportRoot)
        }

        let payloadLowerBound = Int64(
            try content.meeting.encodedData().count
                + (content.notes?.utf8.count ?? 0)
                + (try content.transcript?.encodedData().count ?? 0)
        )
        #expect(
            (checkedBytes.withLock { $0 } ?? 0)
                > payloadLowerBound + MeetingTransferLimits.minimumFreeSpaceReserveBytes
        )
        #expect(try transferDirectoryContents(exportRoot).isEmpty)
    }

    enum BindingCase: String, CaseIterable, CustomStringConvertible, Sendable {
        case missing
        case extra
        case duplicate

        var description: String { rawValue }

        func bindings(sourceURL: URL) -> [MeetingTransferAudioSourceBinding] {
            switch self {
            case .missing:
                []
            case .extra:
                [
                    .init(logicalTrackID: "selected", sourceURL: sourceURL),
                    .init(logicalTrackID: "unregistered", sourceURL: sourceURL),
                ]
            case .duplicate:
                [
                    .init(logicalTrackID: "selected", sourceURL: sourceURL),
                    .init(logicalTrackID: "selected", sourceURL: sourceURL),
                ]
            }
        }

        var expectedError: MeetingTransferArchiveWriterError {
            switch self {
            case .missing:
                .missingAudioSource("selected")
            case .extra:
                .extraAudioSource("unregistered")
            case .duplicate:
                .duplicateAudioSource("selected")
            }
        }
    }
}
