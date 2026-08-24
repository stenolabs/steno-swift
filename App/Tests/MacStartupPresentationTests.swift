import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Mac startup presentation", .serialized)
@MainActor
struct MacStartupPresentationTests {
    @Test("fatal startup stays visible and retry opens the same library once")
    func fatalStartupRetriesSameLibraryWithoutRemovingExistingData() async throws {
        let fixture = try MacStartupFixture()
        defer { fixture.cleanUp() }
        let existingData = Data("keep this local file".utf8)
        let existingURL = fixture.libraryURL.appendingPathComponent("existing-data")
        try existingData.write(to: existingURL)
        let starter = MacPipelineStarterProbe()
        let model = AppModel(
            pipelineStarter: { request in
                try await starter.run(request)
            },
            libraryURL: fixture.libraryURL
        )
        model.report(
            "An earlier capture warning remains visible.",
            isError: true,
            autoDismiss: false
        )

        #expect(model.startupState == .opening)
        await model.bootstrap()

        let failure = MacStartupFailure.runtimeOpening(
            MacStartupTestError.openFailed.localizedDescription
        )
        #expect(model.startupState == .failed(failure))
        #expect(model.runtime == nil)
        #expect(model.notice?.text == "An earlier capture warning remains visible.")

        let retry = Task { @MainActor in
            await model.retryStartup()
        }
        await starter.waitUntilRetryStarted()

        #expect(model.startupState == .opening)
        #expect(model.notice?.text == "An earlier capture warning remains visible.")
        #expect(await starter.attemptCount == 2)

        await starter.releaseRetry()
        await retry.value

        #expect(model.startupState == .ready)
        #expect(model.runtime != nil)
        #expect(model.notice?.text == "An earlier capture warning remains visible.")
        let warning = try #require(model.startupWarnings.first)
        if case .pipeline(let warningMessage) = warning {
            let expected = String(localized: "Steno found an original recording file that could not be safely registered. The file remains stored and needs attention.")
            #expect(warningMessage == expected)
        } else {
            Issue.record("Expected an independent pipeline startup warning")
        }
        #expect(try Data(contentsOf: existingURL) == existingData)
        #expect(await starter.requestedLibraryURLs == [
            fixture.libraryURL.standardizedFileURL,
            fixture.libraryURL.standardizedFileURL,
        ])
        await model.runtime?.coordinator.stop()
    }

    @Test("startup remains opening until the final library refresh finishes")
    func delayedFinalStartupPhasePreventsRecording() async throws {
        let fixture = try MacStartupFixture()
        defer { fixture.cleanUp() }
        let loader = DelayedInitialMeetingLoader()
        let model = AppModel(
            meetingListLoader: { library in
                try await loader.run(library)
            },
            libraryURL: fixture.libraryURL
        )

        let bootstrap = Task { @MainActor in
            await model.bootstrap()
        }
        await loader.waitUntilStarted()

        #expect(model.runtime != nil)
        #expect(model.startupState == .opening)
        #expect(model.isBootstrappingPipeline)
        #expect(!model.canStartRecording)

        await loader.release()
        await bootstrap.value

        #expect(model.startupState == .ready)
        #expect(!model.isBootstrappingPipeline)
        #expect(model.canStartRecording)
        await model.runtime?.coordinator.stop()
    }

    @Test("an older meeting retry cannot publish or clear a newer retry spinner")
    func staleMeetingRetryCannotOverwriteNewerRefreshOrRetry() async throws {
        let fixture = try MacStartupFixture()
        defer { fixture.cleanUp() }
        let oldMeeting = Meeting(title: "Stale meeting", status: .ready)
        let newMeeting = Meeting(title: "Current meeting", status: .ready)
        let loader = MeetingRefreshRaceLoader(
            oldMeeting: oldMeeting,
            newMeeting: newMeeting
        )
        let model = AppModel(
            meetingListLoader: { library in
                try await loader.run(library)
            },
            libraryURL: fixture.libraryURL
        )
        await model.bootstrap()

        await model.refreshMeetings()
        let firstIssue = try #require(
            model.libraryIssues.first { $0.id == .meetings }
        )
        let oldRetry = Task { @MainActor in
            await model.retryLibraryIssue(firstIssue)
        }
        await loader.waitUntilOldRetryStarted()
        #expect(model.retryingLibraryIssueIDs.contains(.meetings))

        let duplicateRetry = Task { @MainActor in
            await model.retryLibraryIssue(firstIssue)
        }
        await duplicateRetry.value
        #expect(await loader.callCount == 3)
        #expect(model.retryingLibraryIssueIDs.contains(.meetings))

        await model.refreshMeetings()
        #expect(!model.retryingLibraryIssueIDs.contains(.meetings))
        let currentIssue = try #require(
            model.libraryIssues.first { $0.id == .meetings }
        )
        let newRetry = Task { @MainActor in
            await model.retryLibraryIssue(currentIssue)
        }
        await loader.waitUntilNewRetryStarted()
        #expect(model.retryingLibraryIssueIDs.contains(.meetings))

        await loader.releaseOldRetry()
        await oldRetry.value

        #expect(model.retryingLibraryIssueIDs.contains(.meetings))
        #expect(model.libraryIssues.contains { $0.id == .meetings })
        #expect(!model.meetings.contains { $0.id == oldMeeting.id })

        await loader.releaseNewRetry()
        await newRetry.value

        #expect(!model.retryingLibraryIssueIDs.contains(.meetings))
        #expect(model.libraryIssues.allSatisfy { $0.id != .meetings })
        #expect(model.meetings.map(\.id) == [newMeeting.id])
        await model.runtime?.coordinator.stop()
    }

    @Test("an older folder retry cannot publish or clear a newer retry spinner")
    func staleFolderRetryCannotOverwriteNewerRefreshOrRetry() async throws {
        let fixture = try MacStartupFixture()
        defer { fixture.cleanUp() }
        let oldFolder = Folder(name: "Stale folder", sortIndex: 0)
        let newFolder = Folder(name: "Current folder", sortIndex: 0)
        let loader = FolderRefreshRaceLoader(
            oldFolder: oldFolder,
            newFolder: newFolder
        )
        let model = AppModel(
            folderListLoader: { store in
                try await loader.run(store)
            },
            libraryURL: fixture.libraryURL
        )
        await model.bootstrap()

        await model.refreshMeetings()
        let firstIssue = try #require(
            model.libraryIssues.first { $0.id == .folders }
        )
        let oldRetry = Task { @MainActor in
            await model.retryLibraryIssue(firstIssue)
        }
        await loader.waitUntilOldRetryStarted()
        #expect(model.retryingLibraryIssueIDs.contains(.folders))

        await model.refreshMeetings()
        let currentIssue = try #require(
            model.libraryIssues.first { $0.id == .folders }
        )
        let newRetry = Task { @MainActor in
            await model.retryLibraryIssue(currentIssue)
        }
        await loader.waitUntilNewRetryStarted()
        #expect(model.retryingLibraryIssueIDs.contains(.folders))

        await loader.releaseOldRetry()
        await oldRetry.value

        #expect(model.retryingLibraryIssueIDs.contains(.folders))
        #expect(model.libraryIssues.contains { $0.id == .folders })
        #expect(!model.folders.contains { $0.id == oldFolder.id })

        await loader.releaseNewRetry()
        await newRetry.value

        #expect(!model.retryingLibraryIssueIDs.contains(.folders))
        #expect(model.libraryIssues.allSatisfy { $0.id != .folders })
        #expect(model.folders.map(\.id) == [newFolder.id])
        await model.runtime?.coordinator.stop()
    }

    @Test("an older retry cannot publish after the runtime changes")
    func staleMeetingRetryCannotCrossRuntimeTransition() async throws {
        let fixture = try MacStartupFixture()
        defer { fixture.cleanUp() }
        let defaultsSuite = "MacStartupPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set("de-DE", forKey: TranscriptionLanguagePreferences.languageKey)
        defaults.set(true, forKey: TranscriptionLanguagePreferences.explicitChoiceKey)
        let staleMeeting = Meeting(title: "Old runtime", status: .ready)
        let loader = RuntimeTransitionMeetingLoader(staleMeeting: staleMeeting)
        let model = AppModel(
            languagePreferences: TranscriptionLanguagePreferences(defaults: defaults),
            supportedLocalesLoader: {
                [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]
            },
            meetingListLoader: { library in
                try await loader.run(library)
            },
            libraryURL: fixture.libraryURL
        )
        await model.bootstrap()
        let originalRuntime = try #require(model.runtime)

        await model.refreshMeetings()
        let issue = try #require(
            model.libraryIssues.first { $0.id == .meetings }
        )
        let oldRetry = Task { @MainActor in
            await model.retryLibraryIssue(issue)
        }
        await loader.waitUntilRetryStarted()

        await model.setLanguage("en-US")
        let replacementRuntime = try #require(model.runtime)
        #expect(replacementRuntime.library !== originalRuntime.library)
        #expect(model.startupState == .ready)
        #expect(model.libraryIssues.allSatisfy { $0.id != .meetings })
        #expect(!model.retryingLibraryIssueIDs.contains(.meetings))

        await loader.releaseRetry()
        await oldRetry.value

        #expect(model.runtime?.library === replacementRuntime.library)
        #expect(model.startupState == .ready)
        #expect(model.libraryIssues.allSatisfy { $0.id != .meetings })
        #expect(!model.meetings.contains { $0.id == staleMeeting.id })
        await replacementRuntime.coordinator.stop()
    }

    @Test("startup and library issues expose distinct localized actions")
    func typedPresentationKeepsFailureCategoriesDistinct() {
        let startup = MacStartupFailure.runtimeOpening("disk unavailable")
        let meetings = MacLibraryIssue.meetings("meeting index unavailable")
        let folders = MacLibraryIssue.folders("folder index unavailable")

        #expect(startup.compatibilityMessage == "disk unavailable")
        #expect(meetings.id == .meetings)
        #expect(folders.id == .folders)
        #expect(meetings.compatibilityMessage == "meeting index unavailable")
        #expect(folders.compatibilityMessage == "folder index unavailable")
    }

    @Test("a folder-open failure stays recoverable without replacing the runtime")
    func folderOpenFailureRetriesOnlyTheFolderStore() async throws {
        let fixture = try MacStartupFixture()
        defer { fixture.cleanUp() }
        let foldersURL = fixture.libraryURL.appendingPathComponent("folders.json")
        try Data("{".utf8).write(to: foldersURL)
        let model = AppModel(libraryURL: fixture.libraryURL)

        await model.bootstrap()

        let runtime = try #require(model.runtime)
        #expect(model.startupState == .ready)
        #expect(model.folderStore == nil)
        #expect(model.canStartRecording)
        let issue = try #require(
            model.libraryIssues.first { $0.id == .folders }
        )

        if FileManager.default.fileExists(atPath: foldersURL.path) {
            try FileManager.default.removeItem(at: foldersURL)
        }
        await model.retryLibraryIssue(issue)

        #expect(model.folderStore != nil)
        #expect(model.libraryIssues.allSatisfy { $0.id != .folders })
        #expect(model.runtime?.library === runtime.library)
        await model.runtime?.coordinator.stop()
    }
}

private struct MacStartupFixture {
    let root: URL
    let libraryURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-MacStartupPresentationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        _ = try Library.open(at: libraryURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor MacPipelineStarterProbe {
    private(set) var attemptCount = 0
    private(set) var requestedLibraryURLs: [URL] = []
    private var retryStarted = false
    private var retryContinuation: CheckedContinuation<Void, Never>?

    func run(_ request: MacPipelineStartRequest) async throws -> PipelineRuntime {
        attemptCount += 1
        requestedLibraryURLs.append(request.libraryURL.standardizedFileURL)
        if attemptCount == 1 {
            throw MacStartupTestError.openFailed
        }
        retryStarted = true
        await withCheckedContinuation { continuation in
            retryContinuation = continuation
        }
        let runtime = try await startPipeline(
            at: request.libraryURL,
            transcriptionProviderResolver: request.transcriptionProviderResolver,
            modelCacheDirectory: request.modelCacheDirectory,
            textModelProviderResolver: request.textModelProviderResolver,
            locale: request.locale,
            activeMeetingIDs: request.activeMeetingIDs
        )
        return PipelineRuntime(
            library: runtime.library,
            jobStore: runtime.jobStore,
            coordinator: runtime.coordinator,
            startupWarnings: [
                .orphanedMedia(
                    meetingID: MeetingID(),
                    fileName: "preserved-original.caf"
                ),
            ]
        )
    }

    func waitUntilRetryStarted() async {
        while !retryStarted {
            await Task.yield()
        }
    }

    func releaseRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }
}

private actor DelayedInitialMeetingLoader {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(_ library: Library) async throws -> [Meeting] {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return try await library.listMeetings()
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MeetingRefreshRaceLoader {
    private(set) var callCount = 0
    private let oldMeeting: Meeting
    private let newMeeting: Meeting
    private var oldRetryStarted = false
    private var newRetryStarted = false
    private var oldRetryContinuation: CheckedContinuation<Void, Never>?
    private var newRetryContinuation: CheckedContinuation<Void, Never>?

    init(oldMeeting: Meeting, newMeeting: Meeting) {
        self.oldMeeting = oldMeeting
        self.newMeeting = newMeeting
    }

    func run(_ library: Library) async throws -> [Meeting] {
        callCount += 1
        switch callCount {
        case 1:
            return try await library.listMeetings()
        case 2, 4:
            throw MacStartupTestError.refreshFailed
        case 3:
            oldRetryStarted = true
            await withCheckedContinuation { continuation in
                oldRetryContinuation = continuation
            }
            return [oldMeeting]
        case 5:
            newRetryStarted = true
            await withCheckedContinuation { continuation in
                newRetryContinuation = continuation
            }
            return [newMeeting]
        default:
            return try await library.listMeetings()
        }
    }

    func waitUntilOldRetryStarted() async {
        while !oldRetryStarted {
            await Task.yield()
        }
    }

    func waitUntilNewRetryStarted() async {
        while !newRetryStarted {
            await Task.yield()
        }
    }

    func releaseOldRetry() {
        oldRetryContinuation?.resume()
        oldRetryContinuation = nil
    }

    func releaseNewRetry() {
        newRetryContinuation?.resume()
        newRetryContinuation = nil
    }
}

private actor RuntimeTransitionMeetingLoader {
    private let staleMeeting: Meeting
    private var callCount = 0
    private var retryStarted = false
    private var retryContinuation: CheckedContinuation<Void, Never>?

    init(staleMeeting: Meeting) {
        self.staleMeeting = staleMeeting
    }

    func run(_ library: Library) async throws -> [Meeting] {
        callCount += 1
        switch callCount {
        case 1, 4:
            return try await library.listMeetings()
        case 2:
            throw MacStartupTestError.refreshFailed
        case 3:
            retryStarted = true
            await withCheckedContinuation { continuation in
                retryContinuation = continuation
            }
            return [staleMeeting]
        default:
            return try await library.listMeetings()
        }
    }

    func waitUntilRetryStarted() async {
        while !retryStarted {
            await Task.yield()
        }
    }

    func releaseRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }
}

private actor FolderRefreshRaceLoader {
    private var callCount = 0
    private let oldFolder: Folder
    private let newFolder: Folder
    private var oldRetryStarted = false
    private var newRetryStarted = false
    private var oldRetryContinuation: CheckedContinuation<Void, Never>?
    private var newRetryContinuation: CheckedContinuation<Void, Never>?

    init(oldFolder: Folder, newFolder: Folder) {
        self.oldFolder = oldFolder
        self.newFolder = newFolder
    }

    func run(_ store: FolderStore) async throws -> [Folder] {
        callCount += 1
        switch callCount {
        case 1:
            return try await store.listFolders()
        case 2, 4:
            throw MacStartupTestError.refreshFailed
        case 3:
            oldRetryStarted = true
            await withCheckedContinuation { continuation in
                oldRetryContinuation = continuation
            }
            return [oldFolder]
        case 5:
            newRetryStarted = true
            await withCheckedContinuation { continuation in
                newRetryContinuation = continuation
            }
            return [newFolder]
        default:
            return try await store.listFolders()
        }
    }

    func waitUntilOldRetryStarted() async {
        while !oldRetryStarted {
            await Task.yield()
        }
    }

    func waitUntilNewRetryStarted() async {
        while !newRetryStarted {
            await Task.yield()
        }
    }

    func releaseOldRetry() {
        oldRetryContinuation?.resume()
        oldRetryContinuation = nil
    }

    func releaseNewRetry() {
        newRetryContinuation?.resume()
        newRetryContinuation = nil
    }
}

private enum MacStartupTestError: LocalizedError {
    case openFailed
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .openFailed:
            "The library disk is unavailable."
        case .refreshFailed:
            "The meeting list is temporarily unavailable."
        }
    }
}
