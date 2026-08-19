import Foundation

/// Heruntergeladene Modellbytes weichen von den freigegebenen ab.
///
/// Ein eigener Typ, weil die Oberflaeche diesen Fall von einem gewoehnlichen
/// Downloadfehler unterscheiden **muss**: nur hier liegen alle Dateien
/// vollstaendig vor und sind trotzdem nicht brauchbar. Genau dann meldet
/// `readiness` faelschlich Bereitschaft, denn es prueft die Existenz, nicht
/// den Inhalt.
///
/// Ohne die Unterscheidung waere die naheliegende Regel "bereit **und**
/// gescheitert heisst Pruefsummenfehler" falsch: `DownloadUtils.downloadRepo`
/// fragt zuerst die Dateiliste von HuggingFace ab und ueberspringt vorhandene
/// Dateien erst danach. Wer offline auf "Allow and install" klickt, obwohl
/// alles installiert ist, scheitert deshalb am Listing, lange bevor eine
/// Pruefsumme berechnet wird.
///
/// Er liegt in StenoDomain, weil die App-Schicht ihn abfangen muss und
/// StenoDiarization nicht einbindet.
public enum ModelIntegrityError: Error, Equatable, LocalizedError, Sendable {
    /// Der relative Pfad, die erwartete und die vorgefundene Pruefsumme.
    case bytesDoNotMatch(file: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .bytesDoNotMatch(let file, let expected, let actual):
            return "Checksum mismatch for \(file). Expected \(expected), got \(actual)."
        }
    }
}
