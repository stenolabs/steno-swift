import SwiftUI

/// Einstellungsfenster: Allgemein (Transkriptionssprache), Personen,
/// Sprachmodelle und Modelle (Zustimmung und Installation).
/// Erreichbar über das Zahnrad in der Toolbar und über Cmd-Komma.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PeopleSettingsView()
                .tabItem { Label("People", systemImage: "person.2") }
            TextModelSettingsView()
                .tabItem { Label("Language Models", systemImage: "brain") }
            ModelStatusView()
                .tabItem { Label("Models", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(OperatorProfile.self) private var profile

    var body: some View {
        @Bindable var profile = profile
        Form {
            TranscriptionLanguagePicker()
            Text("Applies to new recordings and imports.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Section("Recording microphone") {
                MicrophoneSelectionControls()
            }
            TextField("Your name", text: $profile.name)
            TextField("Organisation (optional)", text: $profile.organization)
            Text(OperatorProfile.fieldNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minHeight: 240)
    }
}

/// Der eine Auswahlkasten fuer die Transkriptionssprache. Einstellungen und
/// Wizard zeigen denselben, weil zwei Kopien auseinanderdriften: der Wechsel
/// startet die Pipeline neu, und das darf nicht an zwei Stellen verschieden
/// verdrahtet sein.
struct TranscriptionLanguagePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Transcription language", selection: Binding(
            get: { model.selectedLanguageID },
            set: { newValue in
                Task { await model.setLanguage(newValue) }
            }
        )) {
            ForEach(model.availableLocales, id: \.identifier) { locale in
                Text(model.localizedLanguageName(locale))
                    .tag(locale.identifier)
            }
        }
        .disabled(model.availableLocales.isEmpty)
    }
}
