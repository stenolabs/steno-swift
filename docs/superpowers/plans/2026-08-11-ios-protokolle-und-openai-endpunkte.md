# iOS-Protokolle und OpenAI-kompatible Endpunkte Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die iPhone- und iPad-App erzeugt versionierte Protokolle mit Apple Foundation Models als Standard oder einem bewusst ausgewaehlten OpenAI-kompatiblen Endpunkt und kann Ergebnisse anzeigen, erneut erzeugen, abbrechen, kopieren und teilen.

**Architecture:** Der bestehende gemeinsame Renderpfad bleibt die einzige fachliche Implementierung. Ein gemeinsamer Preflight erzeugt Render-Kontext und Datenschutzmanifest aus derselben Quelle, iOS ergaenzt nur Endpunktverwaltung, AppModel-Zugaenge und eine zustandsfeste SwiftUI-Darstellung. Jede Ausfuehrung pinnt Revision und optionale Endpunkt-ID in einem persistenten Job, waehrend API-Schluessel ausschliesslich im Keychain liegen.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, Foundation Models, URLSession, Security/Keychain, Swift Testing, XcodeGen, iOS/iPadOS 26.

**Spec:** `docs/superpowers/specs/2026-08-11-ios-foundation-models-reports-design.md`

## Global Constraints

- Apple Foundation Models bleibt nach jedem kalten App-Start der ausgewaehlte Standard.
- Ein externer Endpunkt wird nur durch `Test connection`, `Generate minutes` oder `Regenerate` kontaktiert.
- Es gibt keinen automatischen externen Fallback, keinen Hintergrund-Ping und keine automatische Anbieterwahl.
- Steno kennt keine LM-Studio-, Tailscale-, VPN-, LAN- oder Cloud-Sonderlogik.
- Jeder Protokolljob pinnt die aktuelle Transkriptrevision und die optionale Endpunkt-ID.
- Jeder neue Protokolljob pinnt den Fingerabdruck genau des Preflights, dessen Datenschutzhinweis sichtbar war.
- Eine nach dem Preflight veraenderte Prompt-Eingabe scheitert vor jedem Provideraufruf und wird erst nach einem sichtbaren neuen Preflight erneut gestartet.
- Eine geloeschte oder unbekannte Endpunkt-ID darf nie still auf Apple zurueckfallen.
- Endpunktkonfigurationen enthalten kein Schluesselmaterial; API-Schluessel liegen ausschliesslich im Keychain.
- Externe Nutzlasten enthalten nur das Transkript mit bestaetigten Sprechernamen, Teilnehmernamen und Firmen sowie eigene Meetingnotizen, soweit diese Klassen vorhanden sind.
- Audio, E-Mail-Adressen, Dokumente und Bilder erreichen keinen Textmodellprovider.
- Der angezeigte Uebertragungshinweis und die tatsaechliche Providernutzlast werden aus derselben typisierten Datenklassenbeschreibung abgeleitet.
- Nicht lesbare Notizen verhindern das Einreihen, beeintraechtigen aber weder Aufnahme noch Transkript oder bestehende Protokolle.
- Unbestaetigte Sprecher bleiben generische Sprecher und Cluster mit mehreren Stimmen erhalten keinen Personennamen.
- Eine laufende oder fehlgeschlagene Neuerzeugung laesst bestehende Ergebnisversionen sichtbar und unveraendert.
- Navigation oder View-Cancellation darf den persistenten Job nicht abbrechen.
- Der Simulator gilt nicht als Abnahme des echten `SystemLanguageModel`.
- Kein neues Drittanbieterpaket wird hinzugefuegt.
- Nach jeder Aenderung in `StenoKit` laeuft abschliessend XcodeGen, macOS-Build, iOS-Build und die vollstaendige StenoKit-Suite.

## File Map

- `StenoKit/Sources/StenoIntelligence/OutboundDisclosure.swift` definiert die erlaubten Prompt-Datenklassen und leitet daraus das Manifest ab.
- `StenoKit/Sources/StenoIntelligence/TextModelEndpointPolicy.swift` validiert Endpunkt-URLs und klassifiziert unverschluesselte lokale Verbindungen.
- `StenoKit/Sources/StenoPipeline/TemplateRenderInputAssembler.swift` baut Revision, Teilnehmer, Notizen und Disclosure gemeinsam fuer Preflight und Ausfuehrung.
- `StenoKit/Sources/StenoDomain/Job.swift` speichert den optionalen Eingabefingerabdruck abwaertskompatibel fuer neue Protokolljobs.
- `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift` verwendet den gemeinsamen Assembler statt eigener Kontextzusammenstellung.
- `StenoKit/Sources/StenoLibrary/JobStore.swift` reiht einen Renderjob atomar ein oder liefert den bereits blockierenden Job.
- `StenoKit/Sources/StenoPipeline/TemplateRenderRequest.swift` gibt dadurch auch bei zwei schnellen Aufrufen genau einen beobachtbaren Job zurueck.
- `iOS/App/Sources/TextModelSettings.swift` verwaltet Endpunktliste, sitzungsgebundene Auswahl, Keychain und Pipeline-Resolver.
- `iOS/App/Sources/TextModelSettingsView.swift` stellt Endpunkte und den ausschliesslich manuellen Verbindungstest dar.
- `iOS/App/Sources/AppModel+Reports.swift` ist die schmale iOS-Fassade fuer Preflight, Jobs, Ergebnisse, Einreihen und Abbruch.
- `iOS/App/Sources/MeetingReportsPresentation.swift` enthaelt die reine Zustandsmaschine fuer Version, In-Flight-Gate, Jobabgleich und Teilenutzlast.
- `iOS/App/Sources/MeetingReportsSection.swift` zeigt Modellwahl, Disclosure, Status, Versionen, Markdown, Copy und Share.
- `iOS/App/Sources/MarkdownLiteView.swift` rendert das gespeicherte Markdown ohne WebView.
- `iOS/App/Sources/MeetingDetailView.swift` setzt `Minutes` vor das Transkript.
- `iOS/App/Sources/NavigationRouter.swift`, `iOS/App/Sources/ContentView.swift` und `iOS/App/Sources/StenoApp.swift` binden die Sprachmodell-Einstellungen und ihre prozessweite Umgebung ein.
- `iOS/project.yml` erklaert den lokalen Netzwerkzugriff ohne eine allgemeine ATS-Freigabe.

---

### Task 1: Gemeinsames Nutzlastmanifest und sicherer Endpunktvertrag

**Files:**

- Create: `StenoKit/Sources/StenoIntelligence/OutboundDisclosure.swift`
- Create: `StenoKit/Sources/StenoIntelligence/TextModelEndpointPolicy.swift`
- Create: `StenoKit/Tests/StenoIntelligenceTests/OutboundDisclosureTests.swift`
- Create: `StenoKit/Tests/StenoIntelligenceTests/TextModelEndpointPolicyTests.swift`
- Create: `StenoKit/Sources/StenoPipeline/TemplateRenderInputAssembler.swift`
- Modify: `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift:245-290`
- Modify: `StenoKit/Sources/StenoPipeline/TemplateParticipants.swift:17-116`
- Create: `StenoKit/Tests/StenoPipelineTests/TemplateRenderInputAssemblerTests.swift`
- Modify: `StenoKit/Tests/StenoPipelineTests/TemplateRenderPipelineTests.swift`

**Interfaces:**

- Consumes: `TranscriptRevision`, `RenderContext`, `MeetingReviewAssembler.loadForRendering`, `TemplateParticipants`, `MeetingNotesStore` und `Library`.
- Produces: `PromptDataClass`, `OutboundDisclosure`, `TextModelEndpointPolicy`, `TemplateRenderPreflight` und den internen `TemplateRenderInput`.
- Exact public API:

```swift
public enum PromptDataClass: String, CaseIterable, Codable, Sendable {
    case transcriptWithSpeakerNames
    case participants
    case userNotes

    public var displayName: String { get }
}

public struct OutboundDisclosure: Equatable, Sendable {
    public let classes: [PromptDataClass]
    public init(transcript: TranscriptRevision, context: RenderContext)
}

public enum TextModelTransportSecurity: Equatable, Sendable {
    case encrypted
    case localPlaintext
}

public enum TextModelEndpointPolicy {
    public static func transportSecurity(for url: URL) throws
        -> TextModelTransportSecurity
    public static func validate(_ endpoint: TextModelEndpoint) throws
        -> TextModelEndpoint
}

public struct TemplateRenderPreflight: Equatable, Sendable {
    public let meetingID: MeetingID
    public let revisionID: RevisionID
    public let disclosure: OutboundDisclosure
    public let inputFingerprint: String
}

public enum TemplateRenderInputAssembler {
    public static func preflight(
        library: Library,
        meetingID: MeetingID
    ) async throws -> TemplateRenderPreflight

    public static func validate(
        _ preflight: TemplateRenderPreflight,
        library: Library
    ) async throws
}
```

- Invariant: Der interne Ausfuehrungspfad und der oeffentliche Preflight rufen dieselbe private Assembly-Funktion auf.
- Invariant: Der Fingerabdruck kodiert das aufgeloeste Transkript, `participants`, `context.participants` und `context.userNotes` mit sortierten JSON-Schluesseln und hasht diese Bytes mit SHA-256.

- [ ] **Step 1: Write failing disclosure and URL-policy tests**

`OutboundDisclosureTests` konstruiert drei kleine Revisionen und Kontexte und erwartet diese exakten Folgen:

```swift
#expect(
    OutboundDisclosure(transcript: revisionWithTurns, context: .empty).classes
        == [.transcriptWithSpeakerNames]
)
#expect(
    OutboundDisclosure(
        transcript: revisionWithTurns,
        context: RenderContext(participants: ["Ada Lovelace"])
    ).classes == [.transcriptWithSpeakerNames, .participants]
)
#expect(
    OutboundDisclosure(
        transcript: revisionWithTurns,
        context: RenderContext(userNotes: "Project Aurora", participants: ["Ada"])
    ).classes == [.transcriptWithSpeakerNames, .participants, .userNotes]
)
#expect(PromptDataClass.allCases.count == 3)
```

`TextModelEndpointPolicyTests` erwartet:

```swift
#expect(try policy("https://models.example.com/v1") == .encrypted)
#expect(try policy("http://localhost:1234/v1") == .localPlaintext)
#expect(try policy("http://studio.local:1234/v1") == .localPlaintext)
#expect(try policy("http://macbook:1234/v1") == .localPlaintext)
#expect(try policy("http://192.168.1.10:1234/v1") == .localPlaintext)
#expect(try policy("http://100.64.10.20:1234/v1") == .localPlaintext)
#expect(throws: TextModelEndpointPolicyError.insecureRemoteURL) {
    try policy("http://models.example.com/v1")
}
#expect(throws: TextModelEndpointPolicyError.embeddedCredentials) {
    try policy("https://user:secret@models.example.com/v1")
}
```

Weitere Faelle decken `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`, `::1`, `fc00::/7` und `fe80::/10` sowie abgelehnte Query- und Fragmentteile ab.

- [ ] **Step 2: Run the focused StenoIntelligence tests and verify RED**

Run: `swift test --package-path StenoKit --filter OutboundDisclosureTests`

Run: `swift test --package-path StenoKit --filter TextModelEndpointPolicyTests`

Expected: compile failure because the two new public APIs do not exist.

- [ ] **Step 3: Implement the manifest and URL policy**

`OutboundDisclosure` appends classes in enum order and only when the corresponding value is present.
An empty revision does not report transcript data, an empty participant array does not report participants, and `RenderContext` already normalizes blank notes to `nil`.

`TextModelEndpointPolicy` rejects missing host, schemes other than `http` or `https`, embedded user/password, query and fragment.
`https` returns `.encrypted`.
`http` returns `.localPlaintext` only for the exact host families listed in Step 1.
The implementation parses IPv4 octets numerically and IPv6 through `IPv6Address` from `Network`, then checks prefix bits instead of relying on string prefixes.

- [ ] **Step 4: Write the failing shared-input tests**

`TemplateRenderInputAssemblerTests` creates a temporary library with current revision, confirmed participant plus organization, additional participant and `user-notes.md`.
It expects `preflight.disclosure.classes` to contain all three cases.
A second test stores invalid UTF-8 in `user-notes.md` and expects the preflight to throw before a provider is resolved or a job is created.

Add a sentinel test to `TemplateRenderPipelineTests`.
It places unique markers in transcript, participant name, organization and notes, executes a render through a recording fake provider and asserts:

```swift
#expect(seenPayload.contains("TRANSCRIPT_SENTINEL"))
#expect(seenPayload.contains("PARTICIPANT_SENTINEL"))
#expect(seenPayload.contains("ORGANIZATION_SENTINEL"))
#expect(seenPayload.contains("NOTES_SENTINEL"))
#expect(!seenPayload.contains("EMAIL_SENTINEL"))
#expect(!seenPayload.contains("AUDIO_SENTINEL"))
#expect(disclosure.classes == [.transcriptWithSpeakerNames, .participants, .userNotes])
```

- [ ] **Step 5: Refactor the coordinator onto one assembler**

The internal type is:

```swift
struct TemplateRenderInput: Sendable {
    let transcript: TranscriptRevision
    let participants: [String]
    let context: RenderContext

    var disclosure: OutboundDisclosure {
        OutboundDisclosure(transcript: transcript, context: context)
    }
}
```

`TemplateRenderInputAssembler` loads the pinned revision for execution, uses `MeetingReviewAssembler.loadForRendering`, resolves only confirmed speaker names, builds the same `TemplateParticipants.list`, reads notes throwing and returns the input.
The public preflight loads the current revision and returns meeting ID, revision ID, disclosure and the deterministic fingerprint of that exact assembled input.
Move only the necessary `TemplateParticipants` entry points from internal to package-visible or public scope; do not duplicate its speaker truth rules.
Replace the context-building block in `PipelineCoordinator.executeTemplateRender` with the assembler result and pass its `transcript`, `participants` and `context` to the selected provider.

- [ ] **Step 6: Run focused core tests and commit**

Run: `swift test --package-path StenoKit --filter OutboundDisclosureTests`

Run: `swift test --package-path StenoKit --filter TextModelEndpointPolicyTests`

Run: `swift test --package-path StenoKit --filter TemplateRenderInputAssemblerTests`

Run: `swift test --package-path StenoKit --filter TemplateRenderPipelineTests`

Expected: all focused suites pass and the existing invalid-notes test still fails closed before provider invocation.

```bash
git add StenoKit/Sources/StenoIntelligence/OutboundDisclosure.swift \
  StenoKit/Sources/StenoIntelligence/TextModelEndpointPolicy.swift \
  StenoKit/Sources/StenoPipeline/TemplateRenderInputAssembler.swift \
  StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift \
  StenoKit/Sources/StenoPipeline/TemplateParticipants.swift \
  StenoKit/Tests/StenoIntelligenceTests/OutboundDisclosureTests.swift \
  StenoKit/Tests/StenoIntelligenceTests/TextModelEndpointPolicyTests.swift \
  StenoKit/Tests/StenoPipelineTests/TemplateRenderInputAssemblerTests.swift \
  StenoKit/Tests/StenoPipelineTests/TemplateRenderPipelineTests.swift
git commit -m "feat(intelligence): externe Nutzlast ausweisen"
```

### Task 2: iOS-Endpunktregister, Keychain und manueller Verbindungstest

**Files:**

- Create: `iOS/App/Sources/TextModelSettings.swift`
- Create: `iOS/App/Sources/TextModelSettingsView.swift`
- Modify: `iOS/App/Sources/StenoApp.swift:3-18`
- Modify: `iOS/App/Sources/NavigationRouter.swift:4-24`
- Modify: `iOS/App/Sources/ContentView.swift:52-103`
- Modify: `iOS/project.yml:43-72`
- Create: `iOS/App/Tests/TextModelSettingsTests.swift`
- Create: `iOS/App/Tests/TextModelEndpointPresentationTests.swift`
- Modify: `iOS/App/Tests/NavigationRouterTests.swift`

**Interfaces:**

- Consumes: `TextModelEndpoint`, `TextModelEndpointPolicy`, `OpenAICompatibleProvider.probe(endpoint:)`, `TextModelSecretResolving` und Security.framework.
- Produces: `@MainActor @Observable final class TextModelSettings`, `TextModelKeychain`, `EndpointDraft`, `TextModelSettingsView` und `SidebarItem.languageModels`.
- Exact settings API:

```swift
@MainActor
@Observable
final class TextModelSettings {
    private(set) var endpoints: [TextModelEndpoint]
    var selectedEndpointID: UUID?
    var selectedEndpoint: TextModelEndpoint? { get }

    func upsert(_ endpoint: TextModelEndpoint, apiKey: String?) throws
    func remove(_ endpoint: TextModelEndpoint)
    func endpoint(withID id: String?) -> TextModelEndpoint?
    func resetSelectionForColdLaunch()

    nonisolated static func resolveProvider(
        endpointID: String?
    ) throws -> any TextModelProvider
}
```

- Invariant: Endpunkte persistieren, `selectedEndpointID` jedoch nicht.

- [ ] **Step 1: Write failing persistence and secret-separation tests**

`TextModelSettingsTests` verwendet eine eindeutige `UserDefaults(suiteName:)` und einen injizierten In-Memory-Secret-Store.
Die Tests erwarten:

```swift
try first.upsert(endpoint, apiKey: "secret")
let raw = try #require(defaults.data(forKey: TextModelSettings.endpointsDefaultsKey))
#expect(!String(decoding: raw, as: UTF8.self).contains("secret"))
#expect(secrets.value(for: endpoint.id) == "secret")

first.selectedEndpointID = endpoint.id
let second = TextModelSettings(defaults: defaults, secrets: secrets)
#expect(second.endpoints == [endpoint])
#expect(second.selectedEndpointID == nil)
```

Weitere Tests pruefen Aendern ohne neuen Key, explizites Ersetzen, Loeschen samt Keychain-Eintrag, Zuruecksetzen der Auswahl beim Loeschen und Ablehnung einer vom `TextModelEndpointPolicy` verbotenen URL.

- [ ] **Step 2: Verify the iOS settings tests fail to compile**

Run: `cd iOS && xcodegen generate && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" -only-testing:StenoTests/TextModelSettingsTests test`

Expected: compile failure because `TextModelSettings` and its injected secret store do not exist.

- [ ] **Step 3: Implement settings and Keychain storage**

Port the existing Mac storage shape without persisted selection.
Use `steno.textmodel.endpoints` for the endpoint data and Keychain service `org.steno.textmodel` with account equal to the endpoint UUID.
The production resolver reads the persisted endpoint list and resolves the Keychain value at job execution time.
If `endpointID` is `nil`, it returns `FoundationModelsProvider()`.
If the endpoint no longer exists, it throws `PipelineError.unknownTextModelEndpoint(endpointID)`.

`EndpointDraft.validated` trims name, URL and model ID, constructs `TextModelEndpoint`, calls `TextModelEndpointPolicy.validate`, and exposes the exact validation message beside the save button.
The API-key field never reads an existing key back into SwiftUI; an empty field during edit means unchanged.

- [ ] **Step 4: Write and implement navigation plus presentation tests**

`TextModelEndpointPresentationTests` expects:

- an HTTPS endpoint has no plaintext warning,
- a permitted HTTP endpoint shows `This connection is not encrypted.`,
- `Test connection` success distinguishes model present from model absent,
- connection, authentication and invalid-response errors use `localizedDescription` without key or transcript content.

Extend `NavigationRouterTests` so `.languageModels` is independent between two window routers.
Add `Language models` to the Tools section and render `TextModelSettingsView` in the detail switch.

`StenoApp` owns one process-wide settings object and injects it:

```swift
@State private var model = AppModel()
@State private var textModels = TextModelSettings()

WindowGroup {
    ContentView()
        .environment(model)
        .environment(textModels)
        .task { await model.bootstrap() }
}
```

The settings view starts `probe` only from its button action.
It constructs `OpenAICompatibleProvider(endpoint:resolvingSecret:)` with the Keychain resolver and never probes from `.task`, `init` or `onAppear`.

- [ ] **Step 5: Declare narrow local networking and verify**

Add these generated Info.plist properties in `iOS/project.yml`:

```yaml
NSLocalNetworkUsageDescription: Steno connects to a language model server only when you test it or explicitly generate minutes with it.
NSAppTransportSecurity:
  NSAllowsLocalNetworking: true
```

Do not add `NSAllowsArbitraryLoads` or a wildcard exception domain.

Run: `cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" -only-testing:StenoTests/TextModelSettingsTests -only-testing:StenoTests/TextModelEndpointPresentationTests -only-testing:StenoTests/NavigationRouterTests test`

Run: `scripts/build-ios.sh --ipad-simulator`

Expected: focused tests pass, the generated Info.plist contains the usage description and local-only ATS key, and the settings screen opens on iPhone and iPad layouts.

- [ ] **Step 6: Commit the endpoint register**

```bash
git add iOS/App/Sources/TextModelSettings.swift \
  iOS/App/Sources/TextModelSettingsView.swift \
  iOS/App/Sources/StenoApp.swift \
  iOS/App/Sources/NavigationRouter.swift \
  iOS/App/Sources/ContentView.swift \
  iOS/project.yml \
  iOS/App/Tests/TextModelSettingsTests.swift \
  iOS/App/Tests/TextModelEndpointPresentationTests.swift \
  iOS/App/Tests/NavigationRouterTests.swift
git commit -m "feat(ios): Textmodell-Endpunkte verwalten"
```

### Task 3: Gepinnter, idempotenter Protokolljob und iOS-AppModel-Fassade

**Files:**

- Modify: `StenoKit/Sources/StenoDomain/Job.swift`
- Modify: `StenoKit/Sources/StenoLibrary/JobStore.swift:25-58`
- Modify: `StenoKit/Sources/StenoPipeline/TemplateRenderRequest.swift:4-35`
- Modify: `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift`
- Modify: `StenoKit/Sources/StenoPipeline/PipelineError.swift`
- Modify: `StenoKit/Tests/StenoLibraryTests/JobStoreTests.swift`
- Modify: `StenoKit/Tests/StenoPipelineTests/TemplateRenderPipelineTests.swift`
- Modify: `iOS/App/Sources/AppModel.swift:40-145,148-176`
- Create: `iOS/App/Sources/AppModel+Reports.swift`
- Create: `iOS/App/Tests/MeetingReportsIntegrationTests.swift`

**Interfaces:**

- Consumes: `TextModelSettings.resolveProvider`, `TemplateRenderInputAssembler.preflight`, `TemplateResultStore`, `JobStore` und `PipelineCoordinator.cancel(jobID:)`.
- Produces: atomare `JobStore.enqueueOrExistingEquivalentJob`, gepinntes `Job.templateRenderInputFingerprint`, `TemplateRenderRequest.enqueue(...preflight:) async throws -> Job` und die iOS-Report-Fassade.
- Exact AppModel API:

```swift
func reportPreflight(for meetingID: MeetingID) async throws
    -> TemplateRenderPreflight
func reports(for meetingID: MeetingID) async throws
    -> [StoredTemplateResult]
func jobs(for meetingID: MeetingID) async throws -> [Job]
func requestMeetingMinutes(
    meetingID: MeetingID,
    textModelEndpointID: String?,
    preflight: TemplateRenderPreflight
) async throws -> Job
func cancelReportJob(_ jobID: JobID) async throws
```

- Invariant: Zwei konkurrierende Aufrufe liefern nur dann dieselbe blockierende Job-ID, wenn Template, Revision, Endpunkt, Eingabefingerabdruck, Quelllauf und Importgeneration gleich sind.

- [ ] **Step 1: Write the concurrent enqueue RED**

Erweitere `JobStoreTests` um blockierende Protokolljobs, die sich einzeln in `templateID`, `revisionID`, `textModelEndpointID` oder `templateRenderInputFingerprint` unterscheiden.
Erwarte fuer identische Eingaben dieselbe zurueckgegebene ID und fuer jede fachlich abweichende Eingabe einen eigenen Job.

Erweitere `TemplateRenderPipelineTests` um zwei konkurrierende `TemplateRenderRequest.enqueue`-Aufrufe fuer dasselbe Meeting und verschiedene frisch erzeugte Job-Objekte.
Erwarte dieselbe ID, gepinnte Revision und gepinnte Endpunkt-ID.

- [ ] **Step 2: Run RED and implement atomic return-existing behavior**

Run: `swift test --package-path StenoKit --filter JobStoreTests`

Run: `swift test --package-path StenoKit --filter TemplateRenderPipelineTests`

Expected: compile or semantic failure because the store currently returns only `Bool` and `TemplateRenderRequest` calls plain `enqueue`.

Add:

```swift
@discardableResult
public func enqueueOrExistingEquivalentJob(
    _ job: Job,
    blockingStatuses: [Job.Status]
) throws -> Job {
    if let existing = try list().first(where: {
        $0.meetingID == job.meetingID
            && $0.kind == job.kind
            && $0.sourceRunID == job.sourceRunID
            && $0.templateID == job.templateID
            && $0.revisionID == job.revisionID
            && $0.textModelEndpointID == job.textModelEndpointID
            && $0.templateRenderInputFingerprint
                == job.templateRenderInputFingerprint
            && $0.importGenerationID == job.importGenerationID
            && blockingStatuses.contains($0.status)
    }) {
        return existing
    }
    try enqueue(job)
    return job
}
```

Keep the existing Boolean API for current review callers and implement both through one private equivalence predicate.
Change `TemplateRenderRequest.enqueue` to require the visible `TemplateRenderPreflight`, reject a mismatching meeting or stale fingerprint before enqueue, and return `enqueueOrExistingEquivalentJob(job, blockingStatuses: [.queued, .running])`.

- [ ] **Step 3: Write failing AppModel report integration tests**

`MeetingReportsIntegrationTests` creates a temporary `PipelineRuntime` and expects:

- `reportPreflight` returns the three-class disclosure for a prepared fixture,
- unreadable notes throw and leave `jobStore.list()` empty,
- `requestMeetingMinutes` pins `Template.meetingMinutes.id`, revision and endpoint UUID,
- `requestMeetingMinutes` pins exactly the supplied preflight fingerprint,
- a preflight from another meeting or changed prompt input leaves the job store empty,
- a nach dem Einreihen veraenderte Notiz laesst die Pipeline vor dem Fake-Provider mit `PipelineError.templateRenderInputChanged` scheitern und der Fake-Provider zeichnet null Aufrufe auf,
- a schema-1 Apple job without external endpoint ID or `templateRenderInputFingerprint` still decodes and follows the existing compatibility path,
- a schema-1 external job without fingerprint or a complete revision-pinned endpoint snapshot fails before input assembly, resolver and provider construction and requires an explicit new generation,
- two concurrent requests return the same JobID,
- `reports` returns newest first from `TemplateResultStore`,
- `jobs` filters out other meetings,
- `cancelReportJob` transitions a queued job to `.cancelled`,
- cancellation in the calling UI task after enqueue does not delete or cancel the persistent job.

- [ ] **Step 4: Implement bootstrap resolver and AppModel facade**

Change the stored runtime declaration to `private(set) var runtime: PipelineRuntime?` so an extension in the same module can read it but only `AppModel.swift` can replace it.
Add a resolver property to `AppModel.init`, defaulting to `TextModelSettings.resolveProvider`.
Pass it to `startPipeline(... textModelProviderResolver: resolver ...)` in every bootstrap and language-restart path.

`AppModel+Reports.swift` throws `AppModelReportError.runtimeUnavailable` when the runtime is absent.
It does not store a second error channel and does not use speaker-review errors.
`requestMeetingMinutes` consumes the preflight currently displayed by the UI and returns the exact new-or-existing Job.
It never silently calculates a second preflight behind the visible notice.
`cancelReportJob` forwards `PipelineError.cancellationTooLate` unchanged so the report UI can show the precise message.
`PipelineCoordinator` first rejects every external job whose fingerprint or complete revision-pinned endpoint snapshot is missing or whose snapshot identity differs from the endpoint ID.
It then compares every present job fingerprint with the newly assembled pinned input before calling `textModelProvider.render`.
Only older Apple jobs without an external endpoint ID keep the nil-fingerprint compatibility behavior.

- [ ] **Step 5: Verify and commit**

Run: `swift test --package-path StenoKit --filter JobStoreTests`

Run: `swift test --package-path StenoKit --filter TemplateRenderPipelineTests`

Run: `cd iOS && xcodegen generate && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" -only-testing:StenoTests/MeetingReportsIntegrationTests test`

Expected: all focused suites pass, including concurrent request identity.

```bash
git add StenoKit/Sources/StenoDomain/Job.swift \
  StenoKit/Sources/StenoLibrary/JobStore.swift \
  StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift \
  StenoKit/Sources/StenoPipeline/PipelineError.swift \
  StenoKit/Sources/StenoPipeline/TemplateRenderRequest.swift \
  StenoKit/Tests/StenoLibraryTests/JobStoreTests.swift \
  StenoKit/Tests/StenoPipelineTests/TemplateRenderPipelineTests.swift \
  iOS/App/Sources/AppModel.swift \
  iOS/App/Sources/AppModel+Reports.swift \
  iOS/App/Tests/MeetingReportsIntegrationTests.swift
git commit -m "feat(ios): Protokolljobs sicher einreihen"
```

### Task 4: Reine Protokollzustandsmaschine und Datenschutzdarstellung

**Files:**

- Create: `iOS/App/Sources/MeetingReportsPresentation.swift`
- Create: `iOS/App/Tests/MeetingReportsPresentationTests.swift`
- Modify: `App/Sources/ReportsSection.swift:19-170`
- Create: `App/Tests/ReportsDisclosureTests.swift`

**Interfaces:**

- Consumes: `[StoredTemplateResult]`, `[Job]`, `TextModelAvailability`, `OutboundDisclosure`, `TextModelEndpoint` und `EngineDescriptor`.
- Produces: `MeetingReportsPresentation`, `MeetingReportsAvailabilityPresentation`, `ExternalModelNotice` und `ReportSharePayload`.
- Exact state API:

```swift
struct MeetingReportsPresentation: Equatable {
    var reports: [StoredTemplateResult] = []
    var selectedRunID: RunID?
    var pendingJobID: JobID?
    var isStarting = false
    var errorMessage: String?

    var shownReport: StoredTemplateResult? { get }
    var isPending: Bool { get }
    mutating func beginGeneration() -> Bool
    mutating func accepted(job: Job)
    mutating func failedToStart(_ message: String)
    mutating func reconcile(reports: [StoredTemplateResult], jobs: [Job])
    mutating func select(_ runID: RunID)
}

struct ExternalModelNotice: Equatable {
    let text: String
    let isPlaintext: Bool
}

struct ReportSharePayload: Equatable {
    let text: String
}
```

- Invariant: `beginGeneration()` setzt das Gate synchron und liefert bei einem zweiten Aufruf `false`.

- [ ] **Step 1: Write the presentation REDs**

Tests decken diese exakten Uebergaenge ab:

```swift
var state = MeetingReportsPresentation()
#expect(state.beginGeneration())
#expect(!state.beginGeneration())
#expect(state.isStarting)

state.reports = [oldReport]
state.accepted(job: queuedJob)
state.reconcile(reports: [oldReport], jobs: [runningJob])
#expect(state.shownReport == oldReport)
#expect(state.isPending)

state.reconcile(reports: [newReport, oldReport], jobs: [finishedJob])
#expect(state.shownReport == newReport)
#expect(!state.isPending)

state.select(oldReport.runID)
state.reconcile(reports: [newReport, oldReport], jobs: [failedJob])
#expect(state.shownReport == oldReport)
#expect(state.errorMessage == failedJob.errorMessage)
```

Weitere Tests pruefen unbekannte alte Jobs ohne Banner, geloeschte ausgewaehlte Version, Abbruch, Engine-Label, Copy-/Share-Text und alle vier Apple-Unverfuegbarkeitsgruende.

- [ ] **Step 2: Write notice truth tests**

Erzeuge eine Disclosure mit jeder moeglichen Kombination der drei Datenklassen.
Erwarte, dass `ExternalModelNotice` den Endpunktnamen, nur den Host ohne Credentials, jede vorhandene Klasse genau einmal und den Satz ueber nicht uebertragenes Audio, E-Mail-Adressen und Dokumente enthaelt.
Bei `.localPlaintext` muss `isPlaintext == true` sein und der Text die unverschluesselte Verbindung nennen.

- [ ] **Step 3: Run RED and implement pure presentation types**

Run: `cd iOS && xcodegen generate && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" -only-testing:StenoTests/MeetingReportsPresentationTests test`

Expected: compile failure because the presentation types do not exist.

Implement the state without async work, timers, stores or SwiftUI dependencies.
`reconcile` only associates errors with `pendingJobID`; failed historical jobs do not reappear as current errors.
When a pending job finishes and a new report is present, selection moves to the newest report.
When it fails or is cancelled, the prior selection remains.

- [ ] **Step 4: Replace the Mac hand-built notice with the shared manifest**

`ReportsSection` loads `TemplateRenderPreflight` through a new narrow Mac AppModel method, formats `ExternalModelNotice` from its disclosure and removes the separate `hasNotes` and `hasParticipants` truth calculation.
The Mac button remains disabled on a preflight read error.

`ReportsDisclosureTests` verifies that the Mac presentation receives the same three-class manifest as iOS and that its copy says `this Mac` only for the non-transmitted audio statement, not as a claim that an external server is local.

- [ ] **Step 5: Verify and commit**

Run: `cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" -only-testing:StenoTests/MeetingReportsPresentationTests test`

Run: `xcodegen generate && xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/ReportsDisclosureTests test`

```bash
git add iOS/App/Sources/MeetingReportsPresentation.swift \
  iOS/App/Tests/MeetingReportsPresentationTests.swift \
  App/Sources/ReportsSection.swift \
  App/Tests/ReportsDisclosureTests.swift
git commit -m "feat(reports): Protokollzustand wahrheitsgetreu darstellen"
```

### Task 5: Minutes-Ansicht, Versionen, Copy und Share

**Files:**

- Create: `iOS/App/Sources/MeetingReportsSection.swift`
- Create: `iOS/App/Sources/MarkdownLiteView.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift:20-150`
- Create: `iOS/App/Tests/MarkdownLitePresentationTests.swift`
- Create: `iOS/App/Tests/MeetingReportsViewStateTests.swift`

**Interfaces:**

- Consumes: `AppModel+Reports`, `TextModelSettings`, `MeetingReportsPresentation`, `MeetingReviewData` und `ShareLink`.
- Produces: `MeetingReportsSection(meetingID:review:)` and `MarkdownLiteView(markdown:)`.
- Invariant: Die View besitzt keinen Job und loescht keinen Job bei `onDisappear`; sie beobachtet nur persistenten Zustand.

- [ ] **Step 1: Write Markdown and view-state REDs**

`MarkdownLitePresentationTests` prueft den Parser mit:

```swift
let blocks = MarkdownLitePresentation.blocks(
    "# Summary\n\nParagraph one\ncontinues\n\n- First\n- Second"
)
#expect(blocks == [
    .heading("Summary"),
    .paragraph("Paragraph one continues"),
    .bullet("First"),
    .bullet("Second"),
])
```

`MeetingReportsViewStateTests` prueft den Hinweis fuer unbestaetigte Sprecher, die sichtbaren Buttontitel ohne und mit Report, deaktivierte Apple-Aktion bei jeder Unverfuegbarkeit, aktive externe Aktion ohne automatische Probe sowie Copy- und Share-Payload der ausgewaehlten alten Version.

- [ ] **Step 2: Verify RED and implement the renderer**

Run: `cd iOS && xcodegen generate && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" -only-testing:StenoTests/MarkdownLitePresentationTests -only-testing:StenoTests/MeetingReportsViewStateTests test`

Expected: compile failure because the new parser and view presentation do not exist.

Port the Mac renderer into a separate iOS file with pure `MarkdownLitePresentation.blocks(_:)` and a SwiftUI wrapper.
Support `#`, `##`, `-`, `*`, blank-line paragraph boundaries and inline `**bold**`.
Use `Steno.readingBody`, text selection and no WebView or new dependency.

- [ ] **Step 3: Implement `MeetingReportsSection`**

The section keeps one `@State MeetingReportsPresentation` and uses `.task(id: meetingID)` to:

1. call `reportPreflight`,
2. load reports and jobs,
3. reconcile state,
4. poll once per second only while a template-render job is queued or running,
5. stop polling on Task cancellation without cancelling the job.

The Generate action performs:

```swift
guard presentation.beginGeneration() else { return }
guard let preflight else {
    presentation.failedToStart("The report inputs are not ready yet.")
    return
}
do {
    let job = try await app.requestMeetingMinutes(
        meetingID: meetingID,
        textModelEndpointID: textModels.selectedEndpointID?.uuidString,
        preflight: preflight
    )
    presentation.accepted(job: job)
    await refreshLoop()
} catch {
    presentation.failedToStart(error.localizedDescription)
    await loadPreflight()
}
```

The section shows the prior report during `isStarting` and pending jobs.
`Cancel` calls `cancelReportJob` and then reloads jobs; `cancellationTooLate` becomes an informational message while the poll continues.

For an external selection, display `ExternalModelNotice` directly above the Generate button.
For Apple, display the exact `FoundationModelsProvider().availability` explanation and disable only Generate/Regenerate.
Existing reports remain readable regardless of current provider availability.

- [ ] **Step 4: Add versions, Copy and Share**

The version menu lists date, provider name and optional model version from each stored result.
The rendered result header repeats the selected version's engine.

Copy uses:

```swift
UIPasteboard.general.string = presentation.shownReport?.result.markdown
```

Share uses:

```swift
if let payload = MeetingReportsViewState.sharePayload(for: presentation.shownReport) {
    ShareLink(item: payload.text) {
        Label("Share", systemImage: "square.and.arrow.up")
    }
}
```

Neither action uses the newest report implicitly; both use `shownReport`.

- [ ] **Step 5: Integrate before the transcript**

Restructure the loaded MeetingDetail content into one plain `List` with a first `Minutes` section and a second transcript section.
`MeetingReportsSection` receives `meetingID` and the centrally published `review` value.
For draft or missing revision, the Minutes section remains visible but its Generate button shows the no-transcript reason.
Keep transcript search filtering limited to transcript rows and preserve the existing inspector, review generation key and load coordinator.

- [ ] **Step 6: Verify focused UI behavior and commit**

Run: `cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" -only-testing:StenoTests/MeetingReportsPresentationTests -only-testing:StenoTests/MarkdownLitePresentationTests -only-testing:StenoTests/MeetingReportsViewStateTests -only-testing:StenoTests/MeetingReportsIntegrationTests test`

Run: `scripts/build-ios.sh --ipad-simulator`

Use `xcrun simctl io <udid> screenshot /tmp/steno-ipad-reports.png` for visual inspection.
Do not use `cliclick`.
Verify portrait and landscape, hidden and visible sidebar, long report scrolling, version menu, Copy and Share-Sheet presentation.

```bash
git add iOS/App/Sources/MeetingReportsSection.swift \
  iOS/App/Sources/MarkdownLiteView.swift \
  iOS/App/Sources/MeetingDetailView.swift \
  iOS/App/Tests/MarkdownLitePresentationTests.swift \
  iOS/App/Tests/MeetingReportsViewStateTests.swift
git commit -m "feat(ios): Protokolle anzeigen und teilen"
```

### Task 6: Vollverifikation und ehrlicher Abnahmestand

**Files:**

- Modify after successful checks: `docs/FEATURE-PARITY.md`
- Modify after successful checks: `docs/PLAN-IOS.md`

**Interfaces:**

- Consumes: den vollstaendigen Apple- und OpenAI-kompatiblen Pfad aus Tasks 1 bis 5.
- Produces: reproduzierbare Build- und Testbelege sowie einen ehrlichen Status der noch ausstehenden Geraete- und Endpunktabnahme.
- Invariant: Der Simulator wird nicht als Beleg fuer Apple Foundation Models oder echte Netzwerkberechtigungen ausgegeben.

- [ ] **Step 1: Run the complete automated chain once on the final code**

Run: `xcodegen generate`

Run: `scripts/build-app.sh`

Run: `scripts/build-ios.sh`

Run: `swift test --package-path StenoKit`

Run: `cd iOS && xcodegen generate && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" test`

Expected: all commands exit 0.
Classify any failure as change-caused, pre-existing, environment-related or flaky before rerunning only the affected command.

- [ ] **Step 2: Perform the simulator UI acceptance**

Start the app with `scripts/build-ios.sh --ipad-simulator`.
Use a fixture meeting with two stored report versions from different `EngineDescriptor` values.
Verify that Apple is selected after cold launch, external selection shows host and exact data classes, old versions remain visible during pending and failed states, Copy uses the chosen version, Share opens with the chosen text and the settings screen never probes by itself.

Capture portrait and landscape screenshots with `xcrun simctl io` and inspect them locally.

- [ ] **Step 3: Record the two manual acceptance gates without simulating them**

Keep Apple Foundation Models hardware acceptance open until an Apple-Intelligence-capable iPhone or iPad has generated and regenerated a harmless German fixture in airplane mode and Copy, Share and Cancel have been observed.
Keep LM Studio acceptance open until a concrete local endpoint and a non-sensitive synthetic fixture are chosen for the real `/models` and `/chat/completions` checks.
Do not contact a configured endpoint, install to a device or create `docs/BENCH-IOS-I4-REPORTS.md` during automated consolidation.
The final handoff must name both remaining checks exactly.

- [ ] **Step 4: Update status documents from verified facts only**

Mark the iOS report slice complete in `docs/FEATURE-PARITY.md` and `docs/PLAN-IOS.md` only for checks that actually passed.
Keep long-background completion, direct Gemma downloads, custom templates and cloud realtests open.
Do not change historical benchmark values or claim simulator support for `SystemLanguageModel`.

- [ ] **Step 5: Review, final diff check and commit evidence**

Review the complete range for privacy, data loss, job races, cancellation and cross-platform regressions.
Resolve every Critical or Important finding in the touched path and rerun only the affected focused suite before the final chain if code changes.

Run: `git diff --check`

Run: `git status --short`

Expected: only the intended status documents are staged; `.superpowers/` remains untracked.

```bash
git add docs/FEATURE-PARITY.md docs/PLAN-IOS.md
git commit -m "docs(ios): Protokollabnahme festhalten"
```
