import Foundation

public struct DiskSpaceChecker: Sendable {
    public static let minimumRecordingBytes: Int64 = 2_000_000_000

    public init() {}

    public func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let capacities = [
            values.volumeAvailableCapacityForImportantUsage,
            values.volumeAvailableCapacity.map(Int64.init),
        ].compactMap { $0 }
        if let capacity = capacities.max(), capacity > 0 { return capacity }
        throw AudioRecordingError.audioSourceUnavailable(
            "free disk capacity could not be determined"
        )
    }

    public func validate(at url: URL) throws {
        try Self.validate(availableBytes: availableBytes(at: url))
    }

    public static func validate(availableBytes: Int64) throws {
        guard availableBytes >= minimumRecordingBytes else {
            throw AudioRecordingError.insufficientDiskSpace(
                requiredBytes: minimumRecordingBytes,
                availableBytes: availableBytes
            )
        }
    }
}
