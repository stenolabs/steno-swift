import Foundation

/// Resolves the meeting-library location and validates user-chosen paths.
///
/// Resolution order (highest priority first):
/// 1. `STENO_LIBRARY_DIR` environment override (developer/test escape hatch;
///    deliberately wins over everything so isolation setups always work).
/// 2. The `steno.library.customPath` user setting (absent = standard
///    location).
/// 3. The standard location: `Application Support/Steno/Library`.
///
/// Contract: a custom path applies on the NEXT launch. The running app keeps
/// the library it opened at startup and never switches mid-session. Moving an
/// existing library to the new location is a manual user step performed while
/// the app is closed. This is a deliberate divergence from the legacy
/// stenoai `storage_path` behaviour, which relocated recordings, transcripts
/// and output automatically: this app never performs silent bulk copies of
/// irreplaceable originals in the background.
enum StorageLocation {
    /// UserDefaults key holding the user's custom library directory.
    static let customPathDefaultsKey = "steno.library.customPath"

    /// Environment variable overriding every other resolution step.
    static let environmentOverrideKey = "STENO_LIBRARY_DIR"

    /// The stored custom path, or nil when unset/blank. Blank counts as
    /// unset so clearing can be expressed either way.
    static func customPath(defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: customPathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    /// Stores or clears the custom path. A blank/nil value removes the key
    /// entirely so "absent = standard location" stays the single source of
    /// truth for the default reading.
    static func setCustomPath(_ path: String?, defaults: UserDefaults) {
        let trimmed = path?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: customPathDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: customPathDefaultsKey)
        }
    }

    /// The built-in location used when neither the environment nor the user
    /// setting overrides it.
    static func standardLibraryDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent("Steno/Library", isDirectory: true)
    }

    /// Single entry point the app startup wires into: resolves the library
    /// root from environment override, then user setting, then the standard
    /// location.
    static func effectiveLibraryDirectory(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[environmentOverrideKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        if let custom = customPath(defaults: defaults) {
            return URL(
                fileURLWithPath: (custom as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return standardLibraryDirectory(fileManager: fileManager)
    }

    // MARK: - Validation

    enum ValidationFailure: Error, Equatable {
        case notAbsolute(path: String)
        case notADirectory(path: String)
        case notCreatable(path: String)
        case notWritable(path: String)
        case insideAppBundle(path: String)

        /// Inline error text surfaced next to the settings rows.
        var message: String {
            switch self {
            case .notAbsolute(let path):
                return "\(path) is not an absolute folder path."
            case .notADirectory(let path):
                return "\(path) is a file, not a folder."
            case .notCreatable(let path):
                return "\(path) does not exist and could not be created."
            case .notWritable(let path):
                return "Steno does not have permission to write to \(path)."
            case .insideAppBundle(let path):
                return "\(path) is inside the app bundle, where data would be lost on update."
            }
        }
    }

    /// Validates a candidate custom library directory: it must be absolute,
    /// exist or be creatable, be writable, and must not sit inside the app
    /// bundle. Returns nil when acceptable. A missing directory is created
    /// here so the check doubles as proof of writability (mirrors the legacy
    /// config behaviour of initialising subdirectories up front).
    static func validate(
        path input: String,
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> ValidationFailure? {
        let expanded = (input as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .notAbsolute(path: input)
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return .notADirectory(path: url.path)
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            } catch {
                return .notCreatable(path: url.path)
            }
        }

        guard fileManager.isWritableFile(atPath: url.path) else {
            return .notWritable(path: url.path)
        }

        if isInsideBundle(
            path: url.standardizedFileURL.path,
            bundlePath: bundleURL.standardizedFileURL.path
        ) {
            return .insideAppBundle(path: url.standardizedFileURL.path)
        }
        return nil
    }

    /// Prefix containment on standardized paths decides bundle membership;
    /// the trailing slash keeps `/tmp/Foo.app2` distinct from `/Foo.app`.
    static func isInsideBundle(path: String, bundlePath: String) -> Bool {
        guard !bundlePath.isEmpty, path != "/" else { return false }
        return path == bundlePath || path.hasPrefix(bundlePath + "/")
    }
}
