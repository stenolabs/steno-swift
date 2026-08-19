import StenoDomain
import StenoPipeline
import SwiftUI

/// The only place that knows colour names and measurements.
///
/// Ported from `steno-macos/App/Sources/Theme.swift`; the colour set itself
/// lives in the shared asset catalogue, so a speaker keeps the same marker on
/// both platforms. Only `Color(nsColor:)` had to become `Color(uiColor:)`.
enum Steno {
    enum Colors {
        /// Brand colour, independent of the user's accent colour.
        static let brand = Color("StenoBrand")

        static let recording = Color(uiColor: .systemRed)
        static let running = Color("StenoBrand")
        static let confirmed = Color(uiColor: .systemGreen)
        /// Uncertain, provisional, interrupted. Never for real errors.
        static let uncertain = Color(uiColor: .systemOrange)
        static let error = Color(uiColor: .systemRed)

        /// Eight muted tones, deliberately not signal colours. They appear
        /// only as a small marker next to a name, never as a surface and never
        /// as text colour: colour carries no information on its own here.
        static let speakers: [Color] = (1...8).map { Color("Speaker\($0)") }
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    static let cardRadius: CGFloat = 10
    /// Native body metrics preserve legibility across every Dynamic Type size.
    static let readingBody = Font.body
}

extension Steno.Colors {
    static func speaker(_ marker: SpeakerMarker?) -> Color? {
        switch marker {
        case .person(let personID): speaker(for: personID)
        case .unconfirmedRank(let rank): speaker(atRank: rank)
        case .none: nil
        }
    }

    /// A person's colour, stable across meetings and app launches.
    ///
    /// Deliberately a hand-written FNV-1a over the UUID bytes rather than
    /// `Hasher`: Swift's standard hashing is randomly salted per process, so
    /// the colour would change on every launch.
    static func speaker(for personID: PersonID) -> Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: personID.rawValue.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x1000_0000_01b3
            }
        }
        return speakers[Int(hash % UInt64(speakers.count))]
    }

    /// Colour of a cluster nobody has confirmed yet, taken from its position
    /// in the list sorted by speaking time. A new diarisation may change it -
    /// by then they are different clusters.
    static func speaker(atRank rank: Int) -> Color {
        speakers[((rank % speakers.count) + speakers.count) % speakers.count]
    }
}
