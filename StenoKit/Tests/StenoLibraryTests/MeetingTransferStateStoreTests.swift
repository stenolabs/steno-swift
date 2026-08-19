import Foundation
import StenoDomain
import Synchronization
import Testing
@testable import StenoLibrary

@Suite("Meeting transfer state store")
struct MeetingTransferStateStoreTests {
    @Test("persists schema-v1 state atomically and lists meeting states")
    func savesLoadsAndListsState() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let first = try await importTransferMeeting(
                into: library,
                title: "First",
                state: .importedOnly
            )
            let second = try await importTransferMeeting(
                into: library,
                title: "Second",
                state: .importedOnly
            )
            let store = MeetingTransferStateStore(layout: library.layout)

            try await store.save(.importedOnly, for: first.id)
            try await store.save(
                .awaitingModel(localeIdentifier: "de-DE"),
                for: second.id
            )

            #expect(try await store.load(first.id) == .importedOnly)
            #expect(
                try await store.load(second.id)
                    == .awaitingModel(localeIdentifier: "de-DE")
            )
            let listed = try await store.list()
            #expect(listed.count == 2)
            #expect(listed.first(where: { $0.0 == first.id })?.1 == .importedOnly)
            #expect(
                listed.first(where: { $0.0 == second.id })?.1
                    == .awaitingModel(localeIdentifier: "de-DE")
            )

            let documentURL = library.layout.transferState(first.id)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: documentURL))
                    as? [String: Any]
            )
            #expect(object["schemaVersion"] as? Int == 1)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: documentURL.deletingLastPathComponent(),
                    includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.contains(".tmp-") }.isEmpty
            )
        }
    }

    @Test("returns nil when a meeting has no transfer state")
    func missingStateIsNil() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await library.createMeeting(title: "Native", status: .ready)
            let store = MeetingTransferStateStore(layout: library.layout)

            #expect(try await store.load(meeting.id) == nil)
            #expect(try await store.list().isEmpty)
        }
    }

    @Test("rejects an unknown state schema without rewriting it")
    func rejectsUnknownSchema() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await importTransferMeeting(
                into: library,
                title: "Imported",
                state: .importedOnly
            )
            let store = MeetingTransferStateStore(layout: library.layout)
            let stateURL = library.layout.transferState(meeting.id)
            let original = Data(#"{"schemaVersion":2,"state":{"importedOnly":{}}}"#.utf8)
            try original.write(to: stateURL)

            do {
                _ = try await store.load(meeting.id)
                Issue.record("expected unsupported schema version")
            } catch let error as LibraryError {
                guard case .unsupportedSchemaVersion(let document, let found, let supported) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
                #expect(document == stateURL)
                #expect(found == 2)
                #expect(supported == 1)
            }
            #expect(try Data(contentsOf: stateURL) == original)
        }
    }

    @Test("refuses to create state for a missing meeting")
    func refusesOrphanState() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let store = MeetingTransferStateStore(layout: library.layout)
            let missingID = MeetingID()

            await #expect(throws: LibraryError.self) {
                try await store.save(.importedOnly, for: missingID)
            }
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.transferState(missingID).path
            ))
        }
    }

    @Test("refuses transfer state for a native meeting without mutating it")
    func refusesStateForNativeMeeting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await library.createMeeting(title: "Native", status: .ready)
            let store = MeetingTransferStateStore(layout: library.layout)

            await #expect(throws: LibraryError.self) {
                try await store.save(.importedOnly, for: meeting.id)
            }
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.transferState(meeting.id).path
            ))
        }
    }

    @Test("load refuses an existing state document for a native meeting")
    func loadRefusesStateForNativeMeeting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await library.createMeeting(title: "Native", status: .ready)
            let stateURL = library.layout.transferState(meeting.id)
            try MeetingTransferStateStore.write(
                .importedOnly,
                meetingID: meeting.id,
                receipt: makeReceipt(meetingID: meeting.id),
                to: stateURL
            )
            let original = try Data(contentsOf: stateURL)

            await #expect(throws: LibraryError.self) {
                _ = try await MeetingTransferStateStore(layout: library.layout).load(meeting.id)
            }
            #expect(try Data(contentsOf: stateURL) == original)
        }
    }

    @Test("load rejects state for another meeting without rewriting it")
    func loadRejectsMismatchedMeeting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await importTransferMeeting(
                into: library,
                title: "Imported",
                state: .importedOnly
            )
            let stateURL = library.layout.transferState(meeting.id)
            let request = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: MeetingID(),
                localeIdentifier: "de-DE",
                createdAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
            try MeetingTransferStateStore.write(
                .processingRequested(request),
                meetingID: request.meetingID,
                receipt: makeReceipt(meetingID: request.meetingID),
                to: stateURL
            )
            let original = try Data(contentsOf: stateURL)

            await #expect(throws: LibraryError.self) {
                _ = try await MeetingTransferStateStore(layout: library.layout).load(meeting.id)
            }
            #expect(try Data(contentsOf: stateURL) == original)
        }
    }

    @Test("save rejects mismatched requests and semantic invalid states atomically")
    func saveRejectsInvalidStateWithoutMutation() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await importTransferMeeting(
                into: library,
                title: "Imported",
                state: .importedOnly
            )
            let store = MeetingTransferStateStore(layout: library.layout)
            let stateURL = library.layout.transferState(meeting.id)
            let original = try Data(contentsOf: stateURL)
            let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let invalidStates: [ImportedMeetingProcessingState] = [
                .processingRequested(ImportedProcessingRequest(
                    id: MeetingTransferRequestID(),
                    jobID: JobID(),
                    meetingID: MeetingID(),
                    localeIdentifier: "de-DE",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                )),
                .processingRequested(ImportedProcessingRequest(
                    id: MeetingTransferRequestID(rawValue: zero),
                    jobID: JobID(),
                    meetingID: meeting.id,
                    localeIdentifier: "de-DE",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                )),
                .jobEnqueued(
                    jobID: JobID(rawValue: zero),
                    localeIdentifier: "de-DE"
                ),
                .awaitingModel(localeIdentifier: "  "),
                .needsManualRetry(
                    jobID: JobID(),
                    localeIdentifier: "de-DE",
                    reason: "\n"
                ),
            ]

            for invalidState in invalidStates {
                await #expect(throws: LibraryError.self) {
                    try await store.save(invalidState, for: meeting.id)
                }
                #expect(try Data(contentsOf: stateURL) == original)
            }
        }
    }

    @Test("independent state stores compare and set one transition under filesystem lock")
    func compareAndSetSerializesIndependentStores() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await importTransferMeeting(
                into: library,
                title: "Imported",
                state: .importedOnly
            )
            let firstStore = MeetingTransferStateStore(layout: library.layout)
            let secondStore = MeetingTransferStateStore(layout: library.layout)
            let firstRequest = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: meeting.id,
                localeIdentifier: "de-DE",
                createdAt: Date(timeIntervalSinceReferenceDate: 10)
            )
            let secondRequest = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: meeting.id,
                localeIdentifier: "de-DE",
                createdAt: Date(timeIntervalSinceReferenceDate: 11)
            )

            async let first = firstStore.compareAndSet(
                expected: .importedOnly,
                newState: .processingRequested(firstRequest),
                for: meeting.id
            )
            async let second = secondStore.compareAndSet(
                expected: .importedOnly,
                newState: .processingRequested(secondRequest),
                for: meeting.id
            )
            let results = try await [first, second]

            #expect(results.filter { $0 == .updated }.count == 1)
            #expect(results.filter {
                if case .stateMismatch = $0 { return true }
                return false
            }.count == 1)
            let final = try await firstStore.load(meeting.id)
            #expect(final == .processingRequested(firstRequest)
                || final == .processingRequested(secondRequest))
        }
    }

    @Test("state transition holds the stable root namespace against trash and reimport")
    func stateTransitionCoordinatesMeetingNamespaceReplacement() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meeting = try await importTransferMeeting(
                into: library,
                title: "First generation",
                state: .importedOnly
            )
            let replacingLibrary = try Library.open(at: library.layout.root)
            let pause = StateStorePause()
            let store = MeetingTransferStateStore(
                layout: library.layout,
                checkpoint: { checkpoint in
                    guard checkpoint == .afterNamespaceLockBeforeBody else { return }
                    pause.arriveAndWait()
                }
            )
            let request = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: meeting.id,
                localeIdentifier: "de-DE",
                createdAt: Date(timeIntervalSinceReferenceDate: 20)
            )
            let transition = Task {
                try await store.compareAndSet(
                    expected: .importedOnly,
                    newState: .processingRequested(request),
                    for: meeting.id
                )
            }
            try await eventuallyStateStore { pause.hasArrived }

            let replacementFinished = Mutex(false)
            let replacement = Task {
                _ = try await replacingLibrary.trashMeeting(meeting.id)
                let replacementMeeting = Meeting(
                    id: meeting.id,
                    title: "Second generation",
                    status: .ready,
                    metadata: MeetingMetadata(
                        transferReceipt: makeReceipt(meetingID: meeting.id)
                    )
                )
                _ = try await replacingLibrary.commitPreparedMeeting(PreparedMeetingImport(
                    meeting: replacementMeeting,
                    media: [],
                    revision: nil,
                    transferState: .awaitingLanguageConfirmation
                ))
                replacementFinished.withLock { $0 = true }
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(!replacementFinished.withLock { $0 })

            pause.release()
            #expect(try await transition.value == .updated)
            try await replacement.value

            let secondStore = MeetingTransferStateStore(layout: library.layout)
            #expect(try await secondStore.load(meeting.id) == .awaitingLanguageConfirmation)
            #expect(try await library.loadMeeting(meeting.id).title == "Second generation")
        }
    }

    @Test("fresh retry token cannot resolve a replacement generation with identical content")
    func freshRetryTokenRejectsGenerationABA() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetingID = MeetingID()
            let digest = String(repeating: "a", count: 64)
            let firstGeneration = MeetingTransferGenerationID()
            let firstRequest = generatedRequest(
                meetingID: meetingID,
                generationID: firstGeneration
            )
            _ = try await library.commitPreparedMeeting(generatedTransfer(
                meetingID: meetingID,
                digest: digest,
                generationID: firstGeneration,
                state: .processingRequested(firstRequest)
            ))
            let store = MeetingTransferStateStore(layout: library.layout)
            let staleToken = try #require(
                try await store.freshImportRetryToken(meetingID)
            )

            _ = try await library.trashMeeting(meetingID)
            let secondGeneration = MeetingTransferGenerationID()
            let secondRequest = generatedRequest(
                meetingID: meetingID,
                generationID: secondGeneration
            )
            _ = try await library.commitPreparedMeeting(generatedTransfer(
                meetingID: meetingID,
                digest: digest,
                generationID: secondGeneration,
                state: .processingRequested(secondRequest)
            ))

            do {
                _ = try await store.resolveFreshImportRetry(
                    .importedOnly,
                    for: meetingID,
                    expected: staleToken
                )
                Issue.record("expected replacement generation conflict")
            } catch let error as LibraryError {
                guard case .transferImportGenerationConflict(let conflictingID) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
                #expect(conflictingID == meetingID)
            }

            #expect(try await store.load(meetingID) == .processingRequested(secondRequest))
            #expect(try await store.requiresFreshImportRetry(meetingID))
            #expect(try await library.loadMeeting(meetingID).metadata?
                .transferReceipt?.importGenerationID == secondGeneration)
        }
    }
}

private final class StateStorePause: @unchecked Sendable {
    private let arrived = Mutex(false)
    private let resume = DispatchSemaphore(value: 0)

    var hasArrived: Bool { arrived.withLock { $0 } }

    func arriveAndWait() {
        arrived.withLock { $0 = true }
        resume.wait()
    }

    func release() {
        resume.signal()
    }
}

private func eventuallyStateStore(
    _ predicate: @escaping @Sendable () async throws -> Bool
) async throws {
    for _ in 0..<200 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition did not become true")
}

private func importTransferMeeting(
    into library: Library,
    title: String,
    state: ImportedMeetingProcessingState
) async throws -> Meeting {
    let meetingID = MeetingID()
    let receipt = makeReceipt(meetingID: meetingID)
    let meeting = Meeting(
        id: meetingID,
        title: title,
        status: .ready,
        metadata: MeetingMetadata(transferReceipt: receipt)
    )
    _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
        meeting: meeting,
        media: [],
        revision: nil,
        transferState: state
    ))
    return meeting
}

private func makeReceipt(meetingID: MeetingID) -> MeetingTransferReceipt {
    MeetingTransferReceipt(
        sourceMeetingID: meetingID,
        sourceRevisionID: nil,
        sourcePackageContentDigest: "state-\(meetingID)",
        importedAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceAppVersion: "1.0",
        includedCapabilities: [.audio],
        sourceLocaleIdentifier: "de-DE",
        sourceLocaleOrigin: .explicit
    )
}

private func generatedRequest(
    meetingID: MeetingID,
    generationID: MeetingTransferGenerationID
) -> ImportedProcessingRequest {
    ImportedProcessingRequest(
        id: MeetingTransferRequestID(),
        jobID: JobID(),
        meetingID: meetingID,
        localeIdentifier: "de-DE",
        createdAt: Date(timeIntervalSinceReferenceDate: 100),
        importGenerationID: generationID
    )
}

private func generatedTransfer(
    meetingID: MeetingID,
    digest: String,
    generationID: MeetingTransferGenerationID,
    state: ImportedMeetingProcessingState
) -> PreparedMeetingImport {
    let receipt = MeetingTransferReceipt(
        sourceMeetingID: meetingID,
        sourceRevisionID: nil,
        sourcePackageContentDigest: digest,
        importedAt: Date(timeIntervalSinceReferenceDate: 101),
        sourceAppVersion: nil,
        includedCapabilities: [.audio],
        sourceLocaleIdentifier: "de-DE",
        sourceLocaleOrigin: .explicit,
        importGenerationID: generationID
    )
    return PreparedMeetingImport(
        meeting: Meeting(
            id: meetingID,
            title: "Generation \(generationID)",
            status: .ready,
            metadata: MeetingMetadata(transferReceipt: receipt)
        ),
        media: [],
        revision: nil,
        transferState: state
    )
}
