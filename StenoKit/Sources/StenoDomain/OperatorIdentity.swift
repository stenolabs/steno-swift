import Foundation

/// Wer dieses Steno bedient. Bewusst getrennt von der Frage, wer bei einem
/// Meeting ins Mikrofon gesprochen hat: beim Auftragstranskript und beim
/// geteilten Geraet fallen die beiden auseinander. Die Mikrofonbindung ist
/// ein eigenes Arbeitspaket.
public struct OperatorIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let organization: String

    public init(name: String, organization: String) {
        self.name = name
        self.organization = organization
    }

    /// Nil, wenn kein Name hinterlegt ist: ein Protokollkopf ohne Verfasser
    /// ist besser als einer mit leerem Feld.
    public var authorLine: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedOrganization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOrganization.isEmpty ? trimmedName : "\(trimmedName), \(trimmedOrganization)"
    }
}
