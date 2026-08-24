import Foundation
import StenoPipeline

/// Localizes only the fixed presentation vocabulary identified by the shared
/// speaker presentation resolver. Person names, imported labels, and opaque
/// cluster identifiers remain verbatim.
enum SpeakerDisplayLocalization {
    static func label(
        _ presentation: SpeakerPresentation,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let raw = presentation.label else { return nil }
        switch presentation.labelKind {
        case .verbatim:
            return raw
        case .me:
            return localized("Me", locale: locale)
        case .others:
            return localized("Others", locale: locale)
        case .unknown:
            return localized("Unknown speaker", locale: locale)
        case .namedPerson:
            return localized("Named person", locale: locale)
        case .multiplePeople:
            return localized("Multiple people", locale: locale)
        case .probablePerson(let name):
            return localized("Probably \(name)", locale: locale)
        case .generic(let number, let identifier, let source):
            if let number {
                switch source {
                case .none:
                    return localized("Speaker \(number)", locale: locale)
                case .microphone:
                    return localized("Speaker \(number) (microphone)", locale: locale)
                case .system:
                    return localized("Speaker \(number) (system)", locale: locale)
                }
            }
            switch source {
            case .none:
                return identifier
            case .microphone:
                return "\(identifier) (\(localized("Microphone", locale: locale)))"
            case .system:
                return "\(identifier) (\(localized("System audio", locale: locale)))"
            }
        }
    }

    static func originCue(
        _ presentation: SpeakerPresentation,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let cue = presentation.originCue else { return nil }
        guard cue == "Imported text label - not a locally confirmed identity" else {
            return cue
        }
        return localized(
            "Imported text label - not a locally confirmed identity",
            locale: locale
        )
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
