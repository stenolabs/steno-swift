import StenoDomain
import StenoPipeline
import SwiftUI

/// The single place that knows visual roles and measurements.
///
/// Semantic system colors remain authoritative for controls and status. The
/// paper palette below gives reading surfaces Steno's own quiet identity while
/// retaining explicit light and dark variants.
enum Steno {
    enum Colors {
        /// Brand color, independent from the user's system accent color.
        static let brand = Color("StenoBrand")

        static let recording = Color(nsColor: .systemRed)
        static let running = Color("StenoBrand")
        static let confirmed = Color(nsColor: .systemGreen)
        /// Uncertain, provisional, or interrupted. Never used for errors.
        static let uncertain = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)

        /// Eight muted hues used only as a marker alongside a speaker name.
        static let speakers: [Color] = (1...8).map { Color("Speaker\($0)") }
    }

    enum Surfaces {
        static func paper(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.102, green: 0.102, blue: 0.094)
                : Color(red: 0.980, green: 0.976, blue: 0.953)
        }

        static func sunkenPaper(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.075, green: 0.075, blue: 0.067)
                : Color(red: 0.961, green: 0.953, blue: 0.918)
        }

        static func ink(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.929, green: 0.918, blue: 0.878)
                : Color(red: 0.106, green: 0.106, blue: 0.098)
        }

        static func quietInk(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.667, green: 0.655, blue: 0.624)
                : Color(red: 0.420, green: 0.420, blue: 0.400)
        }

        static func border(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0.204, green: 0.200, blue: 0.184)
                : Color(red: 0.867, green: 0.847, blue: 0.804)
        }
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Layout {
        static let readingWidth: CGFloat = 760
        static let chronologyRailWidth: CGFloat = 72
        static let sidebarIdealWidth: CGFloat = 268
    }

    enum Typography {
        static let homeTitle = Font.system(size: 34, weight: .regular, design: .serif)
        static let meetingTitle = Font.system(size: 36, weight: .regular, design: .serif)
        static let wordmark = Font.system(size: 20, weight: .semibold, design: .serif)
    }

    static let cardRadius: CGFloat = 10
    /// Transcript and report body text share the same readable size.
    static let readingBody = Font.system(size: 14)
}

extension Steno.Colors {
    static func speaker(_ marker: SpeakerMarker?) -> Color? {
        switch marker {
        case .person(let personID): speaker(for: personID)
        case .unconfirmedRank(let rank): speaker(atRank: rank)
        case .none: nil
        }
    }

    /// A stable color for one person across meetings and app launches.
    /// FNV-1a is deliberate because Swift's standard hashing is per-process.
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

    /// Color for an unconfirmed cluster, derived from its speech-time rank.
    static func speaker(atRank rank: Int) -> Color {
        speakers[((rank % speakers.count) + speakers.count) % speakers.count]
    }
}
