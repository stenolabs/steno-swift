# iOS-Ordnerhierarchie Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die iPhone- und iPad-App zeigt und bearbeitet die gemeinsame zweistufige Ordnerhierarchie, ohne ihre bestehende Meetingnavigation, Aufnahme oder Transferwege zu brechen.

**Architecture:** `AppModel` oeffnet denselben langlebigen `FolderStore` wie die Mac-App und stellt schmale asynchrone Ordneraktionen bereit. Eine reine iOS-Presentation-Schicht baut den vorhandenen `MeetingSidebarTree`, waehrend SwiftUI nur Baum, Dialoge, Kontextmenues und typisierte lokale Drag-and-drop-Ziele rendert.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, UniformTypeIdentifiers, Transferable, Swift Testing, XcodeGen, iOS/iPadOS 26.

**Spec:** `docs/superpowers/specs/2026-08-18-ios-ordnerhierarchie-design.md`

## Global Constraints

- `FolderStore`, `Folder`, `Meeting.folderID` und `MeetingSidebarTree` aus `StenoKit` bleiben die einzige fachliche Ordnerimplementierung.
- Es gibt hoechstens eine Unterordnerebene.
- Ein Meeting gehoert zu hoechstens einem konkreten Haupt- oder Unterordner.
- Das Loeschen eines Ordners loescht niemals Meetings oder Audiooriginale.
- Kontextmenues und Dialoge bieten jede Drag-and-drop-Aktion ebenfalls an.
- iOS behaelt eine Einzelauswahl und erhaelt keine macOS-Mehrfachauswahl.
- Drag-Nutzlasten enthalten nur stabile Kennungen und keine privaten Meetinginhalte oder Dateipfade.
- Ein Ordnerfehler beendet weder Aufnahme noch Transkription, Diarisierung, Meetingtransfer oder Protokolljobs.
- Die bestehende `SidebarItem.meeting(MeetingID)`-Navigation bleibt die einzige Meetingroute.
- Kein neues Drittanbieterpaket wird hinzugefuegt.
- Die vollstaendige Kern-, macOS- und iOS-Kette laeuft am Ende, weil die gemeinsame Ordnerlogik von beiden Apps genutzt wird.

## File Map

- `iOS/App/Sources/AppModel.swift` besitzt `folders` und die langlebige `FolderStore`-Instanz und laedt Meetings und Ordner gemeinsam neu.
- `iOS/App/Sources/AppModel+Folders.swift` kapselt alle iOS-Ordneroperationen und die rueckrollbare Loeschreihenfolge.
- `iOS/App/Sources/IOSMeetingSidebarPresentation.swift` baut den gemeinsamen Baum, berechnet Aufklappzustaende und typisierte lokale Drag-Ziele.
- `iOS/App/Sources/MeetingSidebarView.swift` rendert Ordnerbaum, Datumsliste, Suche, Menues, Dialoge und Drag-and-drop.
- `iOS/App/Sources/ContentView.swift` ersetzt nur den bisherigen flachen Meetingabschnitt durch `MeetingSidebarView` und behaelt Tools sowie Detailrouting.
- `iOS/App/Tests/AppModelFolderIntegrationTests.swift` prueft reale Bibliotheksmutationen.
- `iOS/App/Tests/IOSMeetingSidebarPresentationTests.swift` prueft die reine Darstellungs- und Draglogik.

---

### Task 1: Langlebiger iOS-FolderStore und sichere AppModel-Aktionen

**Files:**

- Modify: `iOS/App/Sources/AppModel.swift`
- Create: `iOS/App/Sources/AppModel+Folders.swift`
- Create: `iOS/App/Tests/AppModelFolderIntegrationTests.swift`

**Interfaces:**

- Consumes: `PipelineRuntime.library`, `FolderStore.open`, `Library.setMeetingFolders` und die bestehende `reloadMeetings()`-Sequenz.
- Produces: `AppModel.folders`, genau eine `folderStore`-Instanz je Runtime und die folgenden Methoden:

```swift
@discardableResult
func createFolder(named name: String, parentFolderID: FolderID?) async -> Folder?
func renameFolder(_ folderID: FolderID, to name: String) async -> Bool
func deleteFolder(_ folderID: FolderID) async -> Bool
func moveFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async -> Bool
func moveFolder(_ folderID: FolderID, up: Bool) async -> Bool
func moveMeeting(_ meetingID: MeetingID, to folderID: FolderID?) async -> Bool
```

- Die Methoden melden Fehler ueber den vorhandenen sichtbaren AppModel-Fehlerkanal und geben `false` beziehungsweise `nil` zurueck.
- `deleteFolder` uebernimmt die bewaehrte Reihenfolge aus `App/Sources/AppModel+Folders.swift`: direkte Meetingzuordnungen entfernen, Ordnerindex loeschen, bei Indexfehler Zuordnungen wiederherstellen, danach immer neu laden.

- [ ] **Step 1: Write failing runtime and CRUD integration tests**

Erzeuge in `AppModelFolderIntegrationTests` eine temporaere echte `Library`, `JobStore`, `PipelineRuntime` und ein `AppModel` mit injiziertem `startPipeline`.
Die Tests pruefen folgende beobachtbare Ergebnisse:

```swift
#expect(app.folders.isEmpty)
let work = try #require(await app.createFolder(named: "Work", parentFolderID: nil))
let weekly = try #require(await app.createFolder(named: "Weekly", parentFolderID: work.id))
#expect(app.folders.map(\.id) == [work.id, weekly.id])
#expect(await app.moveMeeting(meeting.id, to: weekly.id))
#expect(try await library.loadMeeting(meeting.id).folderID == weekly.id)
```

Ein Umbenennungstest erwartet, dass `meeting.folderID` unveraendert bleibt.
Ein Loeschtest erwartet, dass direkte Meetings danach `folderID == nil` besitzen und Kinder eines geloeschten Hauptordners durch den realen `FolderStore` hochgestuft werden.
Ein Fehlerpfad injiziert einen nicht vorhandenen Zielordner und erwartet `false`, unveraenderte Meetingmetadaten und weiterhin bedienbare App-Runtime.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" \
  -only-testing:StenoTests/AppModelFolderIntegrationTests test
```

Expected: compile failure because `folders` and the iOS folder methods do not exist.

- [ ] **Step 3: Implement the runtime ownership and actions**

Add to `AppModel`:

```swift
private(set) var folders: [Folder] = []
private var folderStore: FolderStore?
```

After a runtime is attached, open exactly one store with `FolderStore.open(layout: runtime.library.layout)`.
If opening fails, keep the runtime and recording usable, clear `folders`, and publish the localized error through the existing failure channel.
When detaching a runtime, clear `folderStore` and `folders` together.

Change `reloadMeetings()` so the real-runtime path loads `library.listMeetings()` and `folderStore.listFolders()` before assigning either visible array.
Keep the existing `meetingListLoader` test seam working by leaving `folders` unchanged when no real runtime store is available.

Implement `AppModel+Folders.swift` from the exact interfaces above.
Do not copy hierarchy validation from `FolderStore`.
Use `Set([meetingID])` with `Library.setMeetingFolders` so the real batch validation and rollback contract stays in force.

- [ ] **Step 4: Verify GREEN and commit**

Run the focused test command from Step 2.
Expected: all `AppModelFolderIntegrationTests` pass with no warnings introduced by these files.

```bash
git add iOS/App/Sources/AppModel.swift \
  iOS/App/Sources/AppModel+Folders.swift \
  iOS/App/Tests/AppModelFolderIntegrationTests.swift
git commit -m "feat(ios): Ordnerzustand und Aktionen anbinden"
```

### Task 2: Reine iOS-Baum-, Such- und Dragdarstellung

**Files:**

- Create: `iOS/App/Sources/IOSMeetingSidebarPresentation.swift`
- Create: `iOS/App/Tests/IOSMeetingSidebarPresentationTests.swift`

**Interfaces:**

- Consumes: `MeetingSidebarTree.build(folders:meetings:query:calendar:now:)`, `Folder.parentFolderID` und stabile `MeetingID`/`FolderID`-Werte.
- Produces:

```swift
struct IOSMeetingSidebarPresentation: Equatable {
    let tree: MeetingSidebarTree

    init(folders: [Folder], meetings: [Meeting], query: String, now: Date = Date())

    func effectiveExpandedFolderIDs(persisted: Set<FolderID>) -> Set<FolderID>
    func expandedFolderIDs(revealing folderID: FolderID, persisted: Set<FolderID>) -> Set<FolderID>
    func moveDestinations(for meetingID: MeetingID) -> [Folder]
    func nestingDestinations(for folderID: FolderID) -> [Folder]
}

enum IOSSidebarDragPayload: Codable, Equatable, Transferable {
    case meeting(MeetingID)
    case folder(FolderID)
}

enum IOSSidebarDropDecision: Equatable {
    case moveMeeting(MeetingID, FolderID?)
    case moveFolder(FolderID, FolderID?)
    case reject
}
```

- [ ] **Step 1: Write failing presentation tests**

Tests verwenden handgeschriebene Ordner- und Meetingfixtures und erwarten:

- Tiefenreihenfolge `Work`, `Weekly`, `Home` aus dem gemeinsamen Baum.
- Eine Suche nach einem Meeting in `Weekly` behaelt `Work/Weekly` und klappt beide nur effektiv auf.
- Leere Ordner sind ohne Suche vorhanden und bei einer nicht passenden Suche nicht vorhanden.
- `moveDestinations` enthaelt jeden Haupt- und Unterordner genau einmal und markiert den aktuellen Ordner nicht als noetige Mutation.
- Ein Hauptordner mit Kind besitzt keine zulaessigen Elternziele.
- Eine Meeting-Nutzlast auf einen Ordner ergibt `.moveMeeting(meetingID, folderID)`.
- Eine Unterordner-Nutzlast auf die Hauptebene ergibt `.moveFolder(folderID, nil)`.
- Falsche Payloadart, Selbstbezug und dritte Ebene ergeben `.reject`.

- [ ] **Step 2: Run RED**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" \
  -only-testing:StenoTests/IOSMeetingSidebarPresentationTests test
```

Expected: compile failure because the presentation and payload types do not exist.

- [ ] **Step 3: Implement minimal pure presentation logic**

Delegate tree creation to `MeetingSidebarTree.build`.
During a non-empty normalized search, effective expansion is every visible root and child ID from `tree.folderNodes`.
Outside a search, return the persisted set unchanged.
`expandedFolderIDs(revealing:)` adds the concrete folder and its direct parent.
Destination and drop decisions inspect the current `folders` collection but leave final hierarchy validation to `FolderStore`.

Declare private app-owned exported type identifiers for meeting and folder payloads.
Encode only the enum case and raw UUID.
No title, path or meeting data may enter the representation.

- [ ] **Step 4: Verify GREEN and commit**

Run the focused command from Step 2.
Expected: all presentation tests pass.

```bash
git add iOS/App/Sources/IOSMeetingSidebarPresentation.swift \
  iOS/App/Tests/IOSMeetingSidebarPresentationTests.swift
git commit -m "feat(ios): Ordnerbaumdarstellung ableiten"
```

### Task 3: Native iPhone- und iPad-Sidebar mit Ordneraktionen

**Files:**

- Create: `iOS/App/Sources/MeetingSidebarView.swift`
- Modify: `iOS/App/Sources/ContentView.swift`
- Modify: `iOS/project.yml`
- Modify: `iOS/App/Tests/IOSMeetingSidebarPresentationTests.swift`
- Modify: `docs/FEATURE-PARITY.md`
- Modify: `docs/PLAN-IOS.md`

**Interfaces:**

- Consumes: Tasks 1 and 2, `Binding<SidebarItem?>`, `AppModel.consumeSelectedMeetingIDIfAvailable` and SwiftUI `DisclosureGroup`, `contextMenu`, `draggable`, `dropDestination`, `alert` and `confirmationDialog`.
- Produces:

```swift
struct MeetingSidebarView: View {
    @Binding var selection: SidebarItem?
    let revealMeetingID: MeetingID?
}
```

- [ ] **Step 1: Extend tests for navigation reveal and action policy**

Add tests that a selected meeting in a child folder expands child and parent IDs without changing the selected `SidebarItem.meeting` route.
Add tests that every drop decision exposed by the presentation has an equivalent menu destination.
Name the production breaks explicitly: losing the parent reveal after transfer, or making drag the only route to a move.

- [ ] **Step 2: Run the focused tests and verify RED**

Run the Task 2 focused test command.
Expected: failure because reveal and menu-equivalence APIs are not complete yet.

- [ ] **Step 3: Implement `MeetingSidebarView`**

Render one stable `List(selection:)` containing:

- a non-selectable `Folders` row that remains visible as the promotion drop target,
- root `DisclosureGroup` rows,
- child `DisclosureGroup` rows one level deeper,
- direct meeting links at the matching node,
- the existing unfiled date sections from `tree.unfiledSections`,
- the existing `Record` and `Audio readiness` tool routes.

Use `.searchable(text:)` for title search.
Persist expanded IDs in a dedicated `UserDefaults` wrapper and never overwrite that set with temporary search expansion.

Folder context menus provide new child, rename, delete, move to parent or root, move up and move down as applicable.
Meeting context menus provide every folder and `No folder` destination.
Use alerts or sheets with explicit text fields for create and rename and a destructive confirmation for delete.

Use typed `IOSSidebarDragPayload` for `.draggable` and `.dropDestination`.
Execute the resulting `IOSSidebarDropDecision` only through the Task 1 AppModel methods, then reveal the successful target path.
Do not mutate visible arrays optimistically.

Refactor `ContentView` so it delegates the entire sidebar list to `MeetingSidebarView` while preserving the existing recording strip, startup warning, scene registration, transfer sheet and detail switch.
When `consumeSelectedMeetingIfAvailable()` returns an ID, set the existing `.meeting(id)` selection and pass the ID to the sidebar reveal mechanism.

- [ ] **Step 4: Update generated-project inputs and parity documentation**

Add the new source and test files to `iOS/project.yml` only if the project specification uses explicit lists.
Do not edit the generated `.xcodeproj`.
Mark iOS folder hierarchy, create/rename/delete and single-meeting move as implemented in `docs/FEATURE-PARITY.md` and the iOS milestone section.
Keep iOS multi-selection explicitly macOS-only.

- [ ] **Step 5: Verify focused UI tests and both iOS form factors**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" \
  -only-testing:StenoTests/IOSMeetingSidebarPresentationTests \
  -only-testing:StenoTests/AppModelFolderIntegrationTests test
cd ..
scripts/build-ios.sh
```

Expected: focused tests and the universal iOS/iPadOS build pass.

- [ ] **Step 6: Commit**

```bash
git add iOS/App/Sources/MeetingSidebarView.swift \
  iOS/App/Sources/ContentView.swift \
  iOS/project.yml \
  iOS/App/Tests/IOSMeetingSidebarPresentationTests.swift \
  docs/FEATURE-PARITY.md \
  docs/PLAN-IOS.md
git commit -m "feat(ios): Ordnerhierarchie in der Sidebar bedienen"
```

## Final Verification

Nach allen Tasks laufen aus dem Repositorywurzelverzeichnis:

```bash
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit
```

Zusaetzlich laufen die vollstaendige macOS-App-Suite, die vollstaendige iOS-App-Suite und die vollstaendige StenoiOSKit-Suite mit demselben wiederverwendeten Build-Root wie die fokussierten Laeufe.
Der Simulator belegt Darstellung und Bedienfluss, aber kein echtes Apple-Foundation-Models-Verhalten und keine Hardwareaufnahme.
