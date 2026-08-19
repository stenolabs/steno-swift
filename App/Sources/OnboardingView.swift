import StenoAudioCore
import StenoMacAudio
import StenoPipeline
import SwiftUI

/// Der Erstlauf-Wizard: einmal durch Profil, Sprache, Modelle und
/// Berechtigungen. Die Seitenfolge kommt aus `OnboardingFlow`, hier steht nur,
/// was auf welcher Seite zu sehen ist.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .onChange(of: onboarding.isFinished) { _, isFinished in
            if isFinished { dismiss() }
        }
        .onDisappear {
            // Wer das Fenster zumacht, statt durchzugehen, hat sich auch
            // entschieden. Ohne diese Zeile stuende der Wizard beim naechsten
            // Start wieder da, obwohl er weggeklickt wurde. Eine bereits
            // erteilte Zustimmung bleibt davon unberuehrt: ein angestossener
            // Download laeuft weiter, zurueckgenommen wird er nur ueber
            // "Revoke" in den Einstellungen.
            if !onboarding.isFinished { onboarding.abort() }
        }
    }

    // Bewusst kein `TabView`: dessen Reiterleiste waere hier sichtbar und
    // liesse durch die Seiten springen. Die Folge bestimmt allein `OnboardingFlow`.
    @ViewBuilder
    private var page: some View {
        switch onboarding.page {
        case .welcome:
            WelcomePage()
        case .profile:
            ProfilePage()
        case .language:
            LanguagePage()
        case .models:
            ModelsPage()
        case .permissions:
            PermissionsPage()
        }
    }

    private var footer: some View {
        HStack {
            // "Skip" bleibt immer offen: eine Seite, die niemanden weiterlaesst,
            // waere eine Sackgasse, wenn das Laden haengt.
            Button("Skip") { onboarding.skip() }
            Spacer()
            Button(onboarding.isLastPage ? "Done" : "Continue") {
                onboarding.advance()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .padding(16)
    }

    /// Weiter erst, wenn die Sprachliste da ist. Der naechste Schritt laedt
    /// die Sprachassets fuer die eingestellte Locale und reserviert sie; wer
    /// vorher weitergeht, laedt die Sprache, die zufaellig voreingestellt war.
    /// Kommt keine Sprache, gibt die Seite trotzdem den Weg frei: laenger zu
    /// warten braechte nichts.
    private var canContinue: Bool {
        onboarding.page != .language || model.hasLoadedLocales
    }
}

// MARK: - Seiten

private struct WelcomePage: View {
    var body: some View {
        Form {
            Section("Welcome to Steno") {
                Text("Steno records and transcribes conversations on this Mac. Your recordings stay here. Steno reaches the network for two things only: to download the models you approve in a moment, and to talk to an external language model if you pick one for a render.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProfilePage: View {
    @Environment(OperatorProfile.self) private var profile

    var body: some View {
        @Bindable var profile = profile
        Form {
            Section("Who is taking the minutes?") {
                TextField("Your name", text: $profile.name)
                TextField("Organisation (optional)", text: $profile.organization)
                Text("\(OperatorProfile.fieldNote) You can skip this and add it later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LanguagePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Transcription language") {
                // Der Wizard oeffnet vor `bootstrap`, die Liste kommt also
                // erst waehrend die Seite schon offen sein kann. Bis dahin
                // steht hier kein Satz, der eine Wahl behauptet.
                if !model.hasLoadedLocales {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Steno is still checking which languages this Mac can transcribe.")
                    }
                } else if model.availableLocales.isEmpty {
                    Text("This Mac reports no languages for transcription. Steno cannot transcribe until macOS offers one.")
                        .foregroundStyle(.secondary)
                } else {
                    TranscriptionLanguagePicker()
                    // Die Reihenfolge ist kein Zufall: der naechste Schritt
                    // laedt die Sprachassets fuer genau diese Locale und
                    // reserviert sie.
                    Text("Pick this before the next step: the speech models are downloaded for the language you choose here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Dieselbe Ansicht wie im Einstellungsregister "Models", nicht eine zweite
/// daneben: sonst driften Wortlaut und Verhalten der beiden Stellen
/// auseinander. Der Satz, dass Steno ohne Modelle gar nicht transkribieren
/// kann, steht dort bereits.
private struct ModelsPage: View {
    var body: some View {
        ModelStatusView()
    }
}

private struct PermissionsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Recording access") {
                HStack {
                    Button("Check microphone and system audio access") {
                        Task {
                            await model.resolveRecordingPermissions(
                                forceSystemAudioProbe: true
                            )
                        }
                    }
                    .disabled(
                        model.isResolvingRecordingPermissions
                            || model.isRecording
                            || model.isStartingRecording
                    )
                    Spacer()
                    if model.isResolvingRecordingPermissions {
                        ProgressView().controlSize(.small)
                    }
                }

                PermissionStatusRow(
                    title: "Microphone",
                    detail: "Steno records your own voice through the microphone.",
                    status: model.recordingPermissions.microphone
                )

                PermissionStatusRow(
                    title: "System audio",
                    detail: "Steno records the other side of a call as a separate track.",
                    status: model.recordingPermissions.systemAudio
                )
                if let systemAudioError = model.recordingPermissions.systemAudioError {
                    Text(systemAudioError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Microphone choice") {
                MicrophoneSelectionControls()
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let detail: String
    let status: AudioPermissionStatus

    private var presentation: RecordingPermissionPresentation {
        RecordingPermissionPresentation(status: status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                Spacer()
                Label(presentation.text, systemImage: presentation.symbolName)
                    .fontWeight(.semibold)
                    .foregroundStyle(accentColor)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if presentation.tone != .neutral {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accentColor.opacity(0.10))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var accentColor: Color {
        switch presentation.tone {
        case .neutral:
            .secondary
        case .failure:
            .red
        case .success:
            .green
        }
    }
}

enum RecordingPermissionTone: Equatable {
    case neutral
    case failure
    case success
}

struct RecordingPermissionPresentation: Equatable {
    let text: String
    let symbolName: String
    let tone: RecordingPermissionTone

    init(status: AudioPermissionStatus) {
        switch status {
        case .notDetermined:
            text = "Not asked yet"
            symbolName = "questionmark.circle"
            tone = .neutral
        case .restricted:
            text = "Not available on this Mac"
            symbolName = "xmark.circle.fill"
            tone = .failure
        case .denied:
            text = "Denied. Allow it in System Settings under Privacy & Security."
            symbolName = "xmark.circle.fill"
            tone = .failure
        case .authorized:
            text = "Allowed"
            symbolName = "checkmark.circle.fill"
            tone = .success
        }
    }
}
