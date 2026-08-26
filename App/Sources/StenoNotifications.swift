import Foundation
import os
import UserNotifications

/// Kinds of user-facing local notifications, mirroring stenoai's
/// completionNotification surface. The raw value doubles as the identifier
/// segment, so updates for the same kind and meeting coalesce: posting again
/// replaces the previous notification instead of stacking a duplicate.
enum StenoNotificationKind: String {
    case noteReady
    case transcriptReady
    case processingFailed
    case meetingDetected

    /// Body wording for each kind. Bodies carry status text only; meeting
    /// content never appears here. The meeting TITLE travels separately in
    /// the notification title.
    var bodyText: String {
        switch self {
        case .noteReady:
            String(localized: "Your note is ready.")
        case .transcriptReady:
            String(localized: "Your transcript is ready.")
        case .processingFailed:
            String(localized: "Processing failed.")
        case .meetingDetected:
            String(localized: "A meeting appears to be running nearby.")
        }
    }
}

/// Thin wrapper around UNUserNotificationCenter for pipeline notifications.
///
/// Authorization (.alert, .sound) is requested lazily at the first post so a
/// fresh install never prompts before it has something to say. Posts are
/// gated by the `steno.notifications.enabled` UserDefaults key (default on).
/// Notification bodies contain only fixed status wording plus the meeting
/// title in the title slot - never transcript or note content.
@MainActor
final class StenoNotifications {
    static let shared = StenoNotifications()

    /// UserDefaults key mirroring the existing `steno.*` settings style.
    /// Absent value counts as enabled so the feature is on by default.
    private static let enabledKey = "steno.notifications.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Stable notification identifier: updates coalesce per kind and meeting.
    static func identifier(kind: StenoNotificationKind, meetingID: String) -> String {
        "steno.\(kind.rawValue).\(meetingID)"
    }

    enum AuthorizationState {
        case notRequested
        case granted
        case denied
    }

    private let center: UNUserNotificationCenter
    private var authorizationState: AuthorizationState = .notRequested

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Posts (or replaces) the notification for one kind and meeting.
    ///
    /// - Parameters:
    ///   - kind: which completion/failure/detection event to announce.
    ///   - meetingTitle: shown as the notification title; falls back to the
    ///     app name when unknown. Titles only - never transcript content.
    ///   - meetingID: stable string form of the meeting id used to coalesce
    ///     repeated posts under one identifier.
    func post(
        kind: StenoNotificationKind,
        meetingTitle: String?,
        meetingID: String
    ) async {
        guard Self.isEnabled else { return }
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        if let meetingTitle, !meetingTitle.isEmpty {
            content.title = meetingTitle
        } else {
            content.title = String(localized: "Steno")
        }
        content.body = kind.bodyText
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.identifier(kind: kind, meetingID: meetingID),
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            Logger.logger.debug("Posted \(kind.rawValue, privacy: .public) notification")
        } catch {
            Logger.logger.error(
                "Failed to add \(kind.rawValue, privacy: .public) notification: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Requests .alert/.sound authorization once, at the first real post.
    private func ensureAuthorized() async -> Bool {
        switch authorizationState {
        case .granted:
            return true
        case .denied:
            return false
        case .notRequested:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authorizationState = granted ? .granted : .denied
                if !granted {
                    Logger.logger.info("Notification authorization denied by user")
                }
                return granted
            } catch {
                Logger.logger.error(
                    "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
                )
                authorizationState = .denied
                return false
            }
        }
    }
}

private extension Logger {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.steno",
        category: "notifications"
    )
}
