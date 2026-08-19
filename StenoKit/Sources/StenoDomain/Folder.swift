import Foundation

/// Ein Ordner der Bibliothek. Ein Hauptordner hat keine Elternkennung, ein
/// Unterordner verweist auf genau einen Hauptordner. Tiefere Ebenen verhindert
/// der persistente Store.
///
/// Ein Meeting gehoert in genau einen Ordner. Mehrfachzuordnung waere im
/// Datenmodell billig, wuerde in einer Sidebar aber dieselbe Meeting-Kennung
/// mehrfach in derselben Liste erzeugen und damit die Auswahl zerlegen.
public struct Folder: Codable, Equatable, Identifiable, Sendable {
    public let id: FolderID
    public var name: String
    public var parentFolderID: FolderID?
    /// Reihenfolge in der Sidebar. Der Benutzer sortiert nach Wichtigkeit,
    /// nicht nach Alphabet. Der Index gilt innerhalb der Geschwistergruppe.
    public var sortIndex: Int
    public let createdAt: Date

    public init(
        id: FolderID = FolderID(),
        name: String,
        parentFolderID: FolderID? = nil,
        sortIndex: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
