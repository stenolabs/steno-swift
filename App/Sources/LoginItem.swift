import ServiceManagement

/// Launch-at-login registration backed by `SMAppService.mainApp` (macOS 13+).
///
/// Stateless by design: callers (the Settings toggle) invoke `setEnabled(_:)`
/// and read `registrationStatus()`; nothing is persisted here.
@MainActor
enum LoginItem {
    /// Registration state of the app's main-app login item.
    static func registrationStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Enables or disables launch-at-login.
    ///
    /// Idempotent: disabling an already-unregistered item succeeds. Enabling
    /// may return `.requiresApproval`, in which case this throws and the user
    /// must approve the item in System Settings > General > Login Items.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else {
            // Unregistering a never-registered item throws; treat as success.
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }

        if service.status == .requiresApproval {
            throw LoginItemError.requiresApproval
        }
    }
}

enum LoginItemError: LocalizedError, Equatable {
    case requiresApproval

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            String(
                localized: "Steno needs approval to launch at login. Enable it in System Settings > General > Login Items."
            )
        }
    }
}
