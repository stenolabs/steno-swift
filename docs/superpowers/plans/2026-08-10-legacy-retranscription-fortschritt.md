# Legacy-Re-Transkription und Fortschritt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Legacy-Meetings bieten die Re-Transkription direkt im Hinweis an und zeigen dort alle drei Verarbeitungsschritte bis zu sichtbaren Sprechern.

**Architecture:** Eine reine Präsentationslogik leitet den Zustand ausschließlich aus Meeting-Metadaten, aktueller Revision, Review-Run, Audioverfügbarkeit und Jobs ab. `MeetingDetailView` rendert daraus Hinweis, Aktion, Fortschritt oder Fehler und verwendet für Hinweis und Inspector denselben vorhandenen Pipeline-Aufruf.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XcodeGen, StenoDomain und StenoPipeline.

## Global Constraints

- Die Verarbeitungs-Pipeline bleibt `finalASR -> diarization -> identitySuggestion`.
- Der Lauf startet nicht automatisch beim Import.
- Das alte Transkript bleibt als frühere Revision erhalten.
- Es wird kein neuer persistierter Zustand eingeführt.
- Ein fehlendes Modell oder ein Transkriptionsfehler darf eine Aufnahme niemals beenden.
- Normale Meetings und Legacy-Meetings ohne Audio erhalten keinen unbrauchbaren Button.
- Sichtbare Texte verwenden keinen Gedankenstrich.
- `project.yml` ist die Quelle für Xcode-Ziele und Schemes.

---

## File Map

- Create `App/Sources/LegacyUpgradePresentation.swift`: Reine Zustandsableitung und Schritttexte für das Legacy-Upgrade.
- Create `App/Tests/LegacyUpgradePresentationTests.swift`: Zustands- und Regressionsprüfungen ohne UI-Automation.
- Modify `project.yml`: macOS-Testziel und gemeinsames Scheme für reproduzierbare App-Tests.
- Modify `App/Sources/MeetingDetailView.swift`: Direkte Aktion, Inline-Fortschritt, Fehlerzustand und gemeinsamer Startpfad.

### Task 1: Testbare Legacy-Upgrade-Zustandslogik

**Files:**

- Modify: `project.yml`
- Create: `App/Tests/LegacyUpgradePresentationTests.swift`
- Create: `App/Sources/LegacyUpgradePresentation.swift`

**Interfaces:**

- Consumes: `Meeting`, `TranscriptRevision`, `MeetingReviewData.runID` als `RunID?`, `[Job]`, Audioverfügbarkeit und `needsTranscriptionFirst`.
- Produces: `LegacyUpgradePresentation.state(meeting:revision:reviewRunID:jobs:hasAudio:needsTranscriptionFirst:) -> LegacyUpgradePresentation`.
- Produces: `LegacyUpgradePresentation.stepTitle(for:) -> String`.

- [ ] **Step 1: macOS-Testziel in XcodeGen aufnehmen**

Ergänze `project.yml` um ein Unit-Test-Ziel und ein explizites Scheme:

```yaml
  StenoTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - App/Tests
    dependencies:
      - target: Steno
      - package: StenoKit
        product: StenoDomain
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.steno.StenoTests
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGN_IDENTITY: "-"
        MACOSX_DEPLOYMENT_TARGET: "26.0"

schemes:
  Steno:
    build:
      targets:
        Steno: all
    test:
      targets:
        - StenoTests
```

- [ ] **Step 2: Fehlende Präsentationslogik durch Tests beschreiben**

Erstelle `App/Tests/LegacyUpgradePresentationTests.swift` mit Swift Testing.
Die Tests müssen mindestens diese Fälle ausdrücken:

```swift
import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("Legacy upgrade presentation")
struct LegacyUpgradePresentationTests {
    @Test("Legacy import offers the complete repair action")
    func legacyImportOffersRepair() {
        #expect(state() == .ready(actionTitle: "Re-transcribe and detect speakers"))
    }

    @Test("Diarization stays visible after final ASR changed the revision origin")
    func diarizationRemainsVisibleAfterASR() {
        let asrRun = RunID()
        let job = makeJob(kind: .diarization, status: .running)
        #expect(
            state(
                revision: makeRevision(origin: .finalRun(asrRun)),
                jobs: [job],
                needsTranscriptionFirst: false
            ) == .running(job: job)
        )
        #expect(LegacyUpgradePresentation.stepTitle(for: .diarization)
            == "Detecting speakers, step 2 of 3")
    }

    @Test("Imported review data does not masquerade as a completed new run")
    func staleImportedReviewDoesNotCompleteUpgrade() {
        let oldRunID = RunID()
        #expect(
            state(
                revision: makeRevision(
                    origin: .legacyImport,
                    speaker: .cluster(runID: oldRunID, clusterID: "legacy-speaker")
                ),
                reviewRunID: oldRunID
            ) == .ready(actionTitle: "Re-transcribe and detect speakers")
        )
    }

    @Test("Current speaker review completes the upgrade")
    func currentReviewCompletesUpgrade() {
        let runID = RunID()
        #expect(
            state(
                revision: makeRevision(origin: .finalRun(runID)),
                reviewRunID: runID,
                needsTranscriptionFirst: false
            ) == .hidden
        )
    }

    @Test("A failed chain remains visible and retryable")
    func failureRemainsRetryable() {
        let job = makeJob(
            kind: .diarization,
            status: .failed,
            errorMessage: "model failed"
        )
        #expect(
            state(
                jobs: [job],
                needsTranscriptionFirst: false
            ) == .failed(
                message: "model failed",
                actionTitle: "Detect speakers"
            )
        )
    }

    @Test("Legacy meeting without audio has no action")
    func noAudioHasNoAction() {
        #expect(state(hasAudio: false) == .unavailable)
    }

    @Test("Normal meeting has no legacy upgrade presentation")
    func normalMeetingIsHidden() {
        let meeting = Meeting(title: "Normal", status: .ready)
        #expect(LegacyUpgradePresentation.state(
            meeting: meeting,
            revision: makeRevision(origin: .finalRun(RunID())),
            reviewRunID: nil,
            jobs: [],
            hasAudio: true,
            needsTranscriptionFirst: false
        ) == .hidden)
    }

    @Test("Every processing job has an explicit step")
    func stepTitles() {
        #expect(LegacyUpgradePresentation.stepTitle(for: .finalASR)
            == "Transcription, step 1 of 3")
        #expect(LegacyUpgradePresentation.stepTitle(for: .diarization)
            == "Detecting speakers, step 2 of 3")
        #expect(LegacyUpgradePresentation.stepTitle(for: .identitySuggestion)
            == "Comparing voices, step 3 of 3")
    }
}
```

Füge im selben Testtyp diese lokalen Builder hinzu:

```swift
private let meetingID = MeetingID()

private func state(
    revision: TranscriptRevision? = nil,
    reviewRunID: RunID? = nil,
    jobs: [Job] = [],
    hasAudio: Bool = true,
    needsTranscriptionFirst: Bool = true
) -> LegacyUpgradePresentation {
    LegacyUpgradePresentation.state(
        meeting: Meeting(
            id: meetingID,
            title: "Legacy",
            status: .ready,
            metadata: MeetingMetadata(legacyProvenanceKey: "legacy:test")
        ),
        revision: revision ?? makeRevision(origin: .legacyImport),
        reviewRunID: reviewRunID,
        jobs: jobs,
        hasAudio: hasAudio,
        needsTranscriptionFirst: needsTranscriptionFirst
    )
}

private func makeRevision(
    origin: TranscriptOrigin,
    speaker: SpeakerReference? = nil
) -> TranscriptRevision {
    TranscriptRevision(
        meetingID: meetingID,
        origin: origin,
        turns: [TranscriptTurn(
            speaker: speaker,
            start: 0,
            end: 1,
            segments: []
        )]
    )
}

private func makeJob(
    kind: Job.Kind,
    status: Job.Status,
    createdAt: Date = Date(),
    errorMessage: String? = nil
) -> Job {
    Job(
        kind: kind,
        meetingID: meetingID,
        status: status,
        createdAt: createdAt,
        errorMessage: errorMessage
    )
}
```

- [ ] **Step 3: Tests generieren und den erwarteten Fehlschlag belegen**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/LegacyUpgradePresentationTests test
```

Expected: FAIL, weil `LegacyUpgradePresentation` noch nicht existiert.

- [ ] **Step 4: Minimale reine Zustandslogik implementieren**

Erstelle `App/Sources/LegacyUpgradePresentation.swift` mit dieser Form:

```swift
import Foundation
import StenoDomain

enum LegacyUpgradePresentation: Equatable {
    case hidden
    case unavailable
    case ready(actionTitle: String)
    case running(job: Job)
    case failed(message: String, actionTitle: String?)

    static func state(
        meeting: Meeting?,
        revision: TranscriptRevision?,
        reviewRunID: RunID?,
        jobs: [Job],
        hasAudio: Bool,
        needsTranscriptionFirst: Bool
    ) -> Self {
        guard meeting?.metadata?.legacyProvenanceKey != nil else { return .hidden }
        let relevant = jobs.filter {
            $0.kind == .finalASR
                || $0.kind == .diarization
                || $0.kind == .identitySuggestion
        }
        if let active = relevant
            .filter { $0.status == .running || $0.status == .queued }
            .sorted(by: activeOrder)
            .first {
            return .running(job: active)
        }
        if let failed = unresolvedFailure(in: relevant) {
            return .failed(
                message: failed.errorMessage ?? "unknown",
                actionTitle: hasAudio ? actionTitle(needsTranscriptionFirst) : nil
            )
        }
        if reviewMatchesCurrentRevision(revision, reviewRunID: reviewRunID)
            || relevant.contains(where: {
                $0.kind == .diarization && $0.status == .finished
            }) {
            return .hidden
        }
        guard hasAudio else { return .unavailable }
        return .ready(actionTitle: actionTitle(needsTranscriptionFirst))
    }

    static func stepTitle(for kind: Job.Kind) -> String {
        switch kind {
        case .finalASR: "Transcription, step 1 of 3"
        case .diarization: "Detecting speakers, step 2 of 3"
        case .identitySuggestion: "Comparing voices, step 3 of 3"
        default: "Processing"
        }
    }

    private static func actionTitle(_ needsTranscriptionFirst: Bool) -> String {
        needsTranscriptionFirst
            ? "Re-transcribe and detect speakers"
            : "Detect speakers"
    }

    private static func activeOrder(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.status != rhs.status { return lhs.status == .running }
        return lhs.createdAt < rhs.createdAt
    }

    private static func unresolvedFailure(in jobs: [Job]) -> Job? {
        jobs
            .filter { $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
            .first { failed in
                !jobs.contains {
                    $0.kind == failed.kind
                        && $0.status == .finished
                        && $0.createdAt > failed.createdAt
                }
            }
    }

    private static func reviewMatchesCurrentRevision(
        _ revision: TranscriptRevision?,
        reviewRunID: RunID?
    ) -> Bool {
        guard let revision, let reviewRunID else { return false }
        switch revision.origin {
        case .finalRun(let runID):
            return runID == reviewRunID
        case .userEdit:
            return revision.turns.contains { turn in
                guard let speaker = turn.speaker,
                      case .cluster(let runID, _) = speaker
                else { return false }
                return runID == reviewRunID
            }
        case .liveProvisional, .legacyImport:
            return false
        }
    }
}
```

- [ ] **Step 5: Fokussierte Tests grün ausführen**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/LegacyUpgradePresentationTests test
```

Expected: PASS für alle Tests der Suite `Legacy upgrade presentation`.

- [ ] **Step 6: Task committen**

```bash
git add project.yml App/Sources/LegacyUpgradePresentation.swift App/Tests/LegacyUpgradePresentationTests.swift
git commit -m "test(mac): Legacy-Verarbeitungszustand absichern"
```

### Task 2: Direkte Aktion und Inline-Fortschritt integrieren

**Files:**

- Modify: `App/Sources/MeetingDetailView.swift:94-139`
- Modify: `App/Sources/MeetingDetailView.swift:145-155`
- Modify: `App/Sources/MeetingDetailView.swift:304-405`

**Interfaces:**

- Consumes: `LegacyUpgradePresentation.state(meeting:revision:reviewRunID:jobs:hasAudio:needsTranscriptionFirst:)` und `LegacyUpgradePresentation.stepTitle(for:)` aus Task 1.
- Produces: `MeetingDetailView.startSpeakerProcessing()` als gemeinsamer Startpfad für Hinweis und Inspector.
- Produces: `MeetingDetailView.legacyUpgradeBanner(_:)` als UI für alle Präsentationszustände.

- [ ] **Step 1: Bestehende Tests als Ausgangspunkt ausführen**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/LegacyUpgradePresentationTests test
```

Expected: PASS.

- [ ] **Step 2: Den Inspector auf einen gemeinsamen Startpfad umstellen**

Füge in `MeetingDetailView` diese Methode hinzu:

```swift
private func startSpeakerProcessing() {
    Task {
        guard await model.requestDiarization(meetingID: meetingID) else { return }
        jobs = await model.jobs(for: meetingID)
        await refreshLoop()
    }
}
```

Ersetze die duplizierte `Task` im bestehenden `diarizationStart` durch `startSpeakerProcessing()`.
Deaktiviere den Inspector-Button mit `isSpeakerProcessing`, solange einer der drei Verarbeitungsjobs wartet oder läuft:

```swift
private var isSpeakerProcessing: Bool {
    transcriptionJobs.contains {
        $0.status == .queued || $0.status == .running
    }
}
```

- [ ] **Step 3: Legacy-Hinweis in eine direkte Aktionsfläche umbauen**

Lasse `originNote(_:)` nur noch `.liveProvisional` darstellen.
Rufe am Anfang von `transcriptList(_:)` stattdessen zusätzlich `legacyUpgradeBanner(revision)` auf.

Die neue View berechnet genau einmal:

```swift
private var legacyUpgradeState: LegacyUpgradePresentation {
    LegacyUpgradePresentation.state(
        meeting: meeting,
        revision: revision,
        reviewRunID: review?.runID,
        jobs: jobs,
        hasAudio: model.meetingsWithAudio.contains(meetingID),
        needsTranscriptionFirst: needsTranscriptionFirst
    )
}
```

Implementiere die Zustände mit dieser Struktur:

```swift
@ViewBuilder
private var legacyUpgradeBanner: some View {
    switch legacyUpgradeState {
    case .hidden:
        EmptyView()
    case .unavailable:
        legacyExplanation
    case .ready(let actionTitle):
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            legacyExplanation
            Button(actionTitle) { startSpeakerProcessing() }
                .controlSize(.small)
        }
    case .running(let job):
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            legacyExplanation
            HStack(spacing: Steno.Space.s) {
                ProgressView().controlSize(.small)
                Text(LegacyUpgradePresentation.stepTitle(for: job.kind))
                    .font(.callout)
                Text("for \(Text(job.createdAt, style: .relative))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    case .failed(let message, let actionTitle):
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            legacyExplanation
            Label(
                "Processing failed: \(message)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(Steno.Colors.error)
            if let actionTitle {
                Button(actionTitle) { startSpeakerProcessing() }
                    .controlSize(.small)
            }
        }
    }
}

private var legacyExplanation: some View {
    Label(
        "Taken over from the legacy Steno app: the timestamps are imprecise and the speaker assignment comes from the old recognition.",
        systemImage: "clock.badge.exclamationmark"
    )
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
}
```

Die Aktions- und Fortschrittszeile steht direkt darunter, damit die Erklärung auf schmalen Fenstern nicht gegen den Button zusammengedrückt wird.

- [ ] **Step 4: Fokussierte Tests und macOS-Build ausführen**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/LegacyUpgradePresentationTests test
scripts/build-app.sh
```

Expected: Tests PASS und `** BUILD SUCCEEDED **`.

- [ ] **Step 5: End-to-End in der isolierten Testbibliothek prüfen**

Starte die Debug-App weiterhin ausschließlich mit:

```bash
STENO_LIBRARY_DIR='~/Library/Application Support/StenoTestLibrary' \
STENO_MODEL_DIR='/private/tmp/steno-macos-model-smoke-20260810' \
'.build/DerivedData/Build/Products/Debug/steno-macos.app/Contents/MacOS/steno-macos'
```

Öffne das bereits importierte, noch nicht neu verarbeitete Meeting **Everquest Discord 3er Konferenz**.
Prüfe visuell:

1. Der Legacy-Hinweis zeigt den direkten Button.
2. Ein Klick zeigt Schritt 1 an derselben Stelle.
3. Nach dem Erscheinen der neuen Transkription bleibt Schritt 2 sichtbar.
4. Schritt 3 bleibt bis zum Ende sichtbar.
5. Danach verschwindet der Hinweis und Sprecher erscheinen im Inspector.
6. Ein erneuter Klick kann während der Kette nicht ausgelöst werden.

- [ ] **Step 6: Vollständige relevante Verifikation ausführen**

Run:

```bash
scripts/build-app.sh
swift test --package-path StenoKit
git diff --check
git status --short
```

Expected: macOS-Build erfolgreich, alle StenoKit-Tests erfolgreich, kein Whitespace-Fehler und nur die beabsichtigten Dateien geändert.

- [ ] **Step 7: Task committen**

```bash
git add App/Sources/MeetingDetailView.swift
git commit -m "fix(mac): Legacy-Sprecherlauf sichtbar machen"
```
