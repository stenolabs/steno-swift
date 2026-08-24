import Foundation
import StenoDomain
import StenoPipeline

enum AppModelReportError: LocalizedError {
    case runtimeUnavailable

    var errorDescription: String? {
        String(localized: "The library is not ready yet.")
    }
}

struct MeetingReportsSnapshot: Equatable {
    let reports: [StoredTemplateResult]
    let jobs: [Job]
}

extension AppModel {
    func reportPreflight(
        for meetingID: MeetingID
    ) async throws -> TemplateRenderPreflight {
        let runtime = try reportRuntime()
        return try await TemplateRenderInputAssembler.preflight(
            library: runtime.library,
            meetingID: meetingID
        )
    }

    func reports(
        for meetingID: MeetingID
    ) async throws -> [StoredTemplateResult] {
        let runtime = try reportRuntime()
        return try TemplateResultStore(layout: runtime.library.layout).list(
            meetingID: meetingID
        )
    }

    func jobs(for meetingID: MeetingID) async throws -> [Job] {
        let runtime = try reportRuntime()
        let meeting = try await runtime.library.loadMeeting(meetingID)
        return try await runtime.jobStore.list().filter {
            $0.meetingID == meetingID
                && $0.processingGenerationID == meeting.processingGenerationID
                && $0.kind == .templateRender
        }
    }

    /// Jobs are loaded first. A finished template job is persisted only after
    /// its result, so this order cannot observe `finished` while missing that
    /// exact result because of a cross-store interleaving.
    func reportsSnapshot(
        for meetingID: MeetingID,
        afterJobsLoaded: () async throws -> Void = {}
    ) async throws -> MeetingReportsSnapshot {
        let jobs = try await jobs(for: meetingID)
        try await afterJobsLoaded()
        let reports = try await reports(for: meetingID)
        return MeetingReportsSnapshot(reports: reports, jobs: jobs)
    }

    func requestMeetingMinutes(
        meetingID: MeetingID,
        textModelEndpointID: String?,
        textModelEndpointSnapshot: TextModelEndpointSnapshot? = nil,
        preflight: TemplateRenderPreflight
    ) async throws -> Job {
        let runtime = try reportRuntime()
        guard let operation = beginLibraryOperation() else {
            throw AppModelLibraryOperationError.operationInProgress
        }
        defer { endFolderOperation(operation) }
        return try await TemplateRenderRequest.enqueue(
            library: runtime.library,
            jobStore: runtime.jobStore,
            meetingID: meetingID,
            templateID: Template.meetingMinutes.id,
            textModelEndpointID: textModelEndpointID,
            textModelEndpointSnapshot: textModelEndpointSnapshot,
            preflight: preflight
        )
    }

    func cancelReportJob(_ jobID: JobID) async throws {
        let runtime = try reportRuntime()
        try await runtime.coordinator.cancel(jobID: jobID)
    }

    private func reportRuntime() throws -> PipelineRuntime {
        guard let runtime else {
            throw AppModelReportError.runtimeUnavailable
        }
        return runtime
    }
}
