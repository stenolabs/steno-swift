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
    /// Optional sidebar color token. Absent means untinted; documents
    /// written before this field existed also decode as nil.
    public var colorToken: FolderColorToken?
    /// Optional SF Symbol from the curated allowlist. nil means the
    /// default folder symbol.
    public var icon: FolderIcon?

    public init(
        id: FolderID = FolderID(),
        name: String,
        parentFolderID: FolderID? = nil,
        sortIndex: Int,
        createdAt: Date = Date(),
        colorToken: FolderColorToken? = nil,
        icon: FolderIcon? = nil
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.colorToken = colorToken
        self.icon = icon
    }
}

/// Fixed eight-color palette for sidebar folders. The concrete color values
/// live in the UI layer; only the stable token is persisted so appearance
/// changes never touch storage. Decoding an unknown token fails on purpose:
/// silently dropping it would hide a permanently diverging folder look.
public enum FolderColorToken: String, CaseIterable, Sendable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
}

extension FolderColorToken: Codable {
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let token = FolderColorToken(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown folder color token: \(rawValue)"
            ))
        }
        self = token
    }
}

/// Curated SF Symbol allowlist for folders. The raw values are directly
/// valid SF Symbol names; an unknown value aborts decoding instead of
/// silently falling back to the default folder icon.
public enum FolderIcon: String, CaseIterable, Sendable {
    case folder
    case briefcase
    case people = "person.2"
    case chart = "chart.bar"
    case target
    case calendar
    case phone
    case video
    case document = "doc.text"
    case bookmark
    case microphone = "mic"
    case education = "graduationcap"
}

extension FolderIcon: Codable {
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let icon = FolderIcon(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown folder icon: \(rawValue)"
            ))
        }
        self = icon
    }
}

