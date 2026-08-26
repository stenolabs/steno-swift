import Foundation
import StenoDomain

// Observation seam note:
//
// AppModel surfaces pipeline state for UI badges by listing the job store on
// demand (`AppModel.jobs(for:)` feeds `MeetingPipelineStatusPresentation` in
// views that run their own refresh loops). There is no push event from
// JobStore, and `Library.meetingChanges()` alone cannot classify job outcomes
// nor survive a runtime swap without editing AppModel.swift. So this hook
// reuses the same seam the badges use - polling `runtime.jobStore.list()` -
// through a lightweight poller bridge kept entirely inside this file.

extension AppModel {
    /// Long-lived poller installed once per process; reads the current
    /// `AppModel.runtime` on every pass, so pipeline re-bootstraps are picked
    /// up automatically without holding onto a stale PipelineRuntime.
    private static var jobCompletionWatcher: StenoJobCompletionWatcher?

    func installNotificationHooks() {
        guard Self.jobCompletionWatcher == nil else { return }
        let watcher = StenoJobCompletionWatcher(appModel: self)
        Self.jobCompletionWatcher = watcher
        watcher.start()
    }
}

/// Watches pipeline jobs for terminal status transitions and posts the
/// corresponding user notification:
///
/// - finalASR / diarization finished -> `.transcriptReady`
/// - templateRender finished         -> `.noteReady`
/// - any job failed                  -> `.processingFailed`
/// - cancelled jobs stay silent
///
/// Notifications are suppressed while their meeting is the currently
/// selected one (the user is already looking at it), and gated entirely by
/// the `steno.notifications.enabled` setting inside `StenoNotifications`.
@MainActor
final class StenoJobCompletionWatcher {
    private weak var appModel: AppModel?
    private var pollTask: Task<Void, Never>?

    /// Last observed status per job. Jobs absent from this map have not been
    /// seen yet; brand-new jobs that already show a terminal status (for
    /// example a fast job finishing between two polls) notify directly.
    private var lastStatuses: [JobID: Job.Status] = [:]

    /// The very first successful listing only establishes the baseline so an
    /// app launch never replays pre-existing finished/failed jobs as
    /// notifications.
    private var hasBaseline = false

    static let pollInterval: Duration = .seconds(2)

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    deinit {
        pollTask?.cancel()
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func poll() async {
        guard let appModel, let runtime = appModel.runtime else { return }

        let jobs = (try? await runtime.jobStore.list()) ?? []

        if !hasBaseline {
            lastStatuses = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) })
            hasBaseline = true
            return
        }

        // Resolve titles at most once per affected meeting per pass. Stored
        // as optional-in-optional so unknown titles are cached too.
        var titles: [MeetingID: String?] = [:]

        for job in jobs {
            let previous = lastStatuses[job.id]
            lastStatuses[job.id] = job.status

            // Only true transitions may notify.
            if let previous, previous == job.status { continue }
            guard let kind = Self.notificationKind(for: job) else { continue }
            // Suppressed for the meeting the user is currently viewing;
            // marking the status above keeps it suppressed for good.
            guard job.meetingID != appModel.selectedMeetingID else { continue }

            let title: String?
            if let cached = titles[job.meetingID] {
                title = cached
            } else {
                let loaded = try? await runtime.library.loadMeeting(job.meetingID)
                titles[job.meetingID] = loaded?.title
                title = loaded?.title
            }

            await StenoNotifications.shared.post(
                kind: kind,
                meetingTitle: title,
                meetingID: job.meetingID.description
            )
        }
    }

    /// Maps a job's terminal transition to a notification kind. Failed jobs
    /// of any kind surface as `.processingFailed`. Cancelled jobs are
    /// deliberate user actions and stay silent; intermediate statuses and
    /// kinds with no user-facing completion surface (identitySuggestion,
    /// export) return nil.
    private static func notificationKind(for job: Job) -> StenoNotificationKind? {
        if job.status == .failed {
            return .processingFailed
        }
        switch job.kind {
        case .finalASR, .diarization:
            return job.status == .finished ? .transcriptReady : nil
        case .templateRender:
            return job.status == .finished ? .noteReady : nil
        case .identitySuggestion, .export:
            return nil
        }
    }
}
