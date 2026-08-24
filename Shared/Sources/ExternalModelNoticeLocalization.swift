import Foundation
import StenoIntelligence

/// Localizes the user-facing copy around the shared, policy-checked outbound
/// disclosure without changing which data classes the core reports.
struct LocalizedExternalModelNotice {
    let text: String
    let isPlaintext: Bool

    static func make(
        endpoint: TextModelEndpoint,
        disclosure: OutboundDisclosure,
        localDeviceDescription: String,
        locale: Locale = .autoupdatingCurrent
    ) throws -> Self {
        let policyNotice = try ExternalModelNotice(
            endpoint: endpoint,
            disclosure: disclosure,
            localDeviceDescription: localDeviceDescription
        )
        let destination = endpoint.baseURL.host()
            ?? localized("unknown host", locale: locale)
        let content = localizedList(
            disclosure.classes.map { localized($0, locale: locale) },
            locale: locale
        )
        var text = localized(
            "Generating sends \(content) to “\(endpoint.name)” (\(destination)). Audio, structured profile email fields, and attachments are not added to the model input. Email addresses written into the meeting text or the notes are included with it.",
            locale: locale
        )
        if policyNotice.isPlaintext {
            text += " " + localized("This connection is not encrypted.", locale: locale)
        }
        return Self(text: text, isPlaintext: policyNotice.isPlaintext)
    }

    private static func localized(
        _ dataClass: PromptDataClass,
        locale: Locale
    ) -> String {
        switch dataClass {
        case .transcriptWithSpeakerNames:
            localized("transcript with speaker names", locale: locale)
        case .participants:
            localized("participants", locale: locale)
        case .userNotes:
            localized("your notes", locale: locale)
        }
    }

    private static func localizedList(_ values: [String], locale: Locale) -> String {
        guard !values.isEmpty else {
            return localized("no meeting content", locale: locale)
        }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }

    private static func localized(
        _ resource: LocalizedStringResource,
        locale: Locale
    ) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}
