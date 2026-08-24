import Dispatch
import Foundation
import StenoDomain
@testable import StenoLibrary
import Synchronization
import Testing

private let fallbackBlockingTestExecutor = DispatchQueue(
    label: "org.steno.library-tests.blocking-executor",
    attributes: .concurrent
)

private enum BlockingTestExecutorContext {
    @TaskLocal static var current: (any TaskExecutor)?
}

private func makeBlockingTestExecutor() -> DispatchQueue {
    DispatchQueue(
        label: "org.steno.library-tests.blocking-executor.\(UUID().uuidString)",
        attributes: .concurrent
    )
}

/// Runs checkpoint-driven test paths on Dispatch workers so their synchronous
/// waits cannot exhaust Swift Concurrency's cooperative thread pool.
///
/// The preference is inherited by structured child tasks, but not by
/// unstructured `Task {}` or `Task.detached`; use `blockingTestTask` for those.
/// It applies to default actors and nonisolated async code, not to actors with
/// custom executors or `MainActor`; none of the paths using this helper contain
/// either. The preference changes thread scheduling, which is immaterial here
/// because the tests force their interleavings through explicit checkpoints
/// instead of relying on scheduling accidents.
func withBlockingTestExecutor<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let executor = makeBlockingTestExecutor()
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
    let executor = BlockingTestExecutorContext.current
        ?? fallbackBlockingTestExecutor
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
    private let issueRecorder: @Sendable (String) -> Void
    private let arrived = Mutex(false)
    private let resume = DispatchSemaphore(value: 0)

    init(
        name: String,
        timeout: DispatchTimeInterval = .seconds(10),
        issueRecorder: @escaping @Sendable (String) -> Void = {
            Issue.record("\($0)")
        }
    ) {
        self.name = name
        self.timeout = timeout
        self.issueRecorder = issueRecorder
    }

    var hasArrived: Bool { arrived.withLock { $0 } }

    func arriveAndWait() {
        arrived.withLock { $0 = true }
        guard resume.wait(timeout: .now() + timeout) == .success else {
            issueRecorder("Timed out waiting to release test pause '\(name)'.")
            return
        }
    }

    func release() {
        resume.signal()
    }
}

func replacePersonsForTest(
    _ persons: [Person],
    in store: IdentityStore
) async throws {
    let snapshot = try await store.snapshot()
    _ = try await store.replacePersons(
        persons,
        expectedRevision: snapshot.revision
    )
}

func withTemporaryDirectory<Result>(
    _ body: (URL) throws -> Result
) throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func withTemporaryDirectory<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
