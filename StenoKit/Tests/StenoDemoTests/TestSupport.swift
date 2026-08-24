import CryptoKit
import Dispatch
import Foundation
import StenoDomain
@testable import StenoDemo
import Synchronization
import Testing

private let fallbackBlockingTestExecutor = DispatchQueue(
    label: "org.steno.demo-tests.blocking-executor",
    attributes: .concurrent
)

private enum BlockingTestExecutorContext {
    @TaskLocal static var current: (any TaskExecutor)?
}

func withBlockingTestExecutor<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let executor = DispatchQueue(
        label: "org.steno.demo-tests.blocking-executor.\(UUID().uuidString)",
        attributes: .concurrent
    )
    let task = Task(executorPreference: executor) {
        try await BlockingTestExecutorContext.$current.withValue(executor) {
            try await withTaskExecutorPreference(executor, operation: operation)
        }
    }
    return try await task.value
}

func blockingTestTask<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
) -> Task<Result, Error> {
    let executor = BlockingTestExecutorContext.current ?? fallbackBlockingTestExecutor
    return Task(executorPreference: executor, operation: operation)
}

func withBlockingTemporaryDirectory<Result: Sendable>(
    _ body: @escaping @Sendable (URL) async throws -> Result
) async throws -> Result {
    try await withBlockingTestExecutor {
        try await withTemporaryDirectory(body)
    }
}

final class BlockingTestPause: @unchecked Sendable {
    private let name: String
    private let timeout: DispatchTimeInterval
    private let resume = DispatchSemaphore(value: 0)

    init(name: String, timeout: DispatchTimeInterval = .seconds(10)) {
        self.name = name
        self.timeout = timeout
    }

    func arriveAndWait() {
        guard resume.wait(timeout: .now() + timeout) == .success else {
            Issue.record("Timed out waiting to release test pause '\(name)'.")
            return
        }
    }

    func release() {
        resume.signal()
    }
}

func withTemporaryDirectory<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "StenoDemoLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

func withTemporaryDemoDataset<Result>(
    _ body: (URL, DemoDatasetManifest) throws -> Result
) throws -> Result {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "StenoDemoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = makeDemoManifest()
    try writeTemporaryDemoResources(manifest, to: root)
    return try body(root, try manifestWithResourceDigests(manifest, from: root))
}

func writeTemporaryDemoResources(
    _ manifest: DemoDatasetManifest,
    to root: URL
) throws {
    for descriptor in manifest.resources {
        let destination = root.appending(path: descriptor.relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data: Data
        if descriptor.kind == .transcript {
            let meeting = manifest.meetings.first { $0.transcript.resourceID == descriptor.id }!
            data = try JSONEncoder().encode(TranscriptRevision(
                id: meeting.transcript.id,
                meetingID: meeting.id,
                createdAt: fixedUTCDate(meeting.transcript.createdAtUTC),
                origin: .demo(DemoProvenance(
                    datasetID: manifest.datasetID,
                    datasetVersion: manifest.datasetVersion,
                    itemID: meeting.itemID
                )),
                turns: []
            ))
        } else {
            data = Data("fixture \(descriptor.id)".utf8)
        }
        try data.write(to: destination)
    }
}

func withTemporaryDemoDataset<Result>(
    _ body: (URL, DemoDatasetManifest) async throws -> Result
) async throws -> Result {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "StenoDemoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = makeDemoManifest()
    try writeTemporaryDemoResources(manifest, to: root)
    return try await body(root, try manifestWithResourceDigests(manifest, from: root))
}

func writeTranscript(_ transcript: TranscriptRevision, to url: URL) throws {
    try JSONEncoder().encode(transcript).write(to: url)
}

func fixedUTCDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

enum InjectedDataReadError: Error {
    case forced
}

final class TranscriptReadSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var readCounts: [String: Int] = [:]

    var transcriptReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounts
            .filter { $0.key.hasSuffix("/transcript.json") }
            .values
            .reduce(0, +)
    }

    var resourceReadCounts: [String: Int] {
        lock.withLock { readCounts }
    }

    func read(_ source: DemoResourceDataSource) throws -> Data {
        let url = source.url
        lock.lock()
        readCounts[url.path, default: 0] += 1
        let count = readCounts[url.path, default: 0]
        lock.unlock()

        if url.lastPathComponent == "transcript.json", count > 1 {
            throw InjectedDataReadError.forced
        }
        return try source.read()
    }
}

func expectError(
    _ expected: DemoLibraryError,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        Issue.record("Expected \(expected), but the operation succeeded.")
    } catch let actual as DemoLibraryError {
        #expect(actual == expected)
    }
}

func makeDemoManifest(
    datasetVersion: String = "2026-08-23",
    revisionOffset: Int = 0
) -> DemoDatasetManifest {
    let meetings = [
        makeMeeting(
            index: 1,
            itemID: "projektauftakt",
            title: "DEMO: Projektauftakt",
            revisionOffset: revisionOffset
        ),
        makeMeeting(
            index: 2,
            itemID: "wochenrunde",
            title: "DEMO: Wochenrunde",
            revisionOffset: revisionOffset
        ),
        makeMeeting(
            index: 3,
            itemID: "produktinterview",
            title: "DEMO: Produktinterview",
            revisionOffset: revisionOffset
        ),
    ]
    let resources = meetings.flatMap { meeting -> [DemoResourceDescriptor] in
        var descriptors = [
            DemoResourceDescriptor(
                id: meeting.transcript.resourceID,
                kind: .transcript,
                relativePath: "\(meeting.itemID)/transcript.json",
                byteCount: 0,
                sha256: String(repeating: "0", count: 64)
            ),
            DemoResourceDescriptor(
                id: meeting.audio.resourceID,
                kind: .audio,
                relativePath: "\(meeting.itemID)/audio.wav",
                byteCount: 0,
                sha256: String(repeating: "0", count: 64)
            ),
            DemoResourceDescriptor(
                id: "reference-text-\(meeting.itemID)",
                kind: .referenceTranscript,
                relativePath: "\(meeting.itemID)/reference.txt",
                byteCount: 0,
                sha256: String(repeating: "0", count: 64)
            ),
            DemoResourceDescriptor(
                id: "reference-rttm-\(meeting.itemID)",
                kind: .referenceTimeline,
                relativePath: "\(meeting.itemID)/reference.rttm",
                byteCount: 0,
                sha256: String(repeating: "0", count: 64)
            ),
        ]
        if meeting.itemID != "produktinterview" {
            descriptors.append(DemoResourceDescriptor(
                id: "notes-\(meeting.itemID)",
                kind: .note,
                relativePath: "\(meeting.itemID)/notes.md",
                byteCount: 0,
                sha256: String(repeating: "0", count: 64)
            ))
        }
        if meeting.itemID != "wochenrunde" {
            descriptors.append(DemoResourceDescriptor(
                id: "report-\(meeting.itemID)",
                kind: .report,
                relativePath: "\(meeting.itemID)/report.md",
                byteCount: 0,
                sha256: String(repeating: "0", count: 64)
            ))
        }
        return descriptors
    } + [
        DemoResourceDescriptor(
            id: "attribution",
            kind: .attribution,
            relativePath: "ATTRIBUTION.md",
            byteCount: 0,
            sha256: String(repeating: "0", count: 64)
        ),
    ]
    return DemoDatasetManifest(
        schemaVersion: 1,
        datasetID: DemoDatasetManifest.requiredDatasetID,
        datasetVersion: datasetVersion,
        generator: DemoGeneratorProvenance(
            generator: "Piper",
            generatorRevision: "v1",
            model: "de_DE-mls-medium",
            modelRevision: "abc123",
            speakerIDs: ["1", "2", "3"],
            inputScriptSHA256: String(repeating: "1", count: 64),
            mixParameters: ["sampleRate": 24_000],
            license: "MIT",
            modificationProvenance: "Mixed into synthetic fixtures."
        ),
        meetings: meetings,
        resources: resources
    )
}

private func makeMeeting(
    index: Int,
    itemID: String,
    title: String,
    revisionOffset: Int
) -> DemoMeetingManifest {
    var resourceIDs: [String] = []
    if itemID != "produktinterview" { resourceIDs.append("notes-\(itemID)") }
    if itemID != "wochenrunde" { resourceIDs.append("report-\(itemID)") }
    resourceIDs.append(contentsOf: [
        "reference-text-\(itemID)",
        "reference-rttm-\(itemID)",
        "attribution",
    ])
    return DemoMeetingManifest(
        id: MeetingID(rawValue: uuid(index)),
        itemID: itemID,
        title: title,
        createdAtUTC: "2026-08-2\(index)T12:00:00Z",
        transcript: DemoTranscriptManifest(
            id: RevisionID(rawValue: uuid(100 + revisionOffset + index)),
            resourceID: "transcript-\(itemID)",
            createdAtUTC: "2026-08-2\(index)T12:01:00Z"
        ),
        audio: DemoAudioManifest(
            mediaAssetID: MediaAssetID(rawValue: uuid(200 + index)),
            resourceID: "audio-\(itemID)",
            sampleRate: 24_000,
            duration: 60
        ),
        runs: [DemoRunManifest(
            id: RunID(rawValue: uuid(300 + index)),
            resourceIDs: resourceIDs
        )]
    )
}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", value))!
}

func manifestWithResourceDigests(
    _ manifest: DemoDatasetManifest,
    from root: URL
) throws -> DemoDatasetManifest {
    var copy = manifest
    copy.resources = try manifest.resources.map { descriptor in
        let data = try Data(contentsOf: root.appending(path: descriptor.relativePath))
        return DemoResourceDescriptor(
            id: descriptor.id,
            kind: descriptor.kind,
            relativePath: descriptor.relativePath,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
    return copy
}
