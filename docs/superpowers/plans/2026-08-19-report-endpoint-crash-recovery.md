# Report Endpoint Crash Recovery Implementation Plan

> **For agentic workers:** Diese Aufgabe wird wegen der ausdruecklichen Vorgabe ohne Subagenten inline umgesetzt. Testgetriebene RED/GREEN-Schritte und `verification-before-completion` sind verpflichtend.

**Goal:** Alte externe Reportjobs vor jeder Datenerfassung oder Netzwerkaktion stoppen und Endpoint-/Secret-Mutationen nach jedem Crash konsistent wiederherstellen.

**Architecture:** Die Pipeline erhaelt eine fruehe Validierung fuer moderne externe Jobpins. `StenoIntelligence` erhaelt einen gemeinsamen secret-freien RegistryState mit Journal und Recovery-Kern; beide Apps orchestrieren Keychain und UI ueber denselben Vertrag.

**Tech Stack:** Swift 6.3, Foundation, UserDefaults, Security/Keychain, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-19-report-endpoint-crash-recovery-design.md`

## Global Constraints

- Keine Subagenten, kein Push, kein physisches Geraet und kein echter externer Endpunkt.
- Kein Secret in UserDefaults, Job, Journal, Log oder Testartefakt.
- Legacy-Apple-Jobs ohne externe ID bleiben kompatibel.
- Aufnahme, Recovery, Transkript, Diarisierung und fachlicher Meetingstatus bleiben von Reportfehlern getrennt.
- Keine neue Dependency und kein globaler SwiftPM-Testlauf.

---

### Task 1: Externe Legacy-Reportjobs fail-closed beenden

**Files:**
- Modify: `StenoKit/Sources/StenoDomain/Job.swift`
- Modify: `StenoKit/Sources/StenoPipeline/PipelineError.swift`
- Modify: `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift`
- Test: `StenoKit/Tests/StenoPipelineTests/TemplateRenderPipelineTests.swift`
- Modify: `App/Sources/ReportsSection.swift`
- Test: `App/Tests/ReportsDisclosureTests.swift`
- Modify: `iOS/App/Sources/MeetingReportsPresentation.swift`
- Test: `iOS/App/Tests/MeetingReportsPresentationTests.swift`

**Interfaces:**
- Produces: `Job.FailureReason.templateRenderPinsRequired`.
- Produces: `PipelineError.templateRenderPinsRequired`.
- Produces: eine fruehe Guard fuer externe Templatejobs mit Fingerprint, Snapshot, passender ID und Revision.

- [x] **Step 1: Write failing queued/recovery matrix tests**

Die Tests persistieren fuer `.queued` und `.running` je einen externen Schema-1-Job mit fehlendem Fingerprint, fehlendem Snapshot, fehlender Snapshotrevision oder beiden fehlenden Pins.

Sie aendern Notizen und Endpointfixture nach Jobpersistenz und erwarten `.failed`, `templateRenderPinsRequired` sowie Resolver-, Provider- und URLRequest-Zaehler null.

- [x] **Step 2: Run RED**

Run: `swift test --package-path StenoKit --scratch-path /private/tmp/steno-report-endpoint-fix4-build/swiftpm --filter TemplateRenderPipelineTests`

Expected: Die Legacy-External-Faelle rendern oder erreichen den Resolver und verletzen die neuen Erwartungen.

- [x] **Step 3: Implement the early typed guard**

Die Guard laeuft am Anfang von `executeTemplateRender` vor committed Replay und Inputassembly.

Nur `textModelEndpointID == nil` darf fehlende moderne Pins als Apple-Legacyvertrag akzeptieren.

- [x] **Step 4: Run GREEN and presentation RED/GREEN**

Run: `swift test --package-path StenoKit --scratch-path /private/tmp/steno-report-endpoint-fix4-build/swiftpm --filter TemplateRenderPipelineTests`

Run: `xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -derivedDataPath /private/tmp/steno-report-endpoint-fix4-build/mac test -only-testing:StenoTests/ReportsDisclosureTests`

Run: `xcodebuild -project iOS/StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/steno-report-endpoint-fix4-build/ios test -only-testing:StenoTests/MeetingReportsPresentationTests`

Die UIs fordern fuer beide typisierten Input-/Pin-Fehler genau einen unmittelbaren Preflightrefresh an.

### Task 2: Gemeinsamen kanonischen RegistryState entwickeln

**Files:**
- Create: `StenoKit/Sources/StenoIntelligence/TextModelEndpointRegistryState.swift`
- Test: `StenoKit/Tests/StenoIntelligenceTests/TextModelEndpointRegistryStateTests.swift`

**Interfaces:**
- Produces: `TextModelEndpointRegistryState`, `TextModelEndpointMutationJournal`, `TextModelEndpointRegistryStoring`, `TextModelSecretStoring`, `UserDefaultsTextModelEndpointRegistryStore` und `TextModelEndpointRegistryRecovery.recover`.

- [x] **Step 1: Write failing journal and recovery tests**

Die Tests pruefen prepared/committed Upsert und Delete, jeden wiederholten Recoveryaufruf, Legacy-Defaults-Migration und secret-freie JSON-Codierung.

- [x] **Step 2: Run RED**

Run: `swift test --package-path StenoKit --scratch-path /private/tmp/steno-report-endpoint-fix4-build/swiftpm --filter TextModelEndpointRegistryStateTests`

Expected: Die neuen Registrytypen fehlen.

- [x] **Step 3: Implement minimal shared state and recovery**

Ein einzelner codierter State bleibt die kanonische Wahrheit.

Recovery entfernt nur die im Journal referenzierten Slots und persistiert jede Phasenaenderung vor der naechsten destruktiven Aktion.

- [x] **Step 4: Run GREEN**

Run the same focused suite and verify every recovery mutation is idempotent.

### Task 3: macOS- und iOS-Settings an die Zustandsmaschine anbinden

**Files:**
- Modify: `App/Sources/TextModelSettings.swift`
- Modify: `App/Sources/TextModelSettingsView.swift`
- Test: `App/Tests/TextModelSettingsTests.swift`
- Modify: `iOS/App/Sources/TextModelSettings.swift`
- Modify: `iOS/App/Sources/TextModelSettingsView.swift`
- Test: `iOS/App/Tests/TextModelSettingsTests.swift`

**Interfaces:**
- Consumes: gemeinsamer RegistryState, Secretstore und Recovery-Kern.
- Produces: `TextModelSettingsMutationCheckpoint` fuer injizierte Prozessabbruchgrenzen.
- Produces: sichtbares `recoveryErrorMessage` und fail-closed Resolver-Recovery.

- [x] **Step 1: Write failing cold-instance crash tests on both platforms**

Upsert wird nach Journal, Secretwrite, Registrycommit und Old-Slot-Cleanup abgebrochen.

Delete wird nach Journal, Secretdelete und Registrycommit abgebrochen.

Jeder Test startet eine neue Settings-Instanz, prueft den kanonischen Endpoint/Slot und startet Recovery ein zweites Mal.

- [x] **Step 2: Run RED**

Run: `xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -derivedDataPath /private/tmp/steno-report-endpoint-fix4-build/mac test -only-testing:StenoTests/TextModelSettingsTests`

Run: `xcodebuild -project iOS/StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/steno-report-endpoint-fix4-build/ios test -only-testing:StenoTests/TextModelSettingsTests`

Expected: Journal, Checkpoints und Cold-Recovery fehlen.

- [x] **Step 3: Implement phase-ordered mutations**

Upsert schreibt prepared State, neuen Slot, committed State, entfernt alten Slot und loescht das Journal.

Delete schreibt prepared State, entfernt den Slot, schreibt committed State ohne Endpoint und loescht das Journal.

In-Memory-Endpoints wechseln nur nach erfolgreichem committed Persist.

- [x] **Step 4: Preserve failure and compatibility contracts**

Tests pruefen Registry-Writefehler vor jedem In-Memory-Wechsel, sichtbare Keychainfehler, stale Selection cleanup, Legacy-Defaults/Slot-Migration sowie alte und neue gepinnte Resolverjobs.

- [x] **Step 5: Run GREEN**

Run the two `xcodebuild` commands from Step 2 again and run `swift test --package-path StenoKit --scratch-path /private/tmp/steno-report-endpoint-fix4-build/swiftpm --filter TextModelEndpointRegistryStateTests`.

### Task 4: Vollverifikation, Dokumentation und lokaler Commit

**Files:**
- Modify: `docs/superpowers/plans/2026-08-11-ios-protokolle-und-openai-endpunkte.md`
- Create: `.superpowers/sdd/2026-08-11-ios-protokolle-und-openai-endpunkte/final-fix-report.md`
- Create: `.superpowers/sdd/2026-08-11-ios-protokolle-und-openai-endpunkte/progress.md`

- [x] **Step 1: Run focused mutation checks and all affected suites**

Run all StenoKit targets separately, both full app suites, StenoiOSKit and generic macOS/iOS builds with `/private/tmp/steno-report-endpoint-fix4-build`.

- [x] **Step 2: Correct compatibility documentation**

Dokumentiere, dass nur Apple-Legacy-Jobs ohne externe ID weiterhin ohne Pins laufen.

Dokumentiere RegistryState, Recoveryphasen, RED/GREEN-Belege und offene manuelle Gates.

- [x] **Step 3: Audit and clean**

Run `git diff --check`, Konfliktmarker-, Secret- und Codable-Audits.

Pruefe Prozesse gegen den exakten Buildroot, entferne ihn und dokumentiere die freigegebene Groesse.

- [x] **Step 4: Commit locally**

Stage only task-owned code, tests and tracked docs.

Create one or few logically separated local commits without co-author and do not push.
