import Darwin
import Foundation
import StenoExchange

enum LibraryBackupPolicy {
    static func prepareAndVerify(libraryRoot: URL, validationRoot: URL) throws {
        try FileManager.default.createDirectory(
            at: libraryRoot,
            withIntermediateDirectories: true
        )

        let privateValidationRoot: MeetingTransferPrivateRoot
        do {
            privateValidationRoot = try MeetingTransferPrivateRoot.prepareAndVerify(
                at: validationRoot
            )
        } catch {
            throw LibraryBackupPolicyError.privateValidationRootRejected(validationRoot)
        }
        var validationStatus = stat()
        guard lstat(validationRoot.path, &validationStatus) == 0,
              validationStatus.st_mode & S_IFMT == S_IFDIR,
              validationStatus.st_uid == geteuid(),
              validationStatus.st_mode & 0o7777 == 0o700
        else {
            throw LibraryBackupPolicyError.privateValidationRootRejected(validationRoot)
        }

        for root in [libraryRoot, validationRoot] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try mutableRoot.setResourceValues(values)

            let stored = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
            guard stored.isExcludedFromBackup == true else {
                throw LibraryBackupPolicyError.exclusionNotPersisted(root)
            }
        }

        withExtendedLifetime(privateValidationRoot) {}
    }
}

enum LibraryBackupPolicyError: LocalizedError, Equatable {
    case privateValidationRootRejected(URL)
    case exclusionNotPersisted(URL)

    var errorDescription: String? {
        switch self {
        case .privateValidationRootRejected:
            String(localized: "Steno could not secure its private transfer validation directory.")
        case .exclusionNotPersisted:
            String(localized: "Steno could not exclude its local library from device backup.")
        }
    }
}
