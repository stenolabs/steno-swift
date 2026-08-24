import Foundation

public enum MeetingTransferProgressPresentation: Equatable, Sendable {
    case indeterminate
    case determinate(Double)

    public var accessibilityLabel: LocalizedStringResource {
        "Import progress"
    }

    public static func make(_ progress: MeetingTransferProgress?) -> Self {
        guard let progress, progress.totalBytes > 0 else {
            return .indeterminate
        }

        let fraction = Double(progress.processedBytes) / Double(progress.totalBytes)
        return .determinate(min(max(fraction, 0), 1))
    }
}
