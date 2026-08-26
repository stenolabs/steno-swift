import Foundation
import StenoDomain

/// Provenance keys for originally recorded tracks (`micTrack`, `systemTrack`).
///
/// The first track of a kind keeps the historical key `"<meetingID>/<kind>"`,
/// so existing libraries, legacy imports, and dedup lookups stay stable.
/// Recordings appended later to the same meeting ("continue recording")
/// extend the scheme with a one-based sequence number:
/// `"<meetingID>/<kind>#2"`, `"<meetingID>/<kind>#3"`, and so on.
///
/// The sequence doubles as the track's recording-session index: tracks with
/// the same sequence were captured in parallel during one session (their
/// local times both start at zero), while higher sequences were recorded
/// strictly later - sequence order is recordedAt order without depending on
/// file timestamps.
public enum RecordedTrackProvenanceKey {
    /// Sequence of a track that follows the historical key format.
    public static let firstSequence = 1

    /// Builds the provenance key for a recorded track.
    public static func make(
        meetingID: MeetingID,
        kind: MediaAsset.Kind,
        sequence: Int
    ) -> String {
        precondition(sequence >= firstSequence, "track sequences are one-based")
        guard sequence > firstSequence else {
            return "\(meetingID)/\(kind.rawValue)"
        }
        return "\(meetingID)/\(kind.rawValue)#\(sequence)"
    }

    /// Decodes the sequence encoded in `provenanceKey`, or nil when the key
    /// was not minted for a recorded track of this meeting and kind (imports,
    /// transfers, and foreign keys never parse).
    public static func sequence(
        of provenanceKey: String,
        meetingID: MeetingID,
        kind: MediaAsset.Kind
    ) -> Int? {
        let base = "\(meetingID)/\(kind.rawValue)"
        if provenanceKey == base { return firstSequence }
        guard provenanceKey.hasPrefix("\(base)#") else { return nil }
        let suffix = String(provenanceKey.dropFirst(base.count + 1))
        guard let sequence = Int(suffix), sequence > firstSequence else {
            return nil
        }
        return sequence
    }

    /// Next free sequence for a recorded track of this meeting and kind:
    /// one more than the highest sequence already registered.
    public static func nextSequence(
        for meetingID: MeetingID,
        kind: MediaAsset.Kind,
        in assets: [MediaAsset]
    ) -> Int {
        let sameKind = assets.filter {
            $0.meetingID == meetingID && $0.kind == kind
        }
        guard !sameKind.isEmpty else { return firstSequence }
        let sequences = sameKind.compactMap {
            sequence(of: $0.provenanceKey, meetingID: meetingID, kind: kind)
        }
        // An unparsable key (not expected for recorded kinds) still occupies
        // the first slot and must not be handed out again.
        return max(sequences.max() ?? 0, firstSequence) + 1
    }
}

