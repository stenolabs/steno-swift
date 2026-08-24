# iOS-Modellinstallation und Live-Revisionsnachweis - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die iOS-App installiert das Apple-Sprachmodell nur nach Zustimmung, nimmt ohne Modell weiter sicher auf und persistiert beim Stop genau eine provisorische Live-Revision plus einen finalen ASR-Job.

**Architecture:** Ein iOS-spezifischer `IOSModelInstallationState` treibt den vorhandenen `ModelInstallationCoordinator` mit genau einem `SpeechAssetInstaller`. `AppModel` serialisiert Sprachwechsel und Pipeline-Neustart, stellt nur modellbedingt gescheiterte Final-ASR-Jobs zurueck und haelt den Audiopfad unabhaengig. Ein eigener `RecordingFinalizer`-Aktor macht den persistenten Stop-Pfad testbar und idempotent.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, Swift Testing, SwiftPM `StenoKit`, XcodeGen, iOS 26, macOS 26.

**Specification:** `docs/superpowers/specs/2026-08-08-ios-modellinstallation-und-live-revision-design.md`

## Global Constraints

- Mindestziel bleibt iOS 26.0 und macOS 26.
- Swift laeuft mit `SWIFT_VERSION: "6.0"` und `SWIFT_STRICT_CONCURRENCY: complete`.
- Keine neue Abhaengigkeit und kein Versionsupgrade.
- In i1 wird nur `SpeechAssetInstaller` verwendet, nicht `ModelInstallationCoordinator.standard` und nicht `DiarizationModelInstaller`.
- Ein fehlendes, abgelehntes oder fehlerhaftes Modell darf den Audiopfad nie blockieren oder beenden.
- Modelle laden nie selbsttaetig aus einem Provider.
- Die gespeicherte Transkriptionssprache bleibt die einzige Sprache im Transkriptionspfad. `Locale.current` darf dort nicht als Ersatz auftauchen.
- Nutzertexte und neue Bedienoberflaeche sind englisch. Kommentare duerfen dem Bestand folgend deutsch sein.
- Kein Gedankenstrich in Text, Kommentaren oder Dokumentation. Ein einfacher Bindestrich ist zu verwenden.
- Originale und Revisionen bleiben unveraenderlich. Korrekturen und Finalergebnisse entstehen als neue Revisionen.
- `App/Info.plist`, `iOS/App/Info.plist` und beide Xcode-Projekte sind Generate und werden nicht editiert oder committet.
- `UEBERGABE-sprecher-erkenntnisse.md` bleibt unangetastet und wird nie gestaget.
- Nach jeder Aenderung im StenoKit-Kern gilt die volle Kette: `xcodegen generate && scripts/build-app.sh && scripts/build-ios.sh && swift test --package-path StenoKit`.
- Jeder Implementierungs-Commit fuehrt nur seine eigenen Dateien explizit mit `git add` auf.

## File Structure

| Datei | Verantwortung |
|---|---|
| `iOS/App/Sources/ModelConsent.swift` | Speichert Zeitpunkt und Apple-Quelle der iOS-Zustimmung in `UserDefaults`. |
| `iOS/App/Sources/IOSModelInstallationState.swift` | Bereitschaft, Zustimmung, Fortschritt, Fehler, Installation und Widerruf fuer genau das Sprachasset. |
| `iOS/App/Sources/MissingSpeechModelJobRetrier.swift` | Setzt nur exakt modellbedingt gescheiterte Final-ASR-Jobs fuer die aktuelle Locale auf `queued`. |
| `iOS/App/Sources/RuntimeChangeSerializer.swift` | Fuehrt Sprachwechsel und installationsbedingte Pipeline-Neustarts strikt nacheinander aus. |
| `iOS/App/Sources/RecordingFinalizer.swift` | Persistiert Live-Revision und finalen Job genau einmal pro Aufnahme. |
| `iOS/App/Sources/AppModel.swift` | Verbindet Sprache, Modellzustand, Job-Retry und serialisierten Pipeline-Neustart. |
| `iOS/App/Sources/AudioReadinessView.swift` | Zeigt Modell, Quelle, Groesse, Zustimmung, Fortschritt, Fehler und Widerruf. |
| `iOS/App/Sources/RecordingView.swift` | Zeigt den fehlenden Modellzustand, ohne den Aufnahmeknopf zu sperren. |
| `iOS/App/Sources/ContentView.swift` | Reicht die Navigation zur Bereitschaftsansicht an den Aufnahmebildschirm. |
| `iOS/App/Sources/RecordingModel.swift` | Delegiert den persistenten Stop-Teil an `RecordingFinalizer`. |
| `iOS/App/Tests/*.swift` | Testet iOS-App-Zustand und Persistenz ohne Netz und ohne Mikrofon. |
| `iOS/project.yml` | Erzeugt das Unit-Testtarget `StenoTests`. |
| `docs/PLAN-IOS.md` | Markiert Schritt i1.7 erst nach lokaler und realer Abnahme als erledigt. |

---

### Task 1: iOS-App-Testtarget, Zustimmung und Modellzustand

**Files:**
- Modify: `iOS/project.yml`
- Create: `iOS/App/Sources/ModelConsent.swift`
- Create: `iOS/App/Sources/IOSModelInstallationState.swift`
- Create: `iOS/App/Tests/ModelConsentTests.swift`
- Create: `iOS/App/Tests/IOSModelInstallationStateTests.swift`

**Interfaces:**
- Consumes: `ModelSource`, `ModelReadiness`, `ModelInstallProgress`, `SpeechAssetInstaller`, `SpeechAssetGateway`, `ModelInstallationCoordinator`.
- Produces: `ModelConsent`, `IOSModelInstallationState`, `refresh(for:)`, `allowAndInstall(for:recordingIsActive:) -> Bool`, `revoke()`, `isReady(for:) -> Bool?`.

- [ ] **Step 1: Add the failing iOS test target and consent test**

Add this target to `iOS/project.yml` after `Steno`:

```yaml
  StenoTests:
    type: bundle.unit-test
    platform: iOS
    supportedDestinations: [iOS, iPadOS]
    sources:
      - App/Tests
    dependencies:
      - target: Steno
    settings:
      base:
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        TARGETED_DEVICE_FAMILY: "1,2"
        IPHONEOS_DEPLOYMENT_TARGET: "26.0"
```

Create `iOS/App/Tests/ModelConsentTests.swift`:

```swift
import Foundation
import StenoDomain
import Testing
@testable import Steno

@Suite("iOS model consent")
struct ModelConsentTests {
    @Test("grant persists its first timestamp and the named source")
    @MainActor
    func grantPersistsRecord() throws {
        let suite = "ModelConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "consent"
        let consent = ModelConsent(defaults: defaults, key: key)

        consent.grant(sources: [.appleSystemAssets])
        let first = try #require(consent.record)
        consent.grant(sources: [.appleSystemAssets])

        #expect(consent.record?.grantedAt == first.grantedAt)
        #expect(consent.record?.sources == ["Apple"])
        #expect(ModelConsent(defaults: defaults, key: key).record == consent.record)
    }

    @Test("revoke removes consent without deleting installed assets")
    @MainActor
    func revokeRemovesRecord() throws {
        let suite = "ModelConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let consent = ModelConsent(defaults: defaults, key: "consent")
        consent.grant(sources: [.appleSystemAssets])

        consent.revoke()

        #expect(!consent.isGranted)
        #expect(consent.record == nil)
    }
}
```

- [ ] **Step 2: Generate the project and verify the consent test fails for the missing type**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/ModelConsentTests test
```

Expected: FAIL with `cannot find 'ModelConsent' in scope`.

- [ ] **Step 3: Implement the minimal persisted consent**

Create `iOS/App/Sources/ModelConsent.swift` with this interface and behavior:

```swift
import Foundation
import Observation
import StenoDomain

@MainActor
@Observable
final class ModelConsent {
    struct Record: Codable, Equatable {
        let grantedAt: Date
        let sources: [String]
    }

    private let defaults: UserDefaults
    private let key: String
    private(set) var record: Record?

    init(
        defaults: UserDefaults = .standard,
        key: String = "org.steno.ios.modelConsent"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key) {
            record = try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    var isGranted: Bool { record != nil }

    func grant(sources: [ModelSource]) {
        let value = Record(
            grantedAt: record?.grantedAt ?? Date(),
            sources: sources.map(\.displayHost)
        )
        record = value
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    func revoke() {
        record = nil
        defaults.removeObject(forKey: key)
    }
}
```

- [ ] **Step 4: Run the consent tests and verify green**

Run the command from Step 2.

Expected: PASS for both `ModelConsentTests` tests.

- [ ] **Step 5: Write failing tests for readiness, consent, progress, concurrency and cancellation**

Create `iOS/App/Tests/IOSModelInstallationStateTests.swift` with a controllable gateway and these tests:

```swift
import Foundation
import StenoPipeline
import StenoTranscription
import Testing
@testable import Steno

@Suite("iOS speech model installation")
struct IOSModelInstallationStateTests {
    @Test("refresh distinguishes installed and missing locales")
    @MainActor
    func readinessIsPerLocale() async throws {
        let fixture = try Fixture(installed: ["de-DE"])
        await fixture.state.refresh(for: Locale(identifier: "de-DE"))
        #expect(fixture.state.isReady(for: Locale(identifier: "de-DE")) == true)

        await fixture.state.refresh(for: Locale(identifier: "en-US"))
        #expect(fixture.state.isReady(for: Locale(identifier: "en-US")) == false)
        #expect(await fixture.gateway.installCount == 0)
    }

    @Test("one approved click starts one install and keeps progress monotonic")
    @MainActor
    func approvedInstallRunsOnce() async throws {
        let fixture = try Fixture(installed: [])
        let locale = Locale(identifier: "de-DE")

        let first = Task { await fixture.state.allowAndInstall(for: locale, recordingIsActive: false) }
        await fixture.gateway.waitUntilStarted()
        let second = await fixture.state.allowAndInstall(for: locale, recordingIsActive: false)
        await fixture.gateway.emitProgress(0.8)
        await Task.yield()
        #expect(fixture.state.progress?.fraction == 0.8)
        await fixture.gateway.emitProgress(0.3)
        await Task.yield()
        #expect(fixture.state.progress?.fraction == 0.8)
        await fixture.gateway.finish()

        #expect(await first.value)
        #expect(!second)
        #expect(await fixture.gateway.installCount == 1)
        #expect(fixture.consent.isGranted)
        #expect(fixture.state.isReady(for: locale) == true)
    }

    @Test("recording blocks installation but not readiness checks")
    @MainActor
    func recordingBlocksInstall() async throws {
        let fixture = try Fixture(installed: [])
        let installed = await fixture.state.allowAndInstall(
            for: Locale(identifier: "de-DE"),
            recordingIsActive: true
        )
        #expect(!installed)
        #expect(await fixture.gateway.installCount == 0)
    }

    @Test("revoke cancels a running install and hides cancellation as a user action")
    @MainActor
    func revokeCancels() async throws {
        let fixture = try Fixture(installed: [])
        let run = Task {
            await fixture.state.allowAndInstall(
                for: Locale(identifier: "de-DE"),
                recordingIsActive: false
            )
        }
        await fixture.gateway.waitUntilStarted()

        await fixture.state.revoke()
        await fixture.gateway.finish(throwing: CancellationError())

        #expect(!(await run.value))
        #expect(!fixture.consent.isGranted)
        #expect(fixture.state.errorMessage == nil)
    }
}
```

The same file defines `Fixture` with a private `UserDefaults` suite and an actor `ControllableSpeechAssets: SpeechAssetGateway`.
The gateway stores `installed: Set<String>`, `installCount`, `isStarted`, `isReleased`, an optional release error and the progress closure.
`install(locale:progress:)` increments `installCount`, stores the progress closure, marks `isStarted`, then loops with `Task.checkCancellation()` and `Task.yield()` until `isReleased` is true.
After release it throws the stored error or inserts the locale on success.
`finish(throwing:)` stores the optional error and sets `isReleased`.
This loop makes cancellation observable without sleeps or a continuation that cannot react while suspended.
`waitUntilStarted()` uses a five-second `ContinuousClock` deadline and `Issue.record` if the install never starts.

- [ ] **Step 6: Verify the model-state tests fail for the missing type**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/IOSModelInstallationStateTests test
```

Expected: FAIL with `cannot find 'IOSModelInstallationState' in scope`.

- [ ] **Step 7: Implement the minimal model installation state**

Create `iOS/App/Sources/IOSModelInstallationState.swift`:

```swift
import Foundation
import Observation
import StenoDomain
import StenoPipeline

@MainActor
@Observable
final class IOSModelInstallationState {
    let bundleDescriptions: [ModelBundleDescription]
    let consent: ModelConsent
    private(set) var readiness: ModelReadiness?
    private(set) var progress: ModelInstallProgress?
    private(set) var isInstalling = false
    private(set) var errorMessage: String?

    private let coordinator: ModelInstallationCoordinator
    private var currentLocale: Locale?

    init(coordinator: ModelInstallationCoordinator, consent: ModelConsent) {
        self.coordinator = coordinator
        self.consent = consent
        bundleDescriptions = coordinator.bundleDescriptions
    }

    func isReady(for locale: Locale) -> Bool? {
        guard currentLocale?.identifier == locale.identifier,
              let readiness else { return nil }
        return readiness.isReady(for: locale)
    }

    func refresh(for locale: Locale) async {
        currentLocale = locale
        let result = await coordinator.readiness(for: [locale])
        guard currentLocale?.identifier == locale.identifier else { return }
        readiness = result
    }

    @discardableResult
    func allowAndInstall(for locale: Locale, recordingIsActive: Bool) async -> Bool {
        guard !recordingIsActive, !isInstalling else { return false }
        isInstalling = true
        progress = ModelInstallProgress(fraction: 0, title: "Preparing")
        errorMessage = nil
        consent.grant(sources: uniqueSources())
        defer {
            isInstalling = false
            progress = nil
        }
        do {
            try await coordinator.installAll(
                for: locale,
                consentGranted: consent.isGranted
            ) { [weak self] update in
                Task { @MainActor in self?.apply(update) }
            }
            await refresh(for: locale)
            return isReady(for: locale) == true
        } catch is CancellationError {
            return false
        } catch {
            if consent.isGranted { errorMessage = error.localizedDescription }
            await refresh(for: locale)
            return false
        }
    }

    func revoke() async {
        consent.revoke()
        await coordinator.cancelAll()
        await refreshIfPossible()
    }

    private func refreshIfPossible() async {
        if let currentLocale { await refresh(for: currentLocale) }
    }

    private func uniqueSources() -> [ModelSource] {
        var seen = Set<ModelSource>()
        return bundleDescriptions.map(\.source).filter { seen.insert($0).inserted }
    }

    private func apply(_ update: ModelInstallProgress) {
        guard update.supersedes(progress) else { return }
        progress = update
    }
}
```

In production, construct it only with:

```swift
let coordinator = ModelInstallationCoordinator(installers: [
    SpeechAssetInstaller(assets: SystemSpeechAssets()),
])
```

Do not call `ModelInstallationCoordinator.standard()` in the iOS tree.

- [ ] **Step 8: Run all new iOS app tests and commit Task 1**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests test
```

Expected: PASS for `ModelConsentTests` and `IOSModelInstallationStateTests`.

Commit only these files:

```bash
git add iOS/project.yml \
  iOS/App/Sources/ModelConsent.swift \
  iOS/App/Sources/IOSModelInstallationState.swift \
  iOS/App/Tests/ModelConsentTests.swift \
  iOS/App/Tests/IOSModelInstallationStateTests.swift
git commit -m "feat(ios): Sprachmodell nach Zustimmung installieren"
```

---

### Task 2: Nur modellbedingt gescheiterte Final-ASR-Jobs wiederholen

**Files:**
- Create: `iOS/App/Sources/MissingSpeechModelJobRetrier.swift`
- Create: `iOS/App/Sources/RuntimeChangeSerializer.swift`
- Create: `iOS/App/Tests/MissingSpeechModelJobRetrierTests.swift`
- Create: `iOS/App/Tests/RuntimeChangeSerializerTests.swift`
- Modify: `iOS/App/Sources/AppModel.swift:41-166`

**Interfaces:**
- Consumes: `JobStore.list()`, `JobStore.transition(_:to:)`, `TranscriptionError.assetsNotInstalled(localeIdentifier:)`.
- Produces: `MissingSpeechModelJobRetrier.requeue(jobStore:locale:) async throws -> [JobID]`, `RuntimeChangeSerializer.run(_:)`, `AppModel.allowAndInstallSpeechModel()`, `AppModel.revokeSpeechModelConsent()`.

- [ ] **Step 1: Write the failing exact-match retry test**

Create `iOS/App/Tests/MissingSpeechModelJobRetrierTests.swift`:

```swift
import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription
import Testing
@testable import Steno

@Suite("Retry missing speech model jobs")
struct MissingSpeechModelJobRetrierTests {
    @Test("only final ASR jobs missing the current locale model are requeued")
    func retriesOnlyExactMissingModelFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
        let store = try JobStore(layout: library.layout)
        let locale = Locale(identifier: "de-DE")
        let exactMessage = TranscriptionError.assetsNotInstalled(
            localeIdentifier: locale.identifier
        ).localizedDescription
        let exact = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            status: .failed,
            attemptCount: 1,
            errorMessage: exactMessage
        )
        let otherLocale = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            status: .failed,
            attemptCount: 1,
            errorMessage: TranscriptionError.assetsNotInstalled(
                localeIdentifier: "en-US"
            ).localizedDescription
        )
        let otherFailure = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            status: .failed,
            attemptCount: 1,
            errorMessage: "Audio file is corrupt"
        )
        for job in [exact, otherLocale, otherFailure] { try await store.enqueue(job) }

        let requeued = try await MissingSpeechModelJobRetrier.requeue(
            jobStore: store,
            locale: locale
        )

        #expect(requeued == [exact.id])
        #expect(try await store.load(exact.id).status == .queued)
        #expect(try await store.load(otherLocale.id).status == .failed)
        #expect(try await store.load(otherFailure.id).status == .failed)
    }
}
```

- [ ] **Step 2: Run the focused test and verify red**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/MissingSpeechModelJobRetrierTests test
```

Expected: FAIL with `cannot find 'MissingSpeechModelJobRetrier' in scope`.

- [ ] **Step 3: Implement exact typed-message retry**

Create `iOS/App/Sources/MissingSpeechModelJobRetrier.swift`:

```swift
import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription

enum MissingSpeechModelJobRetrier {
    static func requeue(jobStore: JobStore, locale: Locale) async throws -> [JobID] {
        let expected = TranscriptionError.assetsNotInstalled(
            localeIdentifier: locale.identifier
        ).localizedDescription
        var requeued: [JobID] = []
        for job in try await jobStore.list() where
            job.kind == .finalASR
            && job.status == .failed
            && job.errorMessage == expected
        {
            _ = try await jobStore.transition(job.id, to: .queued)
            requeued.append(job.id)
        }
        return requeued
    }
}
```

- [ ] **Step 4: Write the failing runtime serialization test**

Create `iOS/App/Tests/RuntimeChangeSerializerTests.swift`:

```swift
import Testing
@testable import Steno

@Suite("Runtime change serialization")
struct RuntimeChangeSerializerTests {
    @Test("overlapping requests execute one after another")
    @MainActor
    func operationsDoNotOverlap() async {
        let serializer = RuntimeChangeSerializer()
        let probe = ConcurrencyProbe()

        async let first: Void = serializer.run {
            await probe.enter()
            await Task.yield()
            await probe.leave()
        }
        async let second: Void = serializer.run {
            await probe.enter()
            await Task.yield()
            await probe.leave()
        }
        _ = await (first, second)

        #expect(await probe.maximumConcurrent == 1)
        #expect(await probe.completed == 2)
        #expect(!serializer.isRunning)
    }
}

private actor ConcurrencyProbe {
    private var current = 0
    private(set) var maximumConcurrent = 0
    private(set) var completed = 0

    func enter() {
        current += 1
        maximumConcurrent = max(maximumConcurrent, current)
    }

    func leave() {
        current -= 1
        completed += 1
    }
}
```

- [ ] **Step 5: Verify the serializer test is red**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/RuntimeChangeSerializerTests test
```

Expected: FAIL with `cannot find 'RuntimeChangeSerializer' in scope`.

- [ ] **Step 6: Implement the minimal main-actor serializer**

Create `iOS/App/Sources/RuntimeChangeSerializer.swift`:

```swift
@MainActor
final class RuntimeChangeSerializer {
    private var current: Task<Void, Never>?

    var isRunning: Bool { current != nil }

    func run(_ operation: @MainActor @escaping () async -> Void) async {
        if let current { await current.value }
        let task = Task { @MainActor in await operation() }
        current = task
        await task.value
        if current == task { current = nil }
    }
}
```

- [ ] **Step 7: Run both focused tests and verify green**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/MissingSpeechModelJobRetrierTests \
  -only-testing:StenoTests/RuntimeChangeSerializerTests test
```

Expected: PASS, only the exact German missing-model job is `queued`, and the probe reports maximum concurrency one.

- [ ] **Step 8: Integrate model state and one serialized runtime restart into AppModel**

Modify `iOS/App/Sources/AppModel.swift` as follows:

1. Add `let models: IOSModelInstallationState` next to `language`.
2. Replace `languageSwitch` with `private let runtimeChanges = RuntimeChangeSerializer()`.
3. In `init`, construct the model state with exactly one `SpeechAssetInstaller`.
4. At the end of successful `bootstrap`, call `await models.refresh(for: language.locale)`.
5. Keep `canChangeLanguage` false while recording, installing or changing the runtime.
6. Add `allowAndInstallSpeechModel()` and `revokeSpeechModelConsent()`.

The production construction is:

```swift
let consent = ModelConsent()
let coordinator = ModelInstallationCoordinator(installers: [
    SpeechAssetInstaller(assets: SystemSpeechAssets()),
])
models = IOSModelInstallationState(coordinator: coordinator, consent: consent)
```

`setLanguage` selects the identifier inside `runtimeChanges.run`, stops the old coordinator, clears `runtime`, calls `bootstrap`, then refreshes model readiness for the selected locale.
Preserve both same-value guards from commit `ee54365`: one before waiting and the identical confirmation-aware guard inside the serialized operation after waiting.
Without the second guard, two queued selections of the same identifier restart the runtime twice.

`allowAndInstallSpeechModel` captures the current locale, calls `models.allowAndInstall(for:recordingIsActive:)`, and returns immediately on failure or cancellation.
On success it enters `runtimeChanges.run`, stops the current pipeline coordinator before touching failed jobs, calls `MissingSpeechModelJobRetrier.requeue(jobStore:locale:)`, clears `runtime`, and calls `bootstrap()` once.
Stopping before requeue prevents the still-running coordinator from claiming the job just before the restart cancels it.

`revokeSpeechModelConsent` only calls `await models.revoke()`.
It does not stop the pipeline and does not delete installed assets.

- [ ] **Step 9: Run the full iOS app tests and build the iOS app**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
cd ..
scripts/build-ios.sh
```

Expected: all `StenoTests` pass and `scripts/build-ios.sh` ends with `BUILD SUCCEEDED`.

- [ ] **Step 10: Commit Task 2**

```bash
git add iOS/App/Sources/MissingSpeechModelJobRetrier.swift \
  iOS/App/Tests/MissingSpeechModelJobRetrierTests.swift \
  iOS/App/Sources/RuntimeChangeSerializer.swift \
  iOS/App/Tests/RuntimeChangeSerializerTests.swift \
  iOS/App/Sources/AppModel.swift
git commit -m "feat(ios): modellbedingt gescheiterte Transkription fortsetzen"
```

---

### Task 3: Modellzustand in Bereitschafts- und Aufnahmeoberflaeche

**Files:**
- Modify: `iOS/App/Sources/AudioReadinessView.swift:70-188`
- Modify: `iOS/App/Sources/RecordingView.swift:25-184`
- Modify: `iOS/App/Sources/ContentView.swift:77-91`
- Create: `iOS/App/Tests/RecordingPresentationTests.swift`

**Interfaces:**
- Consumes: `AppModel.models`, `AppModel.allowAndInstallSpeechModel()`, `AppModel.revokeSpeechModelConsent()`.
- Produces: `RecordingPresentation.modelMessage(isRecording:transcriptionFailure:modelReady:)` and navigation closure `showReadiness`.

- [ ] **Step 1: Write failing presentation-priority tests**

Create `iOS/App/Tests/RecordingPresentationTests.swift`:

```swift
import Testing
@testable import Steno

@Suite("Recording model presentation")
struct RecordingPresentationTests {
    @Test("missing model says recording continues without transcription")
    func missingModelMessage() {
        #expect(
            RecordingPresentation.modelMessage(
                isRecording: true,
                transcriptionFailure: nil,
                modelReady: false
            ) == "Recording without transcription. The speech model is not installed."
        )
    }

    @Test("a concrete transcription failure outranks generic model readiness")
    func concreteFailureWins() {
        #expect(
            RecordingPresentation.modelMessage(
                isRecording: true,
                transcriptionFailure: "SpeechAnalyzer failed",
                modelReady: false
            ) == "Recording. No live transcript: SpeechAnalyzer failed"
        )
    }

    @Test("model state is silent before readiness is known")
    func unknownReadinessIsSilent() {
        #expect(
            RecordingPresentation.modelMessage(
                isRecording: false,
                transcriptionFailure: nil,
                modelReady: nil
            ) == nil
        )
    }
}
```

- [ ] **Step 2: Run the presentation test and verify red**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/RecordingPresentationTests test
```

Expected: FAIL with `cannot find 'RecordingPresentation' in scope`.

- [ ] **Step 3: Add the minimal presentation helper and wire RecordingView**

Add this internal helper to `RecordingView.swift` below the view:

```swift
enum RecordingPresentation {
    static func modelMessage(
        isRecording: Bool,
        transcriptionFailure: String?,
        modelReady: Bool?
    ) -> String? {
        if let transcriptionFailure {
            return "Recording. No live transcript: \(transcriptionFailure)"
        }
        guard modelReady == false else { return nil }
        return isRecording
            ? "Recording without transcription. The speech model is not installed."
            : "The speech model is not installed. Recording still works."
    }
}
```

Change `RecordingView` to accept:

```swift
let showReadiness: () -> Void
```

Use `app.models.isReady(for: app.language.locale)` in `statusMessage` below interruption, audio failure and involuntary stop, but before the guessed-language warning.
When readiness is `false`, show a bordered `Button("Open audio readiness", action: showReadiness)` below the status.
The button may navigate during recording, but the installation action in `AudioReadinessView` stays disabled while `app.recording.isActive`.
Never include model readiness in `RecordingModel.canRecord` or the record button's `.disabled` expression.

- [ ] **Step 4: Add the model installation section to AudioReadinessView**

Within `Section("Speech recognition")`, after the language picker and before the raw installed-languages diagnostics, add one model subsection that renders:

```swift
ForEach(app.models.bundleDescriptions, id: \.title) { bundle in
    LabeledContent(bundle.title) {
        Text("\(bundle.source.displayHost), \(Self.sizeText(bundle.approximateBytes))")
    }
}
```

Render readiness with these exact Swift strings:

```swift
"Checking…"
"Ready for \(app.language.selectedDisplayName)."
"Not installed for \(app.language.selectedDisplayName)."
"Installing \(progress.title), \(Int((progress.fraction * 100).rounded())) %"
```

Add `Button("Allow and install")` calling `await app.allowAndInstallSpeechModel()` followed by `await model.refreshSpeechAvailability()`.
Disable it when `app.recording.isActive`, `app.models.isInstalling`, the language is not explicit, or the bundle list is empty.
While recording, show `Stop the recording before installing a model.` below the disabled button.
Show `app.models.errorMessage` in red.
If `app.models.consent.record` exists, show its date and sources plus `Button("Revoke", role: .destructive)` calling `await app.revokeSpeechModelConsent()`.
State explicitly: `Revoking stops future downloads. Models already installed keep working.`

Add a private static size formatter:

```swift
private static func sizeText(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
```

- [ ] **Step 5: Wire ContentView navigation and run tests**

Change the recording case in `ContentView` to:

```swift
RecordingView(showReadiness: { selection = .readiness })
```

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: all app tests pass with no new warning.

- [ ] **Step 6: Build both adaptive destinations and commit Task 3**

Run:

```bash
scripts/build-ios.sh
```

Expected: `BUILD SUCCEEDED` for the universal iPhone and iPad app.

Commit:

```bash
git add iOS/App/Sources/AudioReadinessView.swift \
  iOS/App/Sources/RecordingView.swift \
  iOS/App/Sources/ContentView.swift \
  iOS/App/Tests/RecordingPresentationTests.swift
git commit -m "feat(ios): Modellzustand sichtbar und Aufnahme unabhaengig halten"
```

---

### Task 4: Live-Revision und Final-ASR-Job idempotent persistieren

**Files:**
- Create: `iOS/App/Sources/RecordingFinalizer.swift`
- Create: `iOS/App/Tests/RecordingFinalizerTests.swift`
- Modify: `iOS/App/Sources/RecordingModel.swift:67-85,180-233`

**Interfaces:**
- Consumes: `TranscriptMapper.revision`, `Library.appendRevision`, `JobStore.enqueue`.
- Produces: `RecordingFinalizer.finalize(meetingID:output:library:jobStore:) async throws`.

- [ ] **Step 1: Write failing integration tests against a real temporary library**

Create `iOS/App/Tests/RecordingFinalizerTests.swift` with this fixture and three tests:

```swift
import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription
import Testing
@testable import Steno

@Suite("iOS recording finalization")
struct RecordingFinalizerTests {
    @Test("live output becomes one provisional revision and one final ASR job")
    func persistsLiveOutput() async throws {
        try await withFixture { library, store, meeting in
            let finalizer = RecordingFinalizer()
            let output = TranscriptOutput(
                localeIdentifier: "de-DE",
                blocks: [
                    TranscriptionBlock(
                        channel: .microphone,
                        text: "Hallo Welt",
                        start: 0,
                        end: 1,
                        words: [
                            TranscriptionWord(text: "Hallo", start: 0, end: 0.4),
                            TranscriptionWord(text: "Welt", start: 0.5, end: 1),
                        ]
                    ),
                ]
            )

            try await finalizer.finalize(
                meetingID: meeting.id,
                output: output,
                library: library,
                jobStore: store
            )

            let revision = try #require(
                try await library.loadCurrentRevision(meetingID: meeting.id)
            )
            let jobs = try await store.list()
            #expect(revision.origin == .liveProvisional)
            #expect(revision.turns.flatMap(\.segments).map(\.text) == ["Hallo Welt"])
            #expect(jobs.count == 1)
            #expect(jobs.first?.kind == .finalASR)
            #expect(jobs.first?.meetingID == meeting.id)
        }
    }

    @Test("missing live output still queues exactly one final ASR job")
    func missingOutputStillQueuesFinal() async throws {
        try await withFixture { library, store, meeting in
            let finalizer = RecordingFinalizer()
            try await finalizer.finalize(
                meetingID: meeting.id,
                output: nil,
                library: library,
                jobStore: store
            )
            #expect(try await library.loadCurrentRevision(meetingID: meeting.id) == nil)
            #expect(try await store.list().count == 1)
        }
    }

    @Test("concurrent and later duplicate calls persist nothing twice")
    func duplicateCallsAreIdempotent() async throws {
        try await withFixture { library, store, meeting in
            let finalizer = RecordingFinalizer()
            let output = TranscriptOutput(localeIdentifier: "de-DE", blocks: [])
            async let first: Void = finalizer.finalize(
                meetingID: meeting.id,
                output: output,
                library: library,
                jobStore: store
            )
            async let second: Void = finalizer.finalize(
                meetingID: meeting.id,
                output: output,
                library: library,
                jobStore: store
            )
            _ = try await (first, second)
            try await finalizer.finalize(
                meetingID: meeting.id,
                output: output,
                library: library,
                jobStore: store
            )
            #expect(try await store.list().count == 1)
        }
    }
}
```

Add a file-private `withFixture` helper that creates a unique directory under `FileManager.default.temporaryDirectory`, removes it with `defer`, opens `Library`, creates a `.ready` meeting and constructs `JobStore`.

- [ ] **Step 2: Run the focused finalizer tests and verify red**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/RecordingFinalizerTests test
```

Expected: FAIL with `cannot find 'RecordingFinalizer' in scope`.

- [ ] **Step 3: Implement the actor with stable prepared IDs**

Create `iOS/App/Sources/RecordingFinalizer.swift`.
The actor stores three dictionaries or sets:

```swift
actor RecordingFinalizer {
    private struct Prepared: Sendable {
        let revision: TranscriptRevision?
        let job: Job
    }

    private var prepared: [MeetingID: Prepared] = [:]
    private var inFlight: [MeetingID: Task<Void, Error>] = [:]
    private var completed: Set<MeetingID> = []
}
```

`finalize` follows this exact order:

1. Return when `completed` already contains the meeting.
2. Await and return an existing `inFlight` task for the meeting.
3. Reuse `prepared[meetingID]`, or create one stable `TranscriptRevision` and one stable `Job` exactly once.
4. Start one task that persists the prepared revision if its file does not exist and enqueues the prepared job if its file does not exist.
5. On success add the meeting to `completed`, clear `prepared` and `inFlight`.
6. On failure clear only `inFlight`, keep `prepared` with the stable IDs, and rethrow.

Use the public nonisolated layouts for existence checks:

```swift
library.layout.revision(meetingID, revisionID: revision.id)
jobStore.layout.job(job.id)
```

If a file already exists, load and validate it instead of treating every existing file as success.
For a revision require full equality with the prepared value.
For a job require the same ID, kind and meeting ID, while allowing its mutable status, attempt count and error message to differ because the pipeline may already have claimed it.
Throw an internal `RecordingFinalizerError.conflictingArtifact` on mismatch.

Create no revision when `output` is `nil` or `output.blocks.isEmpty`.
Always prepare the final-ASR job.

- [ ] **Step 4: Run finalizer tests and verify green**

Run the command from Step 2.

Expected: all three tests pass and every fixture contains at most one job document.

- [ ] **Step 5: Replace inline persistence in RecordingModel**

In `RecordingModel` add:

```swift
private let finalizer: RecordingFinalizer
```

Extend its initializer:

```swift
init(
    session: AudioSessionController,
    finalizer: RecordingFinalizer = RecordingFinalizer()
) {
    audioSession = session
    self.finalizer = finalizer
}
```

Replace lines 212-227 of the current `performStop` with:

```swift
if let runtime, let recordedMeeting {
    do {
        try await finalizer.finalize(
            meetingID: recordedMeeting,
            output: output,
            library: runtime.library,
            jobStore: runtime.jobStore
        )
    } catch {
        state = .failed(error.localizedDescription)
    }
}
```

Do not change the order in `tearDown`.
The recording session must still close and register the original before awaiting the live task and before finalization.

- [ ] **Step 6: Run all iOS tests and both app builds**

Run:

```bash
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
cd ..
scripts/build-app.sh
scripts/build-ios.sh
```

Expected: all app tests pass and both builds end with `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit Task 4**

```bash
git add iOS/App/Sources/RecordingFinalizer.swift \
  iOS/App/Tests/RecordingFinalizerTests.swift \
  iOS/App/Sources/RecordingModel.swift
git commit -m "fix(ios): Live-Revision beim Stop idempotent sichern"
```

---

### Task 5: Vollverifikation, Dokumentation und Geraeteabnahme

**Files:**
- Modify: `docs/PLAN-IOS.md:274-288`
- Create: `docs/BENCH-IOS-I1-MODELS.md`
- Update without committing when work remains: `HANDOFF-audio-core-extraction.md`

**Interfaces:**
- Consumes: alle vorherigen Tasks.
- Produces: reproduzierbarer Testnachweis und ehrliche iPhone-Abnahme.

- [ ] **Step 1: Run the complete local verification from a clean generated-project state**

Run in this order:

```bash
git status --short
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit
cd iOS
xcodegen generate --quiet
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
cd StenoiOSKit
xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected:

- `git status --short` lists only the intended task files and the unrelated untracked `UEBERGABE-sprecher-erkenntnisse.md`.
- macOS and iOS builds report `BUILD SUCCEEDED`.
- all 329 or more StenoKit tests pass.
- all 26 or more `StenoiOSKit` tests pass.
- every `StenoTests` test passes.

Classify every failure as caused by this change, pre-existing, environment-related or flaky before proceeding.

- [ ] **Step 2: Review the complete branch diff for the recording and privacy invariants**

Run:

```bash
git diff main...HEAD -- iOS StenoKit docs/PLAN-IOS.md docs/BENCH-IOS-I1-MODELS.md
rg -n "ModelInstallationCoordinator\.standard|DiarizationModelInstaller|Locale\.current" iOS/App/Sources
rg -n "allowAndInstall|install\(" iOS/App/Sources
```

Expected:

- no iOS call to `ModelInstallationCoordinator.standard`,
- no iOS construction of `DiarizationModelInstaller`,
- no new `Locale.current` in a transcription call,
- exactly one user-triggered installation entry point,
- no model readiness check in `RecordingModel.canRecord` or before audio capture starts.

- [ ] **Step 3: Install on the target iPhone only when the device is available**

Run:

```bash
scripts/build-ios.sh --device
```

Expected: the script names an available iPhone or iPad, builds successfully and installs `org.steno.Steno`.
If no device is available, do not claim the device test.
Record the missing device check in `HANDOFF-audio-core-extraction.md` and stop before marking i1.7 complete.

- [ ] **Step 4: Perform the installed-model device flow**

On the iPhone:

1. Open Audio readiness and confirm German is selected explicitly.
2. Confirm the German speech model reports ready.
3. Start a short recording and speak until final live text is visible.
4. Stop the recording and open the new meeting.
5. Confirm the live text is visible before the final run replaces it.
6. Force-quit and reopen Steno.
7. Confirm the meeting still contains a transcript.
8. Inspect the library job documents locally only if the UI cannot distinguish the provisional and final states.

Do not inspect or copy unrelated meetings from reale library.

- [ ] **Step 5: Perform the missing-model flow without risking the existing German asset**

Use a different language that `AudioReadinessView` reports as supported but not installed.
Do not delete or alter German systemassets.

On the iPhone:

1. Select the supported uninstalled language while no recording runs.
2. Confirm no download starts before `Allow and install`.
3. Start a short recording without installing.
4. Confirm the UI says recording continues without transcription.
5. Stop and confirm the meeting has an original audio track.
6. Confirm its final-ASR job fails with the exact missing-model message.
7. Press `Allow and install` and observe source Apple, size and progress.
8. Confirm that exact failed final-ASR job returns to `queued` and finishes.
9. Confirm no Diarization download starts.

- [ ] **Step 6: Write the measured device report**

Create `docs/BENCH-IOS-I1-MODELS.md` with full sentences on separate physical lines and the headings below.
Before writing, read the device name and iOS version from `xcrun devicectl list devices` and `xcrun devicectl device info details`, and read the commit from `git rev-parse --short HEAD`.
Write each measured value directly after its label.
Do not leave any label empty.

```markdown
# iOS i1 - Modellinstallation und Live-Revision

Stand: 2026-08-08.
Geraet und iOS-Version
Build-Commit

## Installiertes Modell

- Gewaehlte Sprache
- Live-Text vor Stop sichtbar
- Provisorische Revision nach Stop sichtbar
- Revision nach Neustart sichtbar
- Anzahl Final-ASR-Jobs fuer das Meeting

## Fehlendes Modell

- Gewaehlte Sprache
- Download vor Zustimmung beobachtet
- Audio ohne Modell erhalten
- Angezeigte Quelle und Groesse
- Modellbedingt gescheiterter Job erneut verarbeitet
- Diarisierungsdownload beobachtet

## Grenzen

Nur die oben genannten Ablaeufe wurden auf echter Hardware geprueft.
```

If a field could not be measured, write `nicht geprueft` plus the reason instead of guessing.

- [ ] **Step 7: Update the iOS plan only after the evidence exists**

In `docs/PLAN-IOS.md`, replace the open marker on i1 step 7 with a completed paragraph that names:

- the iOS-only `SpeechAssetInstaller` composition,
- explicit Apple-only consent in i1,
- the fact that recording stays available without the model,
- the exact commit and device report proving it.

Do not mark i2 Diarization installation complete.

- [ ] **Step 8: Run final documentation checks and commit Task 5**

Run:

```bash
rg -n "TBD|TODO|nicht geprueft|—|–" \
  docs/PLAN-IOS.md docs/BENCH-IOS-I1-MODELS.md
git diff --check
git status --short
```

Expected: no placeholder or forbidden dash, no whitespace error, and `UEBERGABE-sprecher-erkenntnisse.md` remains untracked.

Commit only the evidence and plan update:

```bash
git add docs/PLAN-IOS.md docs/BENCH-IOS-I1-MODELS.md
git commit -m "docs(ios): Modellinstallation und Live-Revision am Geraet belegen"
```

- [ ] **Step 9: Final branch verification and handoff hygiene**

Run:

```bash
git status --short --branch
git log -8 --oneline --decorate
```

Expected: only the unrelated untracked `UEBERGABE-sprecher-erkenntnisse.md` remains.
If any required device step is open, update `HANDOFF-audio-core-extraction.md` with branch, last commit, completed checks and the exact open device step, and do not commit that handoff.
If every step is complete, preserve the existing handoff until the broader iOS-port task itself is complete, because that file owns more open work than this package.
