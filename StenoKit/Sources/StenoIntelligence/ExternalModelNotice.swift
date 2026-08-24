import Foundation

public struct ExternalModelNotice: Equatable, Sendable {
    public let text: String
    public let isPlaintext: Bool

    public init(
        endpoint: TextModelEndpoint,
        disclosure: OutboundDisclosure,
        localDeviceDescription: String
    ) throws {
        let transport = try TextModelEndpointPolicy.transportSecurity(
            for: endpoint.baseURL
        )
        let destination = endpoint.baseURL.host() ?? "unknown host"
        let content = Self.list(disclosure.classes.map(\.displayName))
        // Der feste Satzteil darf keine der Datenklassen-Bezeichnungen woertlich
        // enthalten. Sonst zaehlt der Hinweis eine Klasse mit, die gar nicht
        // mitgeschickt wird, und die Zusicherung "nennt genau die ausgehenden
        // Klassen" stimmt nicht mehr.
        var text = "Generating sends \(content) to \u{201C}\(endpoint.name)\u{201D} "
            + "(\(destination)). Audio, structured profile email fields, and attachments "
            + "are not added to the model input. Email addresses written into the meeting "
            + "text or the notes are included with it."
        if transport == .localPlaintext {
            text += " This connection is not encrypted."
        }
        self.text = text
        isPlaintext = transport == .localPlaintext
    }

    private static func list(_ values: [String]) -> String {
        switch values.count {
        case 0:
            "no meeting content"
        case 1:
            values[0]
        case 2:
            "\(values[0]) and \(values[1])"
        default:
            values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }
}
