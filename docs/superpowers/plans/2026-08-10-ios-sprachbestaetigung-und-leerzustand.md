# iOS-Sprachbestaetigung und Leerzustand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die iOS-App bietet fuer eine abgeleitete Transkriptionssprache eine eindeutige Bestaetigungsaktion und beschreibt Meetings ohne Transkript anhand des tatsaechlich gespeicherten Audios.

**Architecture:** Zwei kleine reine Darstellungsfunktionen entscheiden, welche Aktion beziehungsweise welcher Leerzustand sichtbar ist. Die SwiftUI-Views verwenden diese Funktionen direkt, waehrend der bestehende `AppModel.setLanguage`-Pfad die eigentliche Bestaetigung serialisiert und persistiert.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XcodeGen und Xcode 26.

## Global Constraints

Die Aufnahme bleibt unabhaengig von Sprachwahl und Modellbereitschaft.
Das Oeffnen der Bereitschaftsansicht und die System-Locale bestaetigen keine Sprache.
Die Bestaetigungsaktion lautet dynamisch `Use <language>` und verwendet den vorhandenen Link-Stil.
Eine gespeicherte Aufnahme ohne Transkript zeigt exakt `Audio saved. No transcript yet. If the speech model is missing, install it under Audio readiness. Steno retries automatically.`
Ein Meeting ohne Medien zeigt exakt `This meeting has no saved audio or transcript yet.`
Der bestehende Entwurfszustand bleibt unveraendert.
StenoKit bleibt unveraendert.
`UEBERGABE-sprecher-erkenntnisse.md` bleibt ungetrackt und wird nie gestaget.

---

### Task 1: Abgeleitete Transkriptionssprache eindeutig bestaetigen

**Files:**
- Modify: `iOS/App/Sources/AudioReadinessView.swift:88-126`
- Create: `iOS/App/Tests/AudioReadinessPresentationTests.swift`

**Interfaces:**
- Consumes: `AppModel.setLanguage(_:)`, `TranscriptionLanguage.selectedDisplayName`, `TranscriptionLanguage.wasChosenExplicitly` und `AppModel.canChangeLanguage`.
- Produces: `AudioReadinessPresentation.confirmationTitle(languageName:wasChosenExplicitly:canChangeLanguage:) -> String?`.

- [ ] **Step 1: Write the failing presentation tests**

Create `iOS/App/Tests/AudioReadinessPresentationTests.swift`:

```swift
import Testing
@testable import Steno

@Suite("Audio readiness presentation")
struct AudioReadinessPresentationTests {
    @Test("an inferred language offers confirmation of the visible value")
    func inferredLanguageCanBeConfirmed() {
        #expect(
            AudioReadinessPresentation.confirmationTitle(
                languageName: "German (Germany)",
                wasChosenExplicitly: false,
                canChangeLanguage: true
            ) == "Use German (Germany)"
        )
    }

    @Test("an explicitly chosen language offers no confirmation")
    func explicitLanguageNeedsNoConfirmation() {
        #expect(
            AudioReadinessPresentation.confirmationTitle(
                languageName: "German (Germany)",
                wasChosenExplicitly: true,
                canChangeLanguage: true
            ) == nil
        )
    }

    @Test("a locked language offers no second action")
    func lockedLanguageCannotBeConfirmed() {
        #expect(
            AudioReadinessPresentation.confirmationTitle(
                languageName: "German (Germany)",
                wasChosenExplicitly: false,
                canChangeLanguage: false
            ) == nil
        )
    }
}
```

The production regression caught by these tests is removal of the same-value confirmation path or showing an actionable control while language changes are locked.

- [ ] **Step 2: Run the focused test and verify red**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/AudioReadinessPresentationTests test
```

Expected: FAIL because `AudioReadinessPresentation` is not defined.

- [ ] **Step 3: Implement the minimal presentation policy and action**

Append this policy to `iOS/App/Sources/AudioReadinessView.swift`:

```swift
enum AudioReadinessPresentation {
    static func confirmationTitle(
        languageName: String,
        wasChosenExplicitly: Bool,
        canChangeLanguage: Bool
    ) -> String? {
        guard canChangeLanguage, !wasChosenExplicitly else { return nil }
        return "Use \(languageName)"
    }
}
```

Directly below the language `Picker`, render the action before the explanatory warning:

```swift
if let title = AudioReadinessPresentation.confirmationTitle(
    languageName: app.language.selectedDisplayName,
    wasChosenExplicitly: app.language.wasChosenExplicitly,
    canChangeLanguage: app.canChangeLanguage
) {
    Button(title) {
        Task { await app.setLanguage(app.language.locale.identifier) }
    }
}
```

Keep the existing lock label and warning branches unchanged.

- [ ] **Step 4: Run the focused test and verify green**

Run the command from Step 2 again.

Expected: all three tests pass and the test output contains no warning introduced by this task.

- [ ] **Step 5: Commit Task 1**

```bash
git add iOS/App/Sources/AudioReadinessView.swift \
  iOS/App/Tests/AudioReadinessPresentationTests.swift
git commit -m "fix(ios): abgeleitete Sprache eindeutig bestaetigen"
```

---

### Task 2: Meeting-Leerzustand aus dem gespeicherten Audio ableiten

**Files:**
- Modify: `iOS/App/Sources/MeetingDetailView.swift:31-43,108-118`
- Create: `iOS/App/Tests/MeetingPresentationTests.swift`

**Interfaces:**
- Consumes: `Meeting.Status?` und den bereits geladenen Wert `duration != nil`.
- Produces: `MeetingEmptyState` sowie `MeetingPresentation.emptyState(status:hasAudio:) -> MeetingEmptyState`.

- [ ] **Step 1: Write the failing state-policy tests**

Create `iOS/App/Tests/MeetingPresentationTests.swift`:

```swift
import StenoDomain
import Testing
@testable import Steno

@Suite("Meeting empty presentation")
struct MeetingPresentationTests {
    @Test("saved audio is stated and gives the transcription recovery path")
    func savedAudioWithoutTranscript() {
        #expect(
            MeetingPresentation.emptyState(status: .ready, hasAudio: true)
                == MeetingEmptyState(
                    title: "No transcript yet",
                    systemImage: "text.quote",
                    description: "Audio saved. No transcript yet. If the speech model is missing, install it under Audio readiness. Steno retries automatically."
                )
        )
    }

    @Test("a meeting without media does not claim saved audio")
    func noMediaWithoutTranscript() {
        #expect(
            MeetingPresentation.emptyState(status: .ready, hasAudio: false)
                == MeetingEmptyState(
                    title: "No transcript yet",
                    systemImage: "text.quote",
                    description: "This meeting has no saved audio or transcript yet."
                )
        )
    }

    @Test("a draft keeps its existing explanation")
    func draftWithoutRecording() {
        #expect(
            MeetingPresentation.emptyState(status: .draft, hasAudio: false)
                == MeetingEmptyState(
                    title: "Draft",
                    systemImage: "square.and.pencil",
                    description: "This meeting holds a note and no recording yet."
                )
        )
    }
}
```

The production regression caught by these tests is collapsing all non-draft meetings into one stale Mac-only explanation or claiming that audio exists when no media duration was loaded.

- [ ] **Step 2: Run the focused test and verify red**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/MeetingPresentationTests test
```

Expected: FAIL because `MeetingPresentation` and `MeetingEmptyState` are not defined.

- [ ] **Step 3: Implement the minimal state policy and connect the view**

Append to `iOS/App/Sources/MeetingDetailView.swift`:

```swift
struct MeetingEmptyState: Equatable {
    let title: String
    let systemImage: String
    let description: String
}

enum MeetingPresentation {
    static func emptyState(
        status: Meeting.Status?,
        hasAudio: Bool
    ) -> MeetingEmptyState {
        if status == .draft {
            return MeetingEmptyState(
                title: "Draft",
                systemImage: "square.and.pencil",
                description: "This meeting holds a note and no recording yet."
            )
        }
        if hasAudio {
            return MeetingEmptyState(
                title: "No transcript yet",
                systemImage: "text.quote",
                description: "Audio saved. No transcript yet. If the speech model is missing, install it under Audio readiness. Steno retries automatically."
            )
        }
        return MeetingEmptyState(
            title: "No transcript yet",
            systemImage: "text.quote",
            description: "This meeting has no saved audio or transcript yet."
        )
    }
}
```

Inside the `didLoad` branch, compute `let state = MeetingPresentation.emptyState(status: meeting?.status, hasAudio: duration != nil)` and pass its three fields to `ContentUnavailableView`.
Remove the old `emptyDescription` property.

- [ ] **Step 4: Run the focused test and verify green**

Run the command from Step 2 again.

Expected: all three tests pass and the test output contains no warning introduced by this task.

- [ ] **Step 5: Commit Task 2**

```bash
git add iOS/App/Sources/MeetingDetailView.swift \
  iOS/App/Tests/MeetingPresentationTests.swift
git commit -m "fix(ios): gespeichertes Audio im Leerzustand zeigen"
```

---

### Task 3: Geraeteabnahme dokumentieren und i1 abschliessen

**Files:**
- Create: `docs/BENCH-IOS-I1-MODELS.md`
- Modify: `docs/PLAN-IOS.md:274-288`
- Update without committing: `HANDOFF-audio-core-extraction.md`

**Interfaces:**
- Consumes: die am 09.08.2026 auf dem iPhone 15 Pro beobachteten Ablaeufe und die lokal geprueften Jobdokumente.
- Produces: reproduzierbarer Nachweis fuer i1 Schritt 7 und eine ehrliche Abgrenzung der noch offenen i2-Diarisierung.

- [ ] **Step 1: Write the measured device report**

Create `docs/BENCH-IOS-I1-MODELS.md` with these facts, each full sentence on its own physical line:

```markdown
# iOS i1 - Modellinstallation und Live-Revision

Stand: 2026-08-09.
Geraet und iOS-Version: iPhone 15 Pro mit iOS 26.5.2.
Build-Commit: `cb4569c`.

## Installiertes Modell

- Gewaehlte Sprache: German (Germany).
- Live-Text vor Stop sichtbar: Ja, bei der kurzen Messung nach ungefaehr 15 Sekunden.
- Provisorische Revision nach Stop sichtbar: Ja.
- Revision nach Neustart sichtbar: Ja, danach durch den segmentierten finalen ASR-Lauf ersetzt.
- Anzahl Final-ASR-Jobs fuer das Meeting: Genau ein Job.

## Fehlendes Modell

- Gewaehlte Sprache: French (France).
- Download vor Zustimmung beobachtet: Nein.
- Audio ohne Modell erhalten: Ja, eine CAF-Datei mit 1,7 MB und die zugehoerigen Metadaten.
- Angezeigte Quelle und Groesse: Apple, 142,6 MB.
- Modellbedingt gescheiterter Job erneut verarbeitet: Ja, derselbe Final-ASR-Job endete nach zwei Versuchen mit Status `finished`.
- Diarisierungsdownload beobachtet: Nein.

## Grenzen

Nur die oben genannten kurzen Ablaeufe wurden auf echter Hardware geprueft.
Die ungefaehr 15 Sekunden bis zum deutschen Live-Text sind eine Einzelbeobachtung und kein belastbarer Leistungswert.
Eine lange Aufnahme, Thermik, Akku, Hintergrundbetrieb und Unterbrechungen waren nicht Teil dieser Messung.
Der Diarisierungsjob wurde eingereiht und scheiterte erwartungsgemaess an den noch fehlenden Modellen Sortformer, pyannote und WeSpeaker.
Es wurde kein automatischer Diarisierungsdownload beobachtet.
```

- [ ] **Step 2: Replace the open i1 step 7 with the verified result**

In `docs/PLAN-IOS.md`, replace the open step 7 with a completed paragraph that states:

```markdown
7. **Erledigt: Modellinstallation und Wiederaufnahme des finalen ASR-Laufs.**
   iOS setzt `ModelInstallationCoordinator` nur mit `SpeechAssetInstaller` zusammen und fragt in i1 ausschliesslich fuer Apple-Sprachassets um ausdrueckliche Zustimmung.
   Ein fehlendes Modell sperrt die Aufnahme nicht; Audio wird gespeichert und der modellbedingt gescheiterte finale ASR-Lauf wird nach erfolgreicher Installation gezielt erneut verarbeitet.
   Implementiert in `fd780e3` bis `cb4569c` und auf dem iPhone in `docs/BENCH-IOS-I1-MODELS.md` belegt.
   Diarisierungsmodelle bleiben Bestandteil von i2 und werden in i1 nicht installiert.
```

- [ ] **Step 3: Verify all iOS tests and the generated iOS build**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
cd ..
scripts/build-ios.sh
git diff --check
```

Expected: every `StenoTests` test passes, `scripts/build-ios.sh` ends with `BUILD SUCCEEDED`, and `git diff --check` prints nothing.

- [ ] **Step 4: Check privacy and recording invariants**

Run:

```bash
rg -n "ModelInstallationCoordinator\.standard|DiarizationModelInstaller|Locale\.current" iOS/App/Sources
rg -n "allowAndInstall|install\(" iOS/App/Sources
rg -n "TBD|TODO|nicht geprueft|—|–" \
  docs/PLAN-IOS.md docs/BENCH-IOS-I1-MODELS.md
git status --short
```

Expected: no standard coordinator or diarization installer in iOS, no `Locale.current` in a transcription call, exactly one user-triggered installation entry point, no documentation placeholder, and only intended files plus the unrelated untracked handoff are visible.

- [ ] **Step 5: Commit Task 3 and update the uncommitted handoff**

```bash
git add docs/PLAN-IOS.md docs/BENCH-IOS-I1-MODELS.md
git commit -m "docs(ios): Modellinstallation am Geraet belegen"
```

Update `HANDOFF-audio-core-extraction.md` with the current branch and commits, the completed device evidence, the latest verification, and the remaining macOS or iOS-port work.
Do not stage or commit the handoff.

---

### Task 4: Install the verified UI build on the paired iPhone

**Files:**
- No repository files.

**Interfaces:**
- Consumes: the verified current branch and the paired physical iPhone.
- Produces: an installed build ready for the final visual check of both corrected states.

- [ ] **Step 1: Confirm the device is available and install**

Run:

```bash
xcrun devicectl list devices
scripts/build-ios.sh --device <DEVICE-UUID>
```

Expected: the target iPhone is available and `org.steno.Steno` installs successfully.

- [ ] **Step 2: Report the two manual visual checks without claiming them prematurely**

Ask the operator to confirm that an unconfirmed language offers `Use <language>` and that a newly saved recording without a transcript shows `Audio saved`.
If either state cannot be reached without deleting data or installed models, report that limitation and rely on the automated branch tests until a safe fresh state is available.
