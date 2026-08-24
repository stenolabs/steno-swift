import Foundation

/// Keeps the persisted demo engine identifier stable while presenting its one
/// fixed bundled display name in the app's language.
enum DemoDisplayLocalization {
    static func engineName(
        _ raw: String,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard raw == "Synthetic Demo" else { return raw }
        var resource: LocalizedStringResource = "Synthetic Demo"
        resource.locale = locale
        return String(localized: resource)
    }
}
