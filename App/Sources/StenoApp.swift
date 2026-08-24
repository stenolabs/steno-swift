import SwiftUI

@main
struct StenoApp: App {
    @State private var model = AppModel()
    @State private var textModelSettings = TextModelSettings()
    @State private var operatorProfile = OperatorProfile.shared
    @State private var onboarding = OnboardingModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Meetings", id: "main") {
            ContentView()
                .environment(model)
                .environment(textModelSettings)
                .environment(operatorProfile)
                .environment(onboarding)
                .task {
                    // Vor `bootstrap`, damit der erste Start nicht erst die
                    // Bibliothek oeffnet und dann den Wizard nachschiebt.
                    if !onboarding.isFinished { openWindow(id: "onboarding") }
                    // Beim Start nur vorhandene TCC-Entscheidungen lesen.
                    // Anfordern darf erst der erklaerende Wizard oder der
                    // ausdrueckliche erste Aufnahmeversuch.
                    model.refreshRecordingPermissionStatus()
                    await model.bootstrap()
                }
        }
        // Drei Spalten: Seitenleiste, Transkript, Inspector. Bei 980 pt
        // blieben dem Transkript keine 500 pt.
        .defaultSize(width: 1240, height: 780)
        .commands {
            StenoCommands(
                model: model,
                openLegacyImport: {
                    openWindow(id: "legacy-import")
                },
                openSetupAssistant: {
                    onboarding.reopen()
                    openWindow(id: "onboarding")
                }
            )
            ToolbarCommands()
        }

        Window("Import from Legacy Steno App", id: "legacy-import") {
            LegacyImportView()
                .environment(model)
        }
        .defaultSize(width: 600, height: 480)

        Window("Welcome to Steno", id: "onboarding") {
            OnboardingView()
                .environment(model)
                .environment(onboarding)
                .environment(operatorProfile)
        }
        .defaultSize(width: 620, height: 480)

        Settings {
            SettingsView()
                .environment(model)
                .environment(textModelSettings)
                .environment(operatorProfile)
        }
    }
}
