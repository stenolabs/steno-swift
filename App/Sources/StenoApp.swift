import SwiftUI

@main
struct StenoApp: App {
    @State private var model = AppModel()
    @State private var textModelSettings = TextModelSettings()
    @State private var operatorProfile = OperatorProfile.shared
    @State private var onboarding = OnboardingModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(textModelSettings)
                .environment(operatorProfile)
                .environment(onboarding)
                .task {
                    // Vor `bootstrap`, damit der erste Start nicht erst die
                    // Bibliothek oeffnet und dann den Wizard nachschiebt.
                    if !onboarding.isFinished { openWindow(id: "onboarding") }
                    // Beide TCC-Entscheidungen sind vor der ersten Aufnahme
                    // geklaert. Der invasive Systemaudio-Probelauf geschieht
                    // einmal pro Code-Signaturidentitaet; spaetere Starts mit
                    // derselben Identitaet verwenden den gespeicherten Status.
                    // Der Wizard kann bewusst erneut pruefen.
                    await model.resolveRecordingPermissions()
                    await model.bootstrap()
                }
        }
        // Drei Spalten: Seitenleiste, Transkript, Inspector. Bei 980 pt
        // blieben dem Transkript keine 500 pt.
        .defaultSize(width: 1240, height: 780)
        .commands {
            // Ohne Menueeintraege sind Aufnehmen und Importieren nur ueber die
            // Toolbar erreichbar - und damit auch nicht ueber die Hilfe-Suche
            // im Menue, die auf dem Mac zur Auffindbarkeit gehoert.
            CommandMenu("Recording") {
                Button("Start Recording") {
                    Task { await model.startRecording() }
                }
                .keyboardShortcut("r")
                .disabled(
                    model.runtime == nil
                        || model.isRecording
                        || model.isStartingRecording
                )

                // Bewusst NICHT auf Cmd-R: Das ist in jedem Browser
                // "neu laden". Ein Reflex in der falschen App beendete sonst
                // die laufende Aufnahme und zerrisse das Meeting in zwei
                // Haelften. Cmd-Punkt ist die Mac-Konvention fuer Abbrechen.
                Button("Stop Recording") {
                    Task { await model.stopRecording() }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isRecording)

                Divider()

                Button("Mark This Moment") {
                    Task { await model.markMoment() }
                }
                .keyboardShortcut("m")
                .disabled(!model.isRecording)
            }
            CommandGroup(after: .newItem) {
                Button("New Meeting") {
                    Task { await model.createDraftMeeting() }
                }
                .keyboardShortcut("n")
                .disabled(model.runtime == nil)
            }
            CommandGroup(after: .importExport) {
                Button("Import Audio File…") {
                    model.requestAudioImport()
                }
                .keyboardShortcut("i")
                .disabled(model.runtime == nil || model.isRecording)

                Button("Import from Legacy Steno App…") {
                    openWindow(id: "legacy-import")
                }
            }
            CommandGroup(replacing: .help) {
                // Der Wizard ist sonst einmalig: wer ihn beim ersten Start
                // weggeklickt hat, kaeme ohne diesen Eintrag nie mehr hin.
                Button("Show Setup Assistant") {
                    onboarding.reopen()
                    openWindow(id: "onboarding")
                }
            }
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
