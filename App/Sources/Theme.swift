import StenoDomain
import StenoPipeline
import SwiftUI

/// Die einzige Stelle, die Farbnamen und Masse kennt.
///
/// Die Flaeche bleibt Systemmaterial; Farbe traegt nur dort Bedeutung, wo es
/// etwas zu bedeuten gibt: Aufnahme, Zustand, Sprecher. Semantische Rollen
/// laufen ueber Systemfarben, weil die Hell/Dunkel und Vibrancy selbst
/// beherrschen.
enum Steno {
    enum Colors {
        /// Markenfarbe, unabhaengig von der Akzentfarbe des Benutzers. Wer
        /// systemweit eine eigene Akzentfarbe erzwungen hat, soll sie in den
        /// Bedienelementen behalten - diese Farbe ist fuer Stellen, die Steno
        /// selbst kennzeichnen.
        static let brand = Color("StenoBrand")

        static let recording = Color(nsColor: .systemRed)
        static let running = Color("StenoBrand")
        static let confirmed = Color(nsColor: .systemGreen)
        /// Unsicher, vorlaeufig, unterbrochen. Nie fuer echte Fehler.
        static let uncertain = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)

        /// Acht gedeckte Toene, absichtlich keine Signalfarben. Sie erscheinen
        /// nur als kleiner Marker neben einem Namen, nie als Flaeche und nie
        /// als Textfarbe - Farbe traegt hier keine Information allein.
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
    /// 13 pt war im Nutzungstest zu klein; Transkript und Protokoll teilen sich die Groesse.
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

    /// Farbe einer Person, stabil ueber Meetings und App-Starts hinweg.
    ///
    /// Bewusst ein eigener FNV-1a ueber die UUID-Bytes statt `Hasher`: Swifts
    /// Standard-Hashing ist pro Prozess zufaellig gesalzen, die Farbe wechselte
    /// sonst bei jedem Start.
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

    /// Farbe eines noch unbestaetigten Clusters, aus seiner Position in der
    /// nach Sprechzeit sortierten Liste. Nach einer neuen Diarisierung darf
    /// sie sich aendern - dann sind es auch andere Cluster.
    static func speaker(atRank rank: Int) -> Color {
        speakers[((rank % speakers.count) + speakers.count) % speakers.count]
    }
}
