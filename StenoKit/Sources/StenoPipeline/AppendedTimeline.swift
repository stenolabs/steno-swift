import Foundation
import StenoDomain
import StenoLibrary

/// Timeline mapping for meetings that received additional recordings
/// ("continue recording").
///
/// Tracks captured inside ONE recording session run in parallel and share
/// local time zero; a session appended later continues after the longest end
/// of everything recorded before it. The session a track belongs to is its
/// provenance sequence (`"<meetingID>/<kind>"` for the first, `"...#n"` for
/// later sessions - see `RecordedTrackProvenanceKey`). Because sequences are
/// handed out in recording order, sequence order IS recordedAt order,
/// without depending on mutable file timestamps.
///
/// Assets whose provenance keys do not parse as recorded-track keys (legacy
/// imports, transfers) are treated as one first session starting at zero,
/// which preserves the pre-append behavior for single-session meetings.
public enum AppendedTimeline {
    /// Absolute meeting-time offset for every asset: assets of the same
    /// session share an offset; each later session starts after the longest
    /// end of all earlier sessions.
    public static func offsets(
        for assets: [MediaAsset]
    ) -> [MediaAssetID: TimeInterval] {
        var result: [MediaAssetID: TimeInterval] = [:]
        var sessionOffset: TimeInterval = 0
        for (_, group) in orderedSessions(in: assets) {
            var sessionEnd = sessionOffset
            for asset in group {
                result[asset.id] = sessionOffset
                sessionEnd = max(sessionEnd, sessionOffset + max(0, asset.duration))
            }
            sessionOffset = sessionEnd
        }
        return result
    }

    /// Absolute end of the timeline spanned by `assets`. This is both the
    /// displayed length of a multi-session meeting and the offset at which a
    /// newly appended recording starts.
    public static func timelineEnd(of assets: [MediaAsset]) -> TimeInterval {
        let offsets = offsets(for: assets)
        return assets.reduce(0) { current, asset in
            max(current, (offsets[asset.id] ?? 0) + max(0, asset.duration))
        }
    }

    /// Chronological processing order for final ASR: ascending session,
    /// microphone before system inside a session. Deterministic and stable
    /// regardless of how the library lists the assets.
    public static func processingOrder(_ assets: [MediaAsset]) -> [MediaAsset] {
        orderedSessions(in: assets).flatMap(\.element)
    }

    private static func orderedSessions(
        in assets: [MediaAsset]
    ) -> [(session: Int, element: [MediaAsset])] {
        let kindOrder: [MediaAsset.Kind: Int] = [
            .micTrack: 0,
            .systemTrack: 1,
            .imported: 2,
        ]
        var grouped: [Int: [MediaAsset]] = [:]
        for asset in assets {
            grouped[sessionIndex(of: asset), default: []].append(asset)
        }
        return grouped.sorted { $0.key < $1.key }.map { key, group in
            (key, group.sorted {
                if $0.kind != $1.kind {
                    return (kindOrder[$0.kind] ?? 0) < (kindOrder[$1.kind] ?? 0)
                }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            })
        }
    }

    private static func sessionIndex(of asset: MediaAsset) -> Int {
        RecordedTrackProvenanceKey.sequence(
            of: asset.provenanceKey,
            meetingID: asset.meetingID,
            kind: asset.kind
        ) ?? RecordedTrackProvenanceKey.firstSequence
    }
}
