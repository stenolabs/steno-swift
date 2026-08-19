import Foundation

public enum MeetingTransferLimits {
    public static let maximumFileCount = 32
    public static let maximumDirectoryDepth = 2
    public static let maximumAudioBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    public static let maximumTotalBytes: Int64 = 24 * 1_024 * 1_024 * 1_024
    public static let maximumArchiveOverheadBytes: Int64 = 2 * 1_024 * 1_024
    public static let maximumTransportFileBytes = maximumTotalBytes + maximumArchiveOverheadBytes
    public static let maximumManifestBytes = 1 * 1_024 * 1_024
    public static let maximumMeetingDocumentBytes = 1 * 1_024 * 1_024
    public static let maximumAudioMetadataBytes = 64 * 1_024
    public static let minimumFreeSpaceReserveBytes: Int64 = 2_000_000_000
    public static let maximumNotesBytes = 16 * 1_024 * 1_024
    public static let maximumTranscriptBytes = 64 * 1_024 * 1_024
    public static let maximumSpeakers = 10_000
    public static let maximumTurns = 200_000
    public static let maximumWords = 2_000_000
    public static let maximumLabelBytes = 1_024
}
