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
        ]
        return try Self.resolveAvailableBytes(
            importantUsage: capacities[0],
            general: capacities[1]
        )
    }

    static func resolveAvailableBytes(
        importantUsage: Int64?,
        general: Int64?
    ) throws -> Int64 {
        guard let capacity = [importantUsage, general].compactMap({ $0 }).max()
        else {
            throw AudioRecordingError.audioSourceUnavailable(
                "free disk capacity could not be determined"
            )
        }
        return max(0, capacity)
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
