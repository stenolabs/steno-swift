import Foundation
import StenoDomain

enum MacGlobalStatusSurface: Equatable {
    case top
    case bottom

    static func notice(isError: Bool) -> MacGlobalStatusSurface {
        isError ? .top : .bottom
    }

    static let startupFailure = MacGlobalStatusSurface.top
    static let audioExport = MacGlobalStatusSurface.bottom
}

enum MacStatusMotionPolicy: Equatable {
    case standard
    case reduced

    init(reduceMotion: Bool) {
        self = reduceMotion ? .reduced : .standard
    }

    var usesPositionalMovement: Bool {
        self == .standard
    }
}

struct MeetingPipelineStatusPresentation: Equatable {
    static let failureTitle: LocalizedStringResource = "Processing failed"

    enum State: Equatable {
        case hidden
        case active(Job)
        case failed(Job)
    }

    let state: State

    var activeTitle: LocalizedStringResource? {
        guard case .active(let job) = state else { return nil }
        return switch (job.kind, job.status) {
        case (.finalASR, .running):
            "Transcription (step 1 of 3) running"
        case (.finalASR, .queued):
            "Transcription (step 1 of 3) queued"
        case (.diarization, .running):
            "Detecting speaker changes (step 2 of 3) running"
        case (.diarization, .queued):
            "Detecting speaker changes (step 2 of 3) queued"
        case (.identitySuggestion, .running):
            "Comparing voices (step 3 of 3) running"
        case (.identitySuggestion, .queued):
            "Comparing voices (step 3 of 3) queued"
        default:
            "Processing"
        }
    }

    static func transferOwnsStatus(
        _ status: MeetingTransferDetailPresentation.ProcessingStatus?
    ) -> Bool {
        switch status {
        case .processing, .failed, .recoveryRequired:
            true
        case .ready, .completed, .confirmLanguage, .modelMissing, nil:
            false
        }
    }

    static func make(
        jobs: [Job],
        isSuppressed: Bool = false
    ) -> MeetingPipelineStatusPresentation {
        guard !isSuppressed else {
            return MeetingPipelineStatusPresentation(state: .hidden)
        }

        let pipelineJobs = jobs.filter {
            $0.kind != .templateRender && $0.kind != .export
        }

        if let running = prioritizedJob(with: .running, in: pipelineJobs) {
            return MeetingPipelineStatusPresentation(state: .active(running))
        }
        if let queued = prioritizedJob(with: .queued, in: pipelineJobs) {
            return MeetingPipelineStatusPresentation(state: .active(queued))
        }

        let failedJobs = pipelineJobs
            .filter { $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
        let visibleFailure = failedJobs.first { failed in
            !pipelineJobs.contains {
                $0.kind == failed.kind
                    && $0.status == .finished
                    && $0.createdAt > failed.createdAt
            }
        }

        if let visibleFailure {
            return MeetingPipelineStatusPresentation(
                state: .failed(visibleFailure)
            )
        }
        return MeetingPipelineStatusPresentation(state: .hidden)
    }

    private static func prioritizedJob(
        with status: Job.Status,
        in jobs: [Job]
    ) -> Job? {
        jobs
            .enumerated()
            .filter { $0.element.status == status }
            .sorted { lhs, rhs in
                let lhsPriority = kindPriority(lhs.element.kind)
                let rhsPriority = kindPriority(rhs.element.kind)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .first?
            .element
    }

    private static func kindPriority(_ kind: Job.Kind) -> Int {
        switch kind {
        case .finalASR: 0
        case .diarization: 1
        case .identitySuggestion: 2
        case .templateRender: 3
        case .export: 4
        }
    }
}
