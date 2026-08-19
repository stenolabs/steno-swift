import Foundation
import StenoDomain

/// Uebernimmt die Ordnernamen, die der Steno-Altimport an den Meetings
/// hinterlassen hat, einmalig in echte Ordner.
///
/// Warum ueberhaupt: der Import ist laengst gelaufen und hat die Namen nur in
/// `metadata.legacyFolders` abgelegt, weil es damals keine Ordner gab. Ohne
/// diesen Schritt muesste jeder importierte Ordner von Hand nachgebaut werden.
///
/// Warum einmalig: es ist eine Uebernahme, keine laufende Spiegelung. Wer ein
/// importiertes Meeting bewusst aus seinem Ordner nimmt, soll es beim naechsten
/// Start nicht wieder darin finden.
public enum LegacyFolderAdoption {
    /// Liefert die Zahl der einsortierten Meetings. Null heisst entweder "schon
    /// gelaufen" oder "nichts zu tun" - beides ist derselbe Nichtzustand.
    @discardableResult
    public static func run(
        library: Library,
        folders: FolderStore
    ) async throws -> Int {
        let meetings = try await library.listMeetings()
        let assignments = try await folders.adoptLegacyFolders(from: meetings)
        var filed = 0
        for (meetingID, folderID) in assignments {
            // Einzeln fehlschlagen lassen: ein Meeting, das gerade geloescht
            // wird, darf die Uebernahme der anderen nicht verhindern.
            guard (try? await library.setMeetingFolder(
                meetingID,
                folderID: folderID
            )) != nil else { continue }
            filed += 1
        }
        // Erst jetzt abhaken. Blieb etwas liegen, versucht es der naechste
        // Start erneut - bereits einsortierte Meetings ruehrt er nicht an,
        // weil die Uebernahme nur Meetings ohne Ordner ansieht.
        if filed == assignments.count {
            try await folders.markLegacyFoldersAdopted()
        }
        return filed
    }
}
