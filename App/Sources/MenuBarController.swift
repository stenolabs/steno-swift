import AppKit
import os

/// Owns the NSStatusItem menu bar entry (plain AppKit, not SwiftUI
/// MenuBarExtra) so it can be installed from non-declarative app startup
/// code. The status item is retained for the controller's lifetime and
/// removed from the status bar on deinit.
///
/// The controller stays useful while the Dock icon is hidden
/// (`DockAppearance.setDockIconHidden(true)`): "Open Steno" reactivates the
/// app and brings the main window forward even in `.accessory` mode.
@MainActor
final class MenuBarController {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.steno",
        category: "menuBar"
    )

    private var statusItem: NSStatusItem?

    /// Called when the user chooses Start/Stop Recording. The handler must
    /// route through the same AppModel start/stop path as Cmd+R / Cmd+.
    var onToggleRecording: () -> Void = {}

    /// Called when the user chooses Open Steno.
    var onOpenMainWindow: () -> Void = {}

    init() {}

    /// Releases the status item. Swift 6 forbids touching actor-isolated
    /// state from a nonisolated deinit, so removal is explicit on the main
    /// actor; the app keeps one controller for its whole lifetime.
    func invalidate() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Installs the status item into the system status bar. Safe to call
    /// repeatedly; a second call is a no-op while one is already installed.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Template rendering lets the symbol adapt to menu bar tinting.
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Steno")
            image?.isTemplate = true
            button.image = image
        }
        item.menu = buildMenu(state: currentState)
        statusItem = item
        logger.debug("Menu bar item installed")
    }

    /// Last state passed to `refresh`; drives the menu rebuild.
    private var currentState = MenuBarController.initialState {
        didSet {
            if let item = statusItem { item.menu = buildMenu(state: currentState) }
        }
    }

    private static let initialState = StenoCommandState(
        hasRuntime: false,
        isRecording: false,
        isStartingRecording: false,
        isResolvingRecordingPermissions: false
    )

    /// Rebuilds the menu so labels and enabled state reflect `state`.
    func refresh(state: StenoCommandState) {
        currentState = state
    }
    // MARK: - Menu construction

    private func buildMenu(state: StenoCommandState) -> NSMenu {
        let menu = NSMenu()

        let recordingTitle = state.canStopRecording ? "Stop Recording" : "Start Recording"
        let recordingItem = NSMenuItem(
            title: recordingTitle,
            action: #selector(toggleRecording(_:)),
            keyEquivalent: ""
        )
        recordingItem.target = self
        // Start requires canStartRecording; Stop requires canStopRecording.
        recordingItem.isEnabled = state.canStartRecording || state.canStopRecording
        menu.addItem(recordingItem)

        let openItem = NSMenuItem(
            title: "Open Steno",
            action: #selector(openMainWindow(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let dockTitle = DockAppearance.isDockIconHidden ? "Show Dock Icon" : "Hide Dock Icon"
        let dockItem = NSMenuItem(
            title: dockTitle,
            action: #selector(toggleDockIcon(_:)),
            keyEquivalent: ""
        )
        dockItem.target = self
        menu.addItem(dockItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Steno",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        menu.autoenablesItems = false
        return menu
    }

    // MARK: - Actions

    @objc private func toggleRecording(_ sender: NSMenuItem) {
        logger.log("Toggle recording requested from menu bar")
        onToggleRecording()
    }

    @objc private func openMainWindow(_ sender: NSMenuItem) {
        logger.log("Open main window requested from menu bar")
        onOpenMainWindow()
    }

    @objc private func toggleDockIcon(_ sender: NSMenuItem) {
        let hidden = !DockAppearance.isDockIconHidden
        DockAppearance.setDockIconHidden(hidden)
        logger.log("Dock icon \(hidden ? "hidden" : "shown", privacy: .public) from menu bar")
        // Rebuild so the dock toggle label flips.
        if let item = statusItem { item.menu = buildMenu(state: currentState) }
    }

}
