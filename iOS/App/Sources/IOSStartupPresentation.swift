import Foundation

enum IOSStartupState: Equatable {
    case opening
    case ready
    case failed(IOSStartupFailure)

    var title: LocalizedStringResource {
        switch self {
        case .opening:
            "Opening library"
        case .ready:
            "Library ready"
        case .failed(let failure):
            failure.title
        }
    }
}

enum IOSStartupFailure: Equatable {
    case libraryProtection(String)
    case runtimeOpening(String)

    var title: LocalizedStringResource {
        switch self {
        case .libraryProtection:
            "The library could not be protected"
        case .runtimeOpening:
            "The library could not be opened"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .libraryProtection(let detail):
            "Steno could not verify the local library before opening it. \(detail)"
        case .runtimeOpening(let detail):
            "Steno could not open the local library. \(detail)"
        }
    }

    var compatibilityMessage: String {
        switch self {
        case .libraryProtection(let detail), .runtimeOpening(let detail):
            detail
        }
    }
}

enum IOSLibraryIssue: Equatable, Identifiable {
    case meetings(String)
    case folders(String)

    enum ID: Hashable {
        case meetings
        case folders
    }

    var id: ID {
        switch self {
        case .meetings:
            .meetings
        case .folders:
            .folders
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .meetings:
            "Meetings unavailable"
        case .folders:
            "Folders unavailable"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .meetings(let detail):
            "The meeting list could not be loaded. Recording remains available. \(detail)"
        case .folders(let detail):
            "The folder list could not be loaded. Meetings and recording remain available. \(detail)"
        }
    }

    var retryTitle: LocalizedStringResource {
        switch self {
        case .meetings:
            "Reload Meetings"
        case .folders:
            "Reload Folders"
        }
    }

    var compatibilityMessage: String {
        switch self {
        case .meetings(let detail), .folders(let detail):
            detail
        }
    }
}

enum IOSStartupWarning: Equatable {
    case captureRecovery(String)
    case missingModelRequeue(String)
    case pipeline(String)

    var message: LocalizedStringResource {
        switch self {
        case .captureRecovery(let detail):
            "Some interrupted recordings need attention. \(detail)"
        case .missingModelRequeue(let detail):
            "Some model-dependent work could not be queued again. \(detail)"
        case .pipeline(let detail):
            "Some background processing could not be resumed. \(detail)"
        }
    }

    var compatibilityMessage: String {
        switch self {
        case .captureRecovery(let detail),
             .missingModelRequeue(let detail),
             .pipeline(let detail):
            detail
        }
    }
}

enum IOSActionNotice: Equatable {
    case appleRetryQueue(String)
    case draftCreation(String)
    case folderMutation(String)
    case folderStateReload(String)
    case partialRecovery(String)

    var title: LocalizedStringResource {
        switch self {
        case .appleRetryQueue:
            "Retry not queued"
        case .draftCreation:
            "Draft not created"
        case .folderMutation:
            "Folder action failed"
        case .folderStateReload:
            "Folder state refreshed"
        case .partialRecovery:
            "Folder recovery incomplete"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .appleRetryQueue(let detail):
            "The Apple transcription retry could not be queued. \(detail)"
        case .draftCreation(let detail):
            "The draft could not be created. \(detail)"
        case .folderMutation(let detail):
            "The folder action could not be completed. \(detail)"
        case .folderStateReload(let detail):
            "The current folder state was reloaded. \(detail)"
        case .partialRecovery(let detail):
            "The folder action could only be recovered in part. \(detail)"
        }
    }

    var compatibilityMessage: String {
        switch self {
        case .appleRetryQueue(let detail):
            String(localized: "The Apple retry could not be queued: \(detail)")
        case .draftCreation(let detail):
            String(localized: "The draft could not be created. (\(detail))")
        case .folderMutation(let detail),
             .folderStateReload(let detail),
             .partialRecovery(let detail):
            detail
        }
    }
}
