import AppKit

/// Controls whether the app shows a regular Dock icon or runs as a
/// menu-bar-only (accessory) app. The choice is persisted so it survives
/// relaunches; the app entry point must call `applyPersistedPolicy()` during
/// startup before the first activation event.
@MainActor
enum DockAppearance {
    private static let dockIconHiddenKey = "steno.appearance.dockIconHidden"

    /// Whether the Dock icon is currently hidden (app runs as `.accessory`).
    static var isDockIconHidden: Bool {
        UserDefaults.standard.bool(forKey: dockIconHiddenKey)
    }

    /// Shows or hides the Dock icon and persists the choice.
    ///
    /// When the icon is hidden the app becomes an `.accessory` application:
    /// its windows are still reachable through the menu bar item's
    /// "Open Steno" command (`NSApp.activate` + window `makeKeyAndOrderFront`),
    /// which is why the menu bar controller must stay installed while the
    /// Dock icon is hidden.
    static func setDockIconHidden(_ hidden: Bool) {
        guard isDockIconHidden != hidden else { return }
        UserDefaults.standard.set(hidden, forKey: dockIconHiddenKey)
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
    }

    /// Applies the persisted choice at launch, before the user interacts.
    /// No-op when the stored value matches the default (icon visible).
    static func applyPersistedPolicy() {
        NSApp.setActivationPolicy(isDockIconHidden ? .accessory : .regular)
    }
}
