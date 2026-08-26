import AppKit
import Carbon.HIToolbox
import os

/// Registers the system-wide record toggle hotkey (Command+Shift+R), matching
/// stenoai's global `CommandOrControl+Shift+R` accelerator.
///
/// The hotkey is registered through Carbon's `RegisterEventHotKey`, which fires
/// regardless of which app is frontmost. When Steno itself is active, in-app
/// keyboard shortcuts already handle the toggle, so the callback is suppressed
/// while `NSApp.isActive`: otherwise the Carbon event and the SwiftUI keyboard
/// shortcut would each fire for one key press, toggling recording twice.
/// 'stno' — process-local signature distinguishing our hot key from any other.
/// File-scope `let` so the nonisolated Carbon event-handler trampoline can read it.
private let hotKeySignature: FourCharCode = 0x7374_6E6F
/// Event id for the single registered record hotkey; read from the
/// nonisolated Carbon trampoline, hence a file-scope constant.
private let hotKeyId: UInt32 = 1
@MainActor
final class GlobalRecordHotkey {
    private let onToggle: () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var didRetainSelf = false

    private static let keyCodeR: UInt32 = 15 // kVK_ANSI_R

    /// - Parameter onToggle: Invoked on the main queue when the user presses
    ///   Command+Shift+R while another app is frontmost.
    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            register()
        } else {
            unregister()
        }
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        installHandlerIfNeeded()

        var hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyId)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            Self.keyCodeR,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Logger.stenoHotkey.error("RegisterEventHotKey failed with status \(status, privacy: .public)")
            return
        }
        hotKeyRef = ref
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        // Retained for the handler's lifetime; released in deinit after the
        // handler is removed.
        var context = Unmanaged.passRetained(self).toOpaque()
        didRetainSelf = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                GlobalRecordHotkey.handleEvent(event: event, userData: userData)
            },
            1,
            &eventType,
            &context,
            &handlerRef
        )
        guard status == noErr, let handlerRef else {
            Unmanaged<AnyObject>.fromOpaque(context).release() // Balance passRetained.
            Logger.stenoHotkey.error("InstallEventHandler failed with status \(status, privacy: .public)")
            return
        }
        eventHandler = handlerRef
    }

    nonisolated private static func handleEvent(event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return status }
        guard hotKeyID.signature == hotKeySignature,
              hotKeyID.id == hotKeyId else {
            return OSStatus(eventNotHandledErr)
        }

        let hotkey = Unmanaged<GlobalRecordHotkey>.fromOpaque(userData).takeUnretainedValue()
        // Carbon delivers on the main thread; hop explicitly to be safe.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Suppress while Steno is active: the in-app Cmd+Shift+R shortcut
                // already toggles recording, so this event must not fire again.
                guard !NSApp.isActive else { return }
                hotkey.onToggle()
            }
        }
        return noErr
    }

    /// Releases the registration and the handler's retained self.
    ///
    /// Swift 6 forbids touching actor-isolated state from a nonisolated
    /// deinit, so cleanup is explicit: call this on the main actor before
    /// dropping the last reference. The app keeps one instance for its whole
    /// lifetime, which makes the requirement trivial to satisfy.
    func invalidate() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        if didRetainSelf {
            // Balance the passRetained in installHandlerIfNeeded.
            Unmanaged.passUnretained(self).release()
            didRetainSelf = false
        }
    }
}

private extension Logger {
    static let stenoHotkey = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.steno",
        category: "global-record-hotkey"
    )
}
