import Foundation
import StenoDomain

/// Verhindert, dass derselbe bereits persistierte Pin-Fehler bei jedem
/// erneuten Aufbau einer Protokollansicht wieder als neu erscheint.
public final class TemplateRenderPinsFailureObservationLedger:
    @unchecked Sendable,
    Equatable
{
    public static let process = TemplateRenderPinsFailureObservationLedger()

    private let lock = NSLock()
    private var observedJobIDs: Set<JobID> = []

    public init() {}

    public func claimLatestFailure(in jobs: [Job]) -> Job? {
        guard let latest = (jobs
            .filter { $0.kind == .templateRender }
            .max(by: { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id < rhs.id
            })),
            latest.status == .failed,
            latest.failureReason == .templateRenderPinsRequired
                || latest.failureReason == .textModelEndpointConfigurationIncomplete
        else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard observedJobIDs.insert(latest.id).inserted else { return nil }
        return latest
    }

    public static func == (
        lhs: TemplateRenderPinsFailureObservationLedger,
        rhs: TemplateRenderPinsFailureObservationLedger
    ) -> Bool {
        lhs === rhs
    }
}
