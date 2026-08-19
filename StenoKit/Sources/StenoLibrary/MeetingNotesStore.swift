import Foundation
import StenoDomain

public protocol MeetingNotesPersistence: Sendable {
    func notes(_ meetingID: MeetingID) async throws -> String?
    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws
}

/// Notizen, die der Benutzer zu einem Meeting schreibt: Kontext vor der
/// Aufnahme, Mitschriebe währenddessen, Nachträge danach.
///
/// Bewusst eine schlichte Datei und keine Revisions-Entität. Revisionen
/// schützen Benutzerarbeit davor, von einem Maschinenlauf überschrieben zu
/// werden; in die Notiz schreibt ausschließlich der Mensch, und zwar aus genau
/// einem Fenster. Ein Revisionsbaum brächte hier nur Zeremonie.
public actor MeetingNotesStore {
    public nonisolated let layout: LibraryLayout

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    /// Die aktuelle Notiz, oder `nil`, wenn es keine gibt.
    ///
    /// Solange der Benutzer ein importiertes Alt-Meeting noch nicht selbst
    /// bearbeitet hat, liefert der Lesepfad die Alt-Notiz. Sonst wäre sie im
    /// Fenster unsichtbar, obwohl sie in der Bibliothek liegt.
    public func notes(_ meetingID: MeetingID) throws -> String? {
        if let own = try Self.read(layout.userNotes(meetingID)) {
            return own
        }
        return try Self.read(layout.legacyUserNotes(meetingID))
    }

    package nonisolated func notes(
        _ meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> String? {
        try transaction.validate(layout: layout)
        if let own = try Self.read(layout.userNotes(meetingID)) {
            return own
        }
        return try Self.read(layout.legacyUserNotes(meetingID))
    }

    /// Schreibt die Notiz atomar (Temp-Datei plus Rename). Eine leere oder nur
    /// aus Leerraum bestehende Notiz löscht die Datei, damit "keine Notiz" ein
    /// Zustand bleibt und nicht als leere Datei herumliegt.
    ///
    /// Die Alt-Notiz bleibt dabei unangetastet: Sie ist importiertes Material
    /// und behält ihre eigene Datei.
    public func setNotes(_ meetingID: MeetingID, to notes: String?) throws {
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            let destination = layout.userNotes(meetingID)
            let isBlank = notes?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true

            guard let notes, !isBlank else {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                return
            }

            try FileManager.default.createDirectory(
                at: layout.notesDirectory(meetingID),
                withIntermediateDirectories: true
            )
            try AtomicFile.write(Data(notes.utf8), to: destination)
        }
    }

    private nonisolated static func read(_ url: URL) throws -> String? {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile
            || error.code == .fileReadNoSuchFile
        {
            return nil
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

extension MeetingNotesStore: MeetingNotesPersistence {}
