import Foundation

/// Where the library and the downloaded models live on iOS.
///
/// The Mac keeps its library in Application Support. On iOS it goes into
/// `Documents` instead, so the Files app can reach it: protecting originals
/// also means the user can get them out without Steno. The price is that the Files
/// app can damage the library too, which the existing validation, schema
/// versions and corrupt quarantine already handle.
enum LibraryLocation {
    static func libraryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["STENO_LIBRARY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        return documents.appendingPathComponent("StenoLibrary", isDirectory: true)
    }

    /// Cache directory for the CoreML models FluidAudio downloads.
    ///
    /// Deliberately not in `Documents`: these are hundreds of megabytes of
    /// reproducible model weights. They stay in the container, and they are
    /// excluded from iCloud backup so they never bloat a device backup. The
    /// unencrypted recording library is excluded separately during bootstrap
    /// until an encrypted backup is available.
    static func modelCacheURL(cachesDirectory: URL? = nil) throws -> URL {
        let caches = cachesDirectory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        var directory = caches.appendingPathComponent(
            "DiarizationModels",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)

        return directory
    }
}
