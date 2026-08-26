import Foundation

/// Deep links for automation (macOS Shortcuts), mirroring the legacy
/// stenoai:// protocol:
///
/// - `steno://record/start?name=...` and `stenoai://record/start?name=...`
/// - `steno://record/stop` and `stenoai://record/stop`
enum DeepLink: Equatable {
    case startRecording(title: String?)
    case stopRecording
}

enum DeepLinkRouter {
    /// Parses a deep link URL into a `DeepLink`. Pure function; returns nil
    /// for anything that is not a recognized record start/stop link.
    static func parse(_ url: URL) -> DeepLink? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "steno" || scheme == "stenoai" else { return nil }
        guard url.host?.lowercased() == "record" else { return nil }

        switch url.path {
        case "/start":
            let raw = url.queryItems["name"] ?? ""
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return .startRecording(title: title.isEmpty ? nil : title)
        case "/stop":
            return .stopRecording
        default:
            return nil
        }
    }
}

private extension URL {
    /// Percent-decoded query parameters of the URL.
    var queryItems: [String: String] {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let query = components.queryItems else { return [:] }
        var result: [String: String] = [:]
        for item in query where item.value != nil {
            result[item.name] = item.value
        }
        return result
    }
}
