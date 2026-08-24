# Meeting-Sidebar mit Ordnerbaum Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die macOS-Sidebar erhält native Mehrfachauswahl, gemeinsame Meeting-Ablage per Menü und Drag-and-drop sowie Hauptordner mit genau einer Unterordner-Ebene, ohne Fensterzoom oder Datenverlust.

**Architecture:** `Folder.parentFolderID` und ein explizit migrierter, langlebiger `FolderStore` bilden die persistente Hierarchie.
Ein reiner `MeetingSidebarTree` bereitet Ordner, Meetings und Datumsgruppen für SwiftUI auf.
Die App hält genau eine `Set<MeetingID>`-Auswahl, rendert gewöhnliche `DisclosureGroup`-Zeilen und delegiert jede schreibende Operation an validierte Store- oder Library-Batches.

**Tech Stack:** Swift 6.3, SwiftUI für macOS 26, Observation, CoreTransferable, UniformTypeIdentifiers, Swift Testing, Swift Package Manager, XcodeGen und Xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-16-meeting-sidebar-ordnerbaum-design.md`

## Global Constraints

- Ordner unterstützen genau eine Unterordner-Ebene.
- Ein Meeting gehört weiterhin genau einem Ordner oder keinem Ordner.
- Aufnahmen und andere Originalartefakte werden niemals verändert.
- Bestehende Schema-1-Ordner werden vor dem ersten Zugriff verlustfrei und atomar auf Schema 2 migriert.
- Normale Ordnerlesevorgänge schreiben nicht auf die Platte.
- Die App verwendet pro geöffneter Bibliothek genau eine `FolderStore`-Instanz.
- Eine Sammelverschiebung fällt niemals still auf einen anderen Ordner zurück.
- Mehrfachaktionen beschränken sich auf das Verschieben von Meetings.
- Die iOS- und iPadOS-Oberfläche erhält keine neue Ordneransicht, muss aber mit dem gemeinsamen Modell bauen.
- Neue Dateien liegen in den vorhandenen Targets und führen keine Abhängigkeit ein.
- Der wiederverwendete Build-Root bleibt `.build`; parallele Builds dürfen diesen Pfad nicht gleichzeitig verwenden.
- `UEBERGABE-sprecher-erkenntnisse.md`, `.superpowers/` und fremde uncommittete Änderungen werden weder gestaged noch verändert.
- Vor dem Abschluss läuft die vollständige Kernkette genau einmal: `xcodegen generate`, `scripts/build-app.sh`, `scripts/build-ios.sh`, `swift test --package-path StenoKit`.

## Geplante Dateistruktur

| Datei | Verantwortung |
|---|---|
| `StenoKit/Sources/StenoDomain/Folder.swift` | Persistentes Ordnermodell mit optionaler Eltern-ID. |
| `StenoKit/Sources/StenoDomain/MeetingSidebarTree.swift` | Reine Baum- und Datumsgruppenaufbereitung ohne UI-Zustand. |
| `StenoKit/Sources/StenoDomain/MeetingGrouping.swift` | Nur die weiterhin benötigte Datumsgruppierung. |
| `StenoKit/Sources/StenoLibrary/JSONDocumentStore.swift` | Versionsgeprüfter, expliziter Migrations-Decode mit bestehender Quarantänesemantik. |
| `StenoKit/Sources/StenoLibrary/FolderStore.swift` | Einziger persistenter Ordnerindex, Hierarchievalidierung, Geschwistersortierung und Lösch-Hochstufung. |
| `StenoKit/Sources/StenoLibrary/Library.swift` | Rückrollbare Meeting-Ordner-Batches über einzelne Metadatendateien. |
| `StenoKit/Sources/StenoLibrary/LibraryError.swift` | Präzise Hierarchie- und Batchfehler. |
| `StenoKit/Sources/StenoExchange/LegacyImporter.swift` | Verwendet den von der App gelieferten Store und erzeugt Altordner nur auf der Hauptebene. |
| `App/Sources/AppModel.swift` | Langlebiger Store und genau eine mengenbasierte Meetingauswahl. |
| `App/Sources/AppModel+Folders.swift` | Validierte App-Aktionen für Ordner und Meeting-Batches. |
| `App/Sources/LegacyImportView.swift` | Reicht dieselbe Store-Instanz an den Legacy-Import weiter. |
| `App/Sources/MeetingSidebar/MeetingSidebarState.swift` | Reine Auswahl-, Sichtbarkeits-, Menü- und Drop-Regeln plus Disclosure-Persistenz. |
| `App/Sources/MeetingSidebar/MeetingSidebarTransfer.swift` | Getrennte Transferable-Nutzlasten für Meetings und Ordner. |
| `App/Sources/MeetingSidebar/MeetingSidebarView.swift` | Baumdarstellung, Kontextmenüs, Dialoge, Drag-and-drop und Suchzustand. |
| `App/Sources/ContentView.swift` | Split-View-Verdrahtung und Mehrfachzusammenfassung in der Detailspalte. |
| `StenoKit/Tests/StenoDomainTests/MeetingSidebarTreeTests.swift` | Baum-, Suchpfad-, Fallback- und Partitionsregressionen. |
| `StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift` | Migration und persistente Hierarchieoperationen. |
| `StenoKit/Tests/StenoLibraryTests/MeetingFolderBatchTests.swift` | Erfolg, Laufzeit-Rollback und fehlgeschlagene Wiederherstellung. |
| `StenoKit/Tests/StenoExchangeTests/LegacyImporterTests.swift` | Legacy-Import mit injiziertem langlebigem Store. |
| `App/Tests/MeetingSidebarStateTests.swift` | Auswahl, Payload, Menü, Sichtbarkeit, Disclosure und Drop-Vorschau. |
| `App/Tests/WindowLayoutTests.swift` | Fensterstabilität auch bei Mehrfachzusammenfassung und Baumdetail. |

---

### Task 1: Ordnermodell und sichere Schema-Migration

**Files:**
- Modify: `StenoKit/Sources/StenoDomain/Folder.swift`
- Modify: `StenoKit/Sources/StenoLibrary/JSONDocumentStore.swift`
- Modify: `StenoKit/Sources/StenoLibrary/FolderStore.swift`
- Modify: `StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift`

**Interfaces:**
- Consumes: `FolderID`, `AtomicFile.write`, `LibraryError.unsupportedSchemaVersion` und den bestehenden Quarantänepfad.
- Produces: `Folder.parentFolderID`, `FolderStore.open(layout:)`, Schema 2 und ausschließlich lesende normale Store-Methoden.

- [ ] **Step 1: Schreibe die roten Migrations- und Modelltests.**

Erweitere `FolderStoreTests` mindestens um diese Fälle:

```swift
@Test("schema 1 migrates to schema 2 without quarantine")
func migratesLegacyFolders() async throws {
    try await withTemporaryDirectory { root in
        let library = try Library.open(at: root)
        let legacy = """
        {
          "adoptedLegacyFolders" : true,
          "folders" : [
            {
              "createdAt" : 0,
              "id" : "00000000-0000-7000-8000-000000000001",
              "name" : "Arbeit",
              "sortIndex" : 0
            }
          ],
          "schemaVersion" : 1
        }
        """
        try Data(legacy.utf8).write(to: library.layout.folders)

        let store = try FolderStore.open(layout: library.layout)
        let folders = try await store.listFolders()

        #expect(folders.count == 1)
        #expect(folders[0].parentFolderID == nil)
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: library.layout.folders)
        ) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .allSatisfy { !$0.contains("corrupt-") })
    }
}

@Test("ordinary reads do not rewrite schema 2")
func readsWithoutWriting() async throws {
    try await withTemporaryDirectory { root in
        let library = try Library.open(at: root)
        let store = try FolderStore.open(layout: library.layout)
        _ = try await store.createFolder(name: "Arbeit")
        let before = try Data(contentsOf: library.layout.folders)

        _ = try await store.listFolders()
        _ = try await store.listFolders()

        #expect(try Data(contentsOf: library.layout.folders) == before)
    }
}
```

Passe den bestehenden Persistenztest auf `schemaVersion == 2` und `FolderStore.open(layout:)` an.
Ergänze einen Decode-Test, der ein Schema-2-`Folder` ohne Eltern-ID als Hauptordner liest, und einen Test, der Schema 3 als `unsupportedSchemaVersion` ablehnt, ohne die Datei zu quarantänisieren.

- [ ] **Step 2: Führe den fokussierten roten Test aus.**

Run: `swift test --package-path StenoKit --filter FolderStoreTests`

Expected: FAIL, weil `parentFolderID`, `FolderStore.open` und Schema 2 noch fehlen.

- [ ] **Step 3: Ergänze das Domänenmodell.**

Ersetze den Kommentar über bewusst flache Ordner und ergänze die optionale Eltern-ID mit rückwärtskompatiblem Decode:

```swift
public struct Folder: Codable, Equatable, Identifiable, Sendable {
    public let id: FolderID
    public var name: String
    public var parentFolderID: FolderID?
    public var sortIndex: Int
    public let createdAt: Date

    public init(
        id: FolderID = FolderID(),
        name: String,
        parentFolderID: FolderID? = nil,
        sortIndex: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Baue einen expliziten Migrations-Decode.**

Erweitere `JSONDocumentStore` um eine interne Methode, die nur beim Store-Open verwendet wird:

```swift
static func migrateAndRead<Legacy: Decodable, Current: Codable>(
    current: Current.Type,
    legacy: Legacy.Type,
    from url: URL,
    legacySchemaVersion: Int,
    currentSchemaVersion: Int,
    currentSchema: (Current) -> Int,
    migrate: (Legacy) throws -> Current
) throws -> Current
```

Die Methode liest zuerst das vorhandene `SchemaEnvelope`.
Bei der aktuellen Version dekodiert und validiert sie `Current` ohne Schreibzugriff.
Bei der genau bekannten Legacy-Version dekodiert sie `Legacy`, transformiert, prüft `currentSchema` und schreibt genau einmal atomar.
Unbekannte Versionen erzeugen `unsupportedSchemaVersion`.
Ein nicht dekodierbares Envelope oder ein beschädigtes Dokument benutzt denselben privaten Quarantänehelfer wie `read`.

Definiere in `FolderStore.swift` ein privates `FoldersDocumentV1` mit einem privaten `FolderV1`, damit Schema 1 nicht versehentlich gegen das neue Modell geraten wird.
Setze `FoldersDocument.currentSchemaVersion = 2`.
Ergänze zunächst die klare Factory:

```swift
public static func open(layout: LibraryLayout) throws -> FolderStore
```

`open` legt nur das Bibliotheksverzeichnis an, migriert eine vorhandene `folders.json` und liefert danach eine vorbereitete Actor-Instanz.
Wenn die Datei fehlt, erfolgt noch kein Schreibzugriff.
`readDocument()` akzeptiert danach ausschließlich Schema 2 über den normalen `JSONDocumentStore.read`-Pfad.
Behalte den bisherigen öffentlichen `init(layout:)` in diesem Task vorübergehend als delegierten, ebenfalls migrierenden Kompatibilitätspfad, damit alle noch nicht umgestellten Targets zwischen den Commits bauen.
Task 2 stellt sämtliche Produkt- und Testaufrufer auf `open` um und macht den direkten Initializer danach privat.

- [ ] **Step 5: Führe die fokussierten Tests grün aus.**

Run: `swift test --package-path StenoKit --filter FolderStoreTests`

Expected: PASS, einschließlich Schema-1-Migration ohne Quarantänedatei.

- [ ] **Step 6: Committe nur Modell und Migration.**

```bash
git add StenoKit/Sources/StenoDomain/Folder.swift \
  StenoKit/Sources/StenoLibrary/JSONDocumentStore.swift \
  StenoKit/Sources/StenoLibrary/FolderStore.swift \
  StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift
git commit -m "feat: migrate folders to hierarchical schema"
```

### Task 2: Eine langlebige Store-Instanz durch App und Legacy-Import reichen

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/AppModel+Folders.swift`
- Modify: `App/Sources/LegacyImportView.swift`
- Modify: `StenoKit/Sources/StenoExchange/LegacyImporter.swift`
- Modify: `StenoKit/Tests/StenoExchangeTests/LegacyImporterTests.swift`
- Modify: `StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift`

**Interfaces:**
- Consumes: `FolderStore.open(layout:)` aus Task 1.
- Produces: `AppModel.folderStore: FolderStore?` und `LegacyImporter.init(sourceRoot:library:folders:timestampParser:)` ohne interne Store-Erzeugung.

- [ ] **Step 1: Schreibe den roten Legacy-Import-Vertrag.**

Passe die Konstruktion in `LegacyImporterTests` auf einen ausdrücklich injizierten Store an und ergänze einen Test, der zweimal denselben Store verwendet:

```swift
let library = try Library.open(at: target)
let folders = try FolderStore.open(layout: library.layout)
let importer = LegacyImporter(
    sourceRoot: source,
    library: library,
    folders: folders,
    timestampParser: berlin
)
```

Der bestehende Test für importierte Ordner muss weiterhin belegen, dass spätere Imports den bereits vorhandenen Hauptordner wiederverwenden.
Suche anschließend im Produktcode nach `FolderStore(` und verlange als statische Abnahme, dass außerhalb `FolderStore.open` keine Initialisierung mehr existiert.

- [ ] **Step 2: Führe den fokussierten roten Exchange-Test aus.**

Run: `swift test --package-path StenoKit --filter LegacyImporterTests`

Expected: FAIL, weil der Importer den Store noch nicht als Argument annimmt.

- [ ] **Step 3: Injiziere den Store in den Legacy-Import.**

Ergänze in `LegacyImporter`:

```swift
public let folders: FolderStore

public init(
    sourceRoot: URL,
    library: Library,
    folders: FolderStore,
    timestampParser: LegacyTimestampParser = LegacyTimestampParser()
)
```

`fileIntoLegacyFolder` benutzt ausschließlich `folders.folder(named:)` und erzeugt niemals selbst einen Store.
Passe alle Tests und Aufrufer an.
Nachdem kein externer Aufrufer mehr den direkten Initializer verwendet, wird `FolderStore.init` privat und ausschließlich von `open(layout:)` aufgerufen.

- [ ] **Step 4: Öffne den Store einmal im App-Bootstrap.**

Ergänze im `AppModel`:

```swift
private(set) var folderStore: FolderStore?
```

Öffne ihn nach erfolgreichem Pipeline-Start genau einmal über `FolderStore.open(layout:)`.
Reiche diese Instanz an `LegacyFolderAdoption.run`, `refreshMeetings`, alle Methoden in `AppModel+Folders` und `LegacyImportModel.runImport` weiter.
Beim Sprachwechsel wird `folderStore` zusammen mit `runtime` geleert und beim nächsten Bootstrap neu geöffnet.

Ein Ordnerfehler darf die Meetingbibliothek nicht unbenutzbar machen.
Wenn `FolderStore.open` scheitert, bleibt `folderStore == nil`, `refreshMeetings` lädt Meetings mit einer leeren Ordnerliste und die Meldungsleiste zeigt `The folders could not be loaded.` samt technischem Fehler.
Ordneraktionen und der Ordnerteil des Legacy-Imports sind dann deaktiviert, während Aufnahme und Meetingzugriff weiterlaufen.

- [ ] **Step 5: Führe fokussierte Tests und die statische Store-Suche aus.**

Run: `swift test --package-path StenoKit --filter LegacyImporterTests`

Expected: PASS.

Run: `rg -n "FolderStore\\(" App StenoKit/Sources --glob '*.swift'`

Expected: Außer der privaten Konstruktion innerhalb `FolderStore.open` gibt es keine Wegwerf-Initialisierung; Produktcode verwendet `FolderStore.open` nur im App-Bootstrap und Tests öffnen ihre jeweils isolierte Instanz.

Run: `scripts/build-app.sh`

Expected: `BUILD SUCCEEDED`; App und Legacy-Import kompilieren gegen die injizierte Store-Instanz.

- [ ] **Step 6: Committe die Store-Lebensdauer.**

```bash
git add App/Sources/AppModel.swift App/Sources/AppModel+Folders.swift \
  App/Sources/LegacyImportView.swift \
  StenoKit/Sources/StenoExchange/LegacyImporter.swift \
  StenoKit/Tests/StenoExchangeTests/LegacyImporterTests.swift \
  StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift
git commit -m "refactor: share one folder store per library"
```

### Task 3: Persistente Hierarchieoperationen und Geschwistersortierung

**Files:**
- Modify: `StenoKit/Sources/StenoLibrary/FolderStore.swift`
- Modify: `StenoKit/Sources/StenoLibrary/LibraryError.swift`
- Modify: `StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift`

**Interfaces:**
- Consumes: Schema-2-`Folder` und den langlebigen Actor aus Tasks 1 und 2.
- Produces: `createFolder(name:parentFolderID:)`, `moveFolder(_:toParentFolderID:)`, `reorderFolders(parentFolderID:order:)` und `FolderDeletionResult`.

- [ ] **Step 1: Schreibe rote Hierarchietests.**

Ergänze einzeln benannte Tests für diese Verträge:

```swift
let work = try await store.createFolder(name: "Arbeit")
let product = try await store.createFolder(
    name: "Produktvorstellung",
    parentFolderID: work.id
)
#expect(product.parentFolderID == work.id)
```

- Derselbe Name ist unter verschiedenen Eltern erlaubt, unter demselben Elternordner jedoch nicht.
- Ein unbekannter Elternordner wird abgelehnt.
- Ein Unterordner kann keinen Unterordner erhalten.
- Ein Hauptordner mit Kindern kann nicht selbst Unterordner werden.
- Ein Ordner kann nicht in sich selbst oder seinen Nachfahren verschoben werden.
- Ein Wechsel des Elternordners hängt den Ordner ans Ende der Zielgeschwister und kompaktiert beide Gruppen.
- `reorderFolders(parentFolderID:order:)` verändert nur die benannte Geschwistergruppe und lehnt eine unvollständige oder fremde ID-Liste ohne Mutation ab.
- Das Löschen eines Hauptordners setzt seine Kinder auf `parentFolderID = nil`, erhält ihre relative Reihenfolge und setzt sie an die Position des gelöschten Ordners.
- Das Löschen eines Unterordners verändert keine andere Geschwistergruppe.

- [ ] **Step 2: Führe die Hierarchietests rot aus.**

Run: `swift test --package-path StenoKit --filter FolderStoreTests`

Expected: FAIL mit fehlenden Parent- und Move-APIs.

- [ ] **Step 3: Ergänze präzise Store-Fehler und Rückgaben.**

Erweitere `LibraryError` um diese Fälle mit verständlichen `LocalizedError`-Texten:

```swift
case invalidFolderParent(FolderID)
case invalidFolderHierarchy(String)
```

Definiere in `FolderStore.swift`:

```swift
public struct FolderDeletionResult: Equatable, Sendable {
    public let deletedFolderID: FolderID
    public let promotedFolderIDs: [FolderID]
}
```

- [ ] **Step 4: Implementiere alle Invarianten zentral im Store.**

Ändere die Signaturen auf:

```swift
public func createFolder(
    name: String,
    parentFolderID: FolderID? = nil,
    createdAt: Date = Date()
) throws -> Folder

public func moveFolder(
    _ folderID: FolderID,
    toParentFolderID parentFolderID: FolderID?
) throws -> Folder

public func reorderFolders(
    parentFolderID: FolderID?,
    order: [FolderID]
) throws

public func deleteFolder(_ folderID: FolderID) throws -> FolderDeletionResult?
```

Validiere Elternexistenz, maximale Tiefe, Selbstbezug, Nachfahren und Namenskonflikt vor jeder Mutation.
Behandle `folder(named:)` und `adoptLegacyFolders` ausdrücklich als Operationen auf der Hauptebene.
Sortiere `listFolders()` deterministisch als Hauptordner, unmittelbar gefolgt von ihren Kindern.
Normalisiere `sortIndex` nach jeder Move-, Reorder- und Delete-Operation je betroffener Geschwistergruppe auf `0..<count`.

- [ ] **Step 5: Führe die Hierarchietests grün aus.**

Run: `swift test --package-path StenoKit --filter FolderStoreTests`

Expected: PASS, einschließlich Migration und Altordnerübernahme.

- [ ] **Step 6: Committe die persistente Hierarchie.**

```bash
git add StenoKit/Sources/StenoLibrary/FolderStore.swift \
  StenoKit/Sources/StenoLibrary/LibraryError.swift \
  StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift
git commit -m "feat: add validated folder hierarchy operations"
```

### Task 4: Reinen Sidebar-Baum aus Ordnern und Meetings bauen

**Files:**
- Create: `StenoKit/Sources/StenoDomain/MeetingSidebarTree.swift`
- Create: `StenoKit/Tests/StenoDomainTests/MeetingSidebarTreeTests.swift`
- Modify: `StenoKit/Sources/StenoDomain/MeetingGrouping.swift`
- Modify: `StenoKit/Tests/StenoDomainTests/MeetingGroupingTests.swift`
- Modify: `StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift`

**Interfaces:**
- Consumes: `Folder.parentFolderID` und die vorhandene Datumsgruppierung.
- Produces: `MeetingFolderNode`, `MeetingSidebarTree` und `MeetingSidebarTree.build(for:folders:now:calendar:hidesEmptyFolders:)`.

- [ ] **Step 1: Schreibe die roten Baumtests.**

Definiere erwartete Knoten mit direkten Meetings und Kindern:

```swift
let tree = MeetingSidebarTree.build(
    for: meetings,
    folders: [work, product, personal],
    now: now,
    calendar: calendar
)

#expect(tree.folderNodes.map(\.folder.id) == [work.id, personal.id])
#expect(tree.folderNodes[0].children.map(\.folder.id) == [product.id])
#expect(tree.folderNodes[0].children[0].meetings.map(\.id) == [demo.id])
```

Decke zusätzlich ab:

- jedes Meeting erscheint genau einmal;
- verwaiste `meeting.folderID` landet in den Datumsgruppen;
- doppelte Folder-IDs erzeugen nur einen Knoten;
- unbekannte Eltern, Kreise und dritte Ebenen fallen sichtbar auf die Hauptebene zurück;
- ein leerer Hauptordner und ein leerer Unterordner bleiben ohne Suche sichtbar;
- `hidesEmptyFolders == true` entfernt leere Zweige, behält aber den vollständigen Vorfahrenpfad eines Treffers;
- gleiche `sortIndex`-Werte werden stabil nach Name und ID aufgelöst.

- [ ] **Step 2: Führe den neuen Test rot aus.**

Run: `swift test --package-path StenoKit --filter MeetingSidebarTreeTests`

Expected: FAIL, weil die neuen Typen fehlen.

- [ ] **Step 3: Implementiere den reinen Baumtyp.**

Lege diese öffentlichen Typen an:

```swift
public struct MeetingFolderNode: Identifiable, Equatable, Sendable {
    public let folder: Folder
    public let meetings: [Meeting]
    public let children: [MeetingFolderNode]
    public var id: FolderID { folder.id }
}

public struct MeetingSidebarTree: Equatable, Sendable {
    public let folderNodes: [MeetingFolderNode]
    public let unfiledSections: [MeetingSection]
}
```

Der Builder dedupliziert Folder-IDs, klassifiziert nur sichere Kindbeziehungen als verschachtelt, ordnet Meetings nach konkreter Folder-ID zu und übergibt nur unbekannte oder nicht einsortierte Meetings an `MeetingGrouping.sections(for:now:calendar:)`.
Stelle die zugehörigen Domänentests und den Test für eine hängende Folder-ID in `FolderStoreTests` auf den neuen Baum um.
Behalte den flachen `MeetingGrouping.sections(for:folders:...)`-Overload aber bis Task 7 als delegierenden Kompatibilitätspfad für die noch nicht migrierte macOS-Sidebar.

- [ ] **Step 4: Führe Baum- und bestehende Gruppierungstests grün aus.**

Run: `swift test --package-path StenoKit --filter MeetingSidebarTreeTests`

Expected: PASS.

Run: `swift test --package-path StenoKit --filter MeetingGroupingTests`

Expected: PASS für alle Datumsgrenzen.

- [ ] **Step 5: Committe nur die reine Aufbereitung.**

```bash
git add StenoKit/Sources/StenoDomain/MeetingSidebarTree.swift \
  StenoKit/Sources/StenoDomain/MeetingGrouping.swift \
  StenoKit/Tests/StenoDomainTests/MeetingSidebarTreeTests.swift \
  StenoKit/Tests/StenoDomainTests/MeetingGroupingTests.swift \
  StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift
git commit -m "feat: build hierarchical meeting sidebar tree"
```

### Task 5: Rückrollbare Meeting-Batches und sichere Ordnerlöschung

**Files:**
- Modify: `StenoKit/Sources/StenoLibrary/Library.swift`
- Modify: `StenoKit/Sources/StenoLibrary/LibraryError.swift`
- Create: `StenoKit/Tests/StenoLibraryTests/MeetingFolderBatchTests.swift`
- Modify: `App/Sources/AppModel+Folders.swift`

**Interfaces:**
- Consumes: Hierarchieoperationen aus Task 3 und den bestehenden atomaren JSON-Write je Meeting.
- Produces: `Library.setMeetingFolders(_:folderID:)`, `MeetingFolderBatchError` und App-Aktionen für mehrere Meetings sowie geordnetes Löschen.

- [ ] **Step 1: Schreibe die roten Batchtests.**

Lege eine interne, per `@testable` erreichbare Schreibsequenz zugrunde und teste:

```swift
private enum TestError: Error {
    case writeFailed
    case restoreFailed
}

private func meeting(_ title: String) -> Meeting {
    Meeting(title: title, status: .ready)
}

@Test("a failed batch restores every already written meeting")
func rollsBackWrittenMeetings() throws {
    let originals = [meeting("A"), meeting("B"), meeting("C")]
    var stored = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
    var writes = 0

    #expect(throws: MeetingFolderBatchError.self) {
        try Library.writeMeetingFolderBatch(
            originals: originals,
            folderID: FolderID(),
            write: { meeting in
                writes += 1
                if writes == 3 { throw TestError.writeFailed }
                stored[meeting.id] = meeting
            },
            restore: { stored[$0.id] = $0 }
        )
    }

    #expect(stored == Dictionary(
        uniqueKeysWithValues: originals.map { ($0.id, $0) }
    ))
}
```

Ergänze Fälle für vollständigen Erfolg, eine vor dem ersten Write fehlende Meeting-ID und einen Wiederherstellungsfehler, dessen Meeting-ID im Fehler enthalten ist.

- [ ] **Step 2: Führe den Batchtest rot aus.**

Run: `swift test --package-path StenoKit --filter MeetingFolderBatchTests`

Expected: FAIL mit fehlender Batch-API.

- [ ] **Step 3: Implementiere Batch und Fehlerwert.**

Definiere:

```swift
public struct MeetingFolderBatchError: Error, LocalizedError, Sendable {
    public let reason: String
    public let restorationFailures: [MeetingID]
}

public func setMeetingFolders(
    _ meetingIDs: Set<MeetingID>,
    folderID: FolderID?
) throws -> [Meeting]

static func writeMeetingFolderBatch(
    originals: [Meeting],
    folderID: FolderID?,
    write: (Meeting) throws -> Void,
    restore: (Meeting) throws -> Void
) throws -> [Meeting]
```

Lade und validiere alle Meetings vor dem ersten Write.
Schreibe sie in deterministischer ID-Reihenfolge.
Halte die Originalwerte bis zum Abschluss und stelle bereits geschriebene Werte bei einem Fehler in umgekehrter Reihenfolge wieder her.
Behalte den bestehenden Ordner-Metadatenvertrag ohne `meetingChanges`-Signal bei und aktualisiere die App erst nach Abschluss der gesamten Ordneroperation über `refreshMeetings()`.
Behalte `setMeetingFolder` als dünnen Einzelelement-Aufruf auf die neue API bei.

- [ ] **Step 4: Stelle die App-Aktionen auf Batch und festgelegte Löschreihenfolge um.**

Ergänze:

```swift
func moveMeetings(_ meetingIDs: Set<MeetingID>, to folderID: FolderID?) async
func createFolder(named name: String, parentFolderID: FolderID? = nil) async -> Folder?
func moveFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async
func moveFolder(_ folderID: FolderID, up: Bool) async
func deleteFolder(_ folderID: FolderID) async -> Bool
```

`moveMeetings` validiert eine nichtleere Ziel-ID zuerst über den langlebigen `folderStore` und ruft dann genau einen Library-Batch auf.
Die bestehende Aufwärts- und Abwärtsaktion ermittelt ausschließlich die Geschwister mit derselben `parentFolderID` und übergibt deren Reihenfolge an `reorderFolders(parentFolderID:order:)`.
`deleteFolder` führt diese Reihenfolge aus:

1. Direkte Meetings mit dem Batch nach `nil` verschieben.
2. Den Ordnerindex atomar löschen und Kinder hochstufen.
3. Bei einem Indexfehler die direkten Meetings auf die noch vorhandene Folder-ID zurückrollen.
4. Bei einem fehlgeschlagenen Rollback `refreshMeetings()` ausführen und den tatsächlichen Teilzustand melden.

- [ ] **Step 5: Führe Batch- und FolderStore-Tests grün aus.**

Run: `swift test --package-path StenoKit --filter MeetingFolderBatchTests`

Expected: PASS.

Run: `swift test --package-path StenoKit --filter FolderStoreTests`

Expected: PASS.

Run: `scripts/build-app.sh`

Expected: `BUILD SUCCEEDED`; die bisherige flache Sidebar kompiliert bis zu ihrer Ablösung weiter.

- [ ] **Step 6: Committe Batch und App-Operationen.**

```bash
git add StenoKit/Sources/StenoLibrary/Library.swift \
  StenoKit/Sources/StenoLibrary/LibraryError.swift \
  StenoKit/Tests/StenoLibraryTests/MeetingFolderBatchTests.swift \
  App/Sources/AppModel+Folders.swift
git commit -m "feat: move meeting selections with rollback"
```

### Task 6: Einen einzigen Auswahlzustand und Disclosure-Zustand einführen

**Files:**
- Create: `App/Sources/MeetingSidebar/MeetingSidebarState.swift`
- Create: `App/Tests/MeetingSidebarStateTests.swift`
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/ContentView.swift`
- Modify: `App/Tests/WindowLayoutTests.swift`

**Interfaces:**
- Consumes: `MeetingID`, `FolderID` und die vorhandene UserDefaults-Auswahlkennung.
- Produces: `AppModel.selectedMeetingIDs`, den abgeleiteten `selectedMeetingID`, `MeetingSidebarSelectionPolicy`, `FolderDisclosureStore` und `MultiMeetingSelectionView`.

- [ ] **Step 1: Schreibe rote Zustands- und Präsentationstests.**

Teste die reinen Regeln:

```swift
#expect(MeetingSidebarSelectionPolicy.singleID(in: []) == nil)
#expect(MeetingSidebarSelectionPolicy.singleID(in: [a]) == a)
#expect(MeetingSidebarSelectionPolicy.singleID(in: [a, b]) == nil)
#expect(MeetingSidebarSelectionPolicy.pruned(
    [a, missing],
    to: [a, b]
) == [a])
#expect(MeetingSidebarSelectionPolicy.draggedIDs(
    startingAt: a,
    selection: [a, b]
) == Set([a, b]))
#expect(MeetingSidebarSelectionPolicy.draggedIDs(
    startingAt: c,
    selection: [a, b]
) == Set([c]))
```

Teste `FolderDisclosureStore` mit einer eigenen UserDefaults-Suite: Laden ist anfangs leer, Speichern überlebt eine neue Store-Instanz und `remove(folderID)` entfernt nur diese ID.
Ergänze in `WindowLayoutTests` eine Mehrfachzusammenfassung mit langer Meetingzahl und prüfe weiterhin `fittingSize.height <= proposed.height`.

- [ ] **Step 2: Führe die macOS-Zustandstests rot aus.**

Run: `xcodegen generate && xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/MeetingSidebarStateTests -only-testing:StenoTests/WindowLayoutTests test`

Expected: FAIL mit fehlenden Sidebar-Zustandstypen.

- [ ] **Step 3: Implementiere reine Auswahl- und Disclosure-Helfer.**

Definiere in `MeetingSidebarState.swift`:

```swift
enum MeetingSidebarSelectionPolicy {
    static func singleID(in selection: Set<MeetingID>) -> MeetingID?
    static func pruned(
        _ selection: Set<MeetingID>,
        to visibleOrExisting: Set<MeetingID>
    ) -> Set<MeetingID>
    static func draggedIDs(
        startingAt meetingID: MeetingID,
        selection: Set<MeetingID>
    ) -> Set<MeetingID>
}

struct FolderDisclosureStore {
    init(defaults: UserDefaults = .standard)
    func load() -> Set<FolderID>
    func save(_ folderIDs: Set<FolderID>)
    func remove(_ folderID: FolderID)
}
```

Speichere die Folder-IDs als sortiertes String-Array unter `steno.sidebar.expandedFolders`.

- [ ] **Step 4: Ersetze die Einzelauswahl im AppModel.**

Führe genau diesen gespeicherten Zustand:

```swift
var selectedMeetingIDs: Set<MeetingID> = [] {
    didSet { persistSingleMeetingSelection() }
}

var selectedMeetingID: MeetingID? {
    get { MeetingSidebarSelectionPolicy.singleID(in: selectedMeetingIDs) }
    set { selectedMeetingIDs = newValue.map { Set([$0]) } ?? [] }
}
```

Bei genau einer ID wird die bisherige UserDefaults-Kennung aktualisiert.
Bei einer leeren Menge wird sie entfernt.
Eine Mehrfachauswahl überschreibt die zuletzt echte Einzelauswahl nicht.
`restoreSelection` setzt die Menge auf genau die gespeicherte gültige ID.
`refreshMeetings` schneidet die Menge nach dem Laden auf existierende Meeting-IDs zu.

- [ ] **Step 5: Ergänze die Mehrfachzusammenfassung in der Detailspalte.**

Prüfe in `ContentView.detailContent` vor dem Einzelfall:

```swift
if model.selectedMeetingIDs.count > 1 {
    MultiMeetingSelectionView(count: model.selectedMeetingIDs.count)
} else if model.isRecording,
          model.selectedMeetingID == model.recordingMeetingID {
    RecordingView()
} else if let meetingID = model.selectedMeetingID {
    MeetingDetailView(meetingID: meetingID)
}
```

Die Zusammenfassung zeigt Anzahl, das System-Symbol `rectangle.stack.fill` und den Hinweis `Drag the selection into a folder or use Move Meetings.`.
Sie bleibt innerhalb `WindowStableDetail` und fordert keine eigene Mindestgröße an.

- [ ] **Step 6: Führe die fokussierten App-Tests grün aus.**

Run: `xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/MeetingSidebarStateTests -only-testing:StenoTests/WindowLayoutTests test`

Expected: PASS.

- [ ] **Step 7: Committe Auswahl und Detailzustand.**

```bash
git add App/Sources/MeetingSidebar/MeetingSidebarState.swift \
  App/Tests/MeetingSidebarStateTests.swift App/Sources/AppModel.swift \
  App/Sources/ContentView.swift App/Tests/WindowLayoutTests.swift
git commit -m "feat: add meeting multi-selection state"
```

### Task 7: Baum-Sidebar mit Kontextmenüs und Suche rendern

**Files:**
- Create: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `App/Sources/ContentView.swift`
- Modify: `App/Sources/AppModel+Folders.swift`
- Modify: `App/Tests/MeetingSidebarStateTests.swift`

**Interfaces:**
- Consumes: `MeetingSidebarTree`, `selectedMeetingIDs`, `FolderDisclosureStore` und die Batch-Aktionen aus früheren Tasks.
- Produces: `MeetingSidebarView`, `MeetingSidebarVisibility`, `MeetingSidebarActionPolicy`, gewöhnliche `DisclosureGroup`-Zeilen, die feste `Ordner`-Kopfzeile und `contextMenu(forSelectionType:)`.

- [ ] **Step 1: Ergänze rote Sichtbarkeits- und Menütests.**

Erweitere `MeetingSidebarStateTests` um reine Policies:

```swift
#expect(MeetingSidebarVisibility.visibleMeetingIDs(
    in: tree,
    expandedFolderIDs: [work.id, product.id]
) == Set([direct.id, demo.id, loose.id]))

#expect(MeetingSidebarActionPolicy.actions(for: [a, b]) == [.moveMeetings])
#expect(MeetingSidebarActionPolicy.actions(for: [a]) == [
    .rename, .moveMeetings, .retranscribe, .export, .trash,
])
```

Teste außerdem, dass Suchtreffer ihre Vorfahren in `effectiveExpandedFolderIDs` ergänzen, ohne den gespeicherten Set zu verändern.

- [ ] **Step 2: Führe die neuen Policy-Tests rot aus.**

Run: `xcodegen generate && xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/MeetingSidebarStateTests test`

Expected: FAIL mit fehlender Sichtbarkeits- und Aktionspolicy.

- [ ] **Step 3: Implementiere die reinen Sichtbarkeits- und Aktionspolicies.**

Definiere in `MeetingSidebarState.swift` die reinen Policies, auf denen die roten Tests beruhen:

```swift
enum MeetingSidebarAction: Equatable {
    case rename
    case moveMeetings
    case retranscribe
    case export
    case trash
}

enum MeetingSidebarActionPolicy {
    static func actions(
        for meetingIDs: Set<MeetingID>
    ) -> [MeetingSidebarAction]
}

enum MeetingSidebarVisibility {
    static func effectiveExpandedFolderIDs(
        in tree: MeetingSidebarTree,
        persisted: Set<FolderID>,
        isSearching: Bool
    ) -> Set<FolderID>

    static func visibleMeetingIDs(
        in tree: MeetingSidebarTree,
        expandedFolderIDs: Set<FolderID>
    ) -> Set<MeetingID>
}
```

- [ ] **Step 4: Extrahiere die bestehende Sidebar aus `ContentView.swift`.**

Verschiebe `MeetingListView`, `FolderDialogs` und `MeetingDialogs` nach `MeetingSidebarView.swift` und benenne die Hauptansicht `MeetingSidebarView`.
Lasse `StatusBadge` in `ContentView.swift`, sofern es auch außerhalb der Sidebar verwendet wird, andernfalls verschiebe es mit.
Ändere die Verdrahtung auf:

```swift
MeetingSidebarView(selection: $model.selectedMeetingIDs)
    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
```

- [ ] **Step 5: Rendere Baum und Datumsgruppen.**

Baue `tree` ausschließlich über:

```swift
MeetingSidebarTree.build(
    for: MeetingSearch.matching(model.meetings, query: query),
    folders: model.folders,
    hidesEmptyFolders: isSearching
)
```

Entferne jetzt den in Task 4 nur vorübergehend behaltenen flachen `MeetingGrouping.sections(for:folders:...)`-Overload und jede letzte App-Nutzung davon.

Die `List(selection: $selection)` enthält in dieser Reihenfolge:

1. Eine feste, nicht auswählbare `Ordner`-Kopfzeile.
2. Pro Hauptordner eine gewöhnliche `DisclosureGroup`-Zeile.
3. Innerhalb eines Hauptordners zuerst Unterordner als weitere `DisclosureGroup`-Zeilen, danach direkte Meetings.
4. Unterhalb des Ordnerbaums die vorhandenen Datumsüberschriften als normale nicht auswählbare Zeilen und deren Meetings.

Jede Meetingzeile trägt `.tag(meeting.id)`.
Folder- und Überschriftszeilen tragen keinen Meeting-Tag.
Setze `.selectionDisabled()` nur auf die jeweilige Label- oder Leerzeile, niemals auf den umschließenden `DisclosureGroup`, weil der Modifier sonst die auswählbaren Meetingkinder erben könnte.
Leere Ordner zeigen `Empty - move a meeting here`.

- [ ] **Step 6: Verdrahte Disclosure, Suche und Auswahlbereinigung.**

Der effektive Aufklappzustand ist bei normaler Ansicht der persistierte Set und bei Suche dessen Vereinigung mit allen Vorfahren von Treffern.
Nur Benutzeränderungen außerhalb einer Suche werden im `FolderDisclosureStore` gespeichert.
Beim Zuklappen und bei einer Suchänderung schneidet die Ansicht `selection` auf `MeetingSidebarVisibility.visibleMeetingIDs` zu.
Beim erfolgreichen Verschieben wird der Zielpfad in den gespeicherten Aufklappzustand aufgenommen.

- [ ] **Step 7: Ersetze Zeilen-Kontextmenüs durch ein Auswahl-Kontextmenü.**

Hänge an die `List`:

```swift
.contextMenu(forSelectionType: MeetingID.self) { meetingIDs in
    meetingSelectionMenu(for: meetingIDs)
}
```

Bei genau einer ID enthält das Menü die bisherigen Einzelaktionen und `Move to Folder`.
Bei mehreren IDs enthält es ausschließlich `Move N Meetings` mit Haupt- und Unterordnern sowie `None`.
Die Menüstruktur zeigt Unterordner eingerückt oder in einem Untermenü unter ihrem Hauptordner und ruft immer `model.moveMeetings(meetingIDs, to:)` auf.

Folderzeilen behalten ein eigenes Kontextmenü mit `New Subfolder...`, `Rename...`, geschwisterbezogenem `Move Up` und `Move Down`, `Move into Folder`, bei Unterordnern `Move to Top Level` sowie `Delete Folder...`.
Der Löschdialog nennt bei vorhandenen Kindern ausdrücklich, dass diese auf die Hauptebene verschoben werden.
`FolderDialogs` hält für Neuanlagen zusätzlich `newFolderParentID: FolderID?`; `New folder` setzt `nil`, `New Subfolder...` setzt die Kennung des Hauptordners und beide Wege rufen `model.createFolder(named:parentFolderID:)` auf.
Wenn `await model.deleteFolder(folder.id)` `true` liefert, entfernt die Ansicht die Folder-ID aus `FolderDisclosureStore`; bei `false` bleibt der persistierte Zustand bis zum Fehler-Refresh unangetastet.

- [ ] **Step 8: Ergänze barrierefreie Ordner- und Auswahlbeschriftungen.**

Jede Folderzeile nennt per Accessibility-Wert die Zahl direkter Meetings und Unterordner.
Die feste Kopfzeile erklärt `Drop a nested folder here to move it to the top level.`.
Die Mehrfachzusammenfassung nennt die Auswahlanzahl bereits als sichtbaren Text und wiederholt sie nicht in einem dekorativen Symbol-Label.
Prüfe, dass jede Drag-Aktion weiterhin dieselbe Menüaktion besitzt.

- [ ] **Step 9: Führe Policytests und macOS-Build aus.**

Run: `xcodegen generate && xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/MeetingSidebarStateTests test`

Expected: PASS.

Run: `scripts/build-app.sh`

Expected: `BUILD SUCCEEDED` und die extrahierte Sidebar kompiliert ohne Typchecker-Timeout.

- [ ] **Step 10: Committe die sichtbare Baum-Sidebar.**

```bash
git add App/Sources/MeetingSidebar/MeetingSidebarView.swift \
  App/Sources/MeetingSidebar/MeetingSidebarState.swift \
  App/Sources/ContentView.swift App/Sources/AppModel+Folders.swift \
  App/Tests/MeetingSidebarStateTests.swift
git commit -m "feat: render nested meeting sidebar"
```

### Task 8: Getrennte Drag-and-drop-Nutzlasten und Drop-Ziele

**Files:**
- Create: `App/Sources/MeetingSidebar/MeetingSidebarTransfer.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarState.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `App/Tests/MeetingSidebarStateTests.swift`

**Interfaces:**
- Consumes: Auswahlpolicy, Storevalidierung und App-Batchmethoden.
- Produces: `MeetingDragPayload`, `FolderDragPayload`, getrennte UTTypes und vollständige Meeting- sowie Folder-Drops.

- [ ] **Step 1: Schreibe rote Payload- und Drop-Vorschautests.**

Teste Codable-Roundtrips beider Payloads und die reine Folder-Drop-Policy:

```swift
#expect(MeetingSidebarDropPolicy.canMove(
    folder: emptyRoot.id,
    onto: work.id,
    folders: folders
))
#expect(!MeetingSidebarDropPolicy.canMove(
    folder: work.id,
    onto: product.id,
    folders: folders
))
#expect(!MeetingSidebarDropPolicy.canMove(
    folder: rootWithChildren.id,
    onto: work.id,
    folders: folders
))
#expect(MeetingSidebarDropPolicy.canPromote(
    folder: product.id,
    folders: folders
))
```

- [ ] **Step 2: Führe die Payloadtests rot aus.**

Run: `xcodegen generate && xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/MeetingSidebarStateTests test`

Expected: FAIL mit fehlenden Transfer- und Drop-Typen.

- [ ] **Step 3: Definiere getrennte lokale Transferables.**

Lege zwei UTTypes und Payloads an:

```swift
extension UTType {
    static let stenoMeetingSelection = UTType(
        exportedAs: "org.steno.meeting-selection"
    )
    static let stenoFolder = UTType(exportedAs: "org.steno.folder")
}

struct MeetingDragPayload: Codable, Hashable, Identifiable, Transferable {
    let meetingIDs: [MeetingID]
    var id: String { meetingIDs.map(\.description).joined(separator: ",") }
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stenoMeetingSelection)
    }
}

struct FolderDragPayload: Codable, Hashable, Identifiable, Transferable {
    let folderID: FolderID
    var id: FolderID { folderID }
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stenoFolder)
    }
}
```

Sortiere Meeting-IDs beim Erzeugen stabil nach ihrer Beschreibung.
Die Nutzlast enthält keine Titel, Dateipfade oder Meetinginhalte.

Definiere im selben Task die reine Preview-Policy:

```swift
enum MeetingSidebarDropPolicy {
    static func canMove(
        folder folderID: FolderID,
        onto parentFolderID: FolderID,
        folders: [Folder]
    ) -> Bool

    static func canPromote(
        folder folderID: FolderID,
        folders: [Folder]
    ) -> Bool
}
```

Die Policy spiegelt Elternexistenz, maximale Tiefe, Selbstbezug und vorhandene Kinder für die Vorschau.
Der `FolderStore` bleibt beim Schreiben die autoritative zweite Prüfung.

- [ ] **Step 4: Berechne Meeting-Payloads erst beim Drag-Start.**

Verwende die Closure-Variante der macOS-26-API:

```swift
.draggable(MeetingDragPayload.self) {
    let ids = MeetingSidebarSelectionPolicy.draggedIDs(
        startingAt: meeting.id,
        selection: selection
    )
    return MeetingDragPayload(meetingIDs: ids.sorted())
}
```

Ordnerzeilen liefern analog genau ihre `FolderDragPayload`.

- [ ] **Step 5: Ergänze Meeting- und Folder-Drop-Ziele.**

Jede Folderzeile akzeptiert `MeetingDragPayload` und ruft nach erneutem Store-Check `model.moveMeetings(Set(payload.meetingIDs), to: folder.id)` auf.
Sie akzeptiert `FolderDragPayload` nur, wenn die reine Preview-Policy zustimmt; der `FolderStore` validiert beim eigentlichen Schreiben nochmals autoritativ.

Die feste `Ordner`-Kopfzeile akzeptiert ausschließlich verschachtelte `FolderDragPayload` und ruft `model.moveFolder(folderID, to: nil)` auf.
Akzeptiere pro Drop genau eine Transferable-Nutzlast; eine Meeting-Nutzlast enthält selbst bereits die gesamte Meetingauswahl.

Verwende auf macOS 26 `onDropSessionUpdated` und `dropConfiguration`, damit lokale Folder-Drags schon vor dem Drop autoritativ als `.move` oder `.forbidden` dargestellt werden.
Lies die gezogene Folder-ID aus `session.localSession?.draggedItemIDs(for: FolderID.self)` und gib nur bei genau einer durch `MeetingSidebarDropPolicy` erlaubten ID `DropConfiguration(operation: .move)` zurück.
Ein lokaler Meeting-Drag ist an genau einer `MeetingDragPayload.ID` vom Typ `String` erkennbar und auf einen existierenden Folder immer `.move`; seine Meeting-IDs werden nach dem Decode erneut durch das AppModel validiert.
Die Zeile zeigt ihren Akzenthintergrund nur in den Phasen `.entering` oder `.active` einer gültigen lokalen Session.
Die eigentliche `dropDestination`-Action prüft Payloadanzahl und Storezustand nochmals, bevor sie einen Task startet.
Ein ungültiges Ziel verwendet `.forbidden`, startet keinen Task und verändert keine Auswahl.

- [ ] **Step 6: Führe App-Tests und fokussierte Store-Tests aus.**

Run: `xcodegen generate && xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -only-testing:StenoTests/MeetingSidebarStateTests test`

Expected: PASS.

Run: `swift test --package-path StenoKit --filter FolderStoreTests`

Expected: PASS.

- [ ] **Step 7: Committe Drag-and-drop.**

```bash
git add App/Sources/MeetingSidebar/MeetingSidebarTransfer.swift \
  App/Sources/MeetingSidebar/MeetingSidebarState.swift \
  App/Sources/MeetingSidebar/MeetingSidebarView.swift \
  App/Tests/MeetingSidebarStateTests.swift
git commit -m "feat: drag meetings and folders in sidebar"
```

### Task 9: Konsolidierte Verifikation und isolierte manuelle Abnahme

**Files:**
- Modify only if a reproduced failure requires a targeted fix.
- Update without committing: `HANDOFF-audio-core-extraction.md`

**Interfaces:**
- Consumes: Alle vorherigen Tasks und die manuelle Abnahmeliste der Spezifikation.
- Produces: Einen reproduzierbar grünen Build, eine isolierte UI-Abnahme und einen sauberen lokalen Commitstand ohne Push.

- [ ] **Step 1: Prüfe Diff, Scope und Testartefakte vor dem Abschlusslauf.**

Run: `git status --short`

Expected: Nur die beabsichtigten Featureänderungen sowie die bekannten ungetrackten `.superpowers/` und `UEBERGABE-sprecher-erkenntnisse.md`.

Run: `git diff --check`

Expected: Keine Ausgabe.

Run: `du -sh .build 2>/dev/null || true`

Expected: Größe ist bekannt; bei mehr als 5 GB wird nur task-eigener, nicht von Prozessen verwendeter regenerierbarer Ballast gezielt bereinigt.

- [ ] **Step 2: Führe die vollständige vorgeschriebene Kernkette genau einmal aus.**

Run: `xcodegen generate && scripts/build-app.sh && scripts/build-ios.sh && swift test --package-path StenoKit`

Expected: Beide Builds enden mit `BUILD SUCCEEDED`; alle StenoKit-Tests bestehen.

- [ ] **Step 3: Führe die vollständige macOS-App-Testsuite aus.**

Run: `xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' test`

Expected: Alle `StenoTests` bestehen, einschließlich Sidebar- und Fensterlayouttests.

- [ ] **Step 4: Starte genau einen isolierten manuellen Build.**

Erzeuge zwei task-eigene Verzeichnisse mit `mktemp -d` und starte direkt das gebaute Binary mit `STENO_LIBRARY_DIR` und `STENO_MODEL_DIR` auf diese Verzeichnisse gesetzt.
Verwende keine nutzereigene Bibliothek für Drag-, Delete- oder Migrationsversuche.
Prüfe vor dem Start per Prozessliste, dass keine zweite Instanz desselben Debug-Builds läuft und dass keine Aufnahme geöffnet ist.

- [ ] **Step 5: Führe die manuelle UX-Abnahme aus.**

Prüfe sichtbar in dieser Reihenfolge:

1. Mindestens fünf Draft-Meetings und die Hauptordner `Arbeit` und `Privat` anlegen.
2. Unter `Arbeit` die Unterordner `Meetings` und `Produktvorstellung` anlegen.
3. Drei benachbarte Meetings mit `Shift` und ein weiteres mit `Cmd` auswählen.
4. Die Auswahl in `Arbeit/Produktvorstellung` ziehen und prüfen, dass alle vier ausgewählt und sichtbar bleiben.
5. Eine andere Zeile ziehen und prüfen, dass nur diese Zeile bewegt wird.
6. Mehrere Meetings über `Move N Meetings` nach `None` verschieben.
7. Einen leeren Hauptordner auf `Arbeit` ziehen, dann über die feste `Ordner`-Kopfzeile wieder hochstufen.
8. Einen unzulässigen Drop auf einen Unterordner versuchen und prüfen, dass nichts verändert wird.
9. Den Suchtreffer eines geschlossenen Unterordners anzeigen und danach den vorherigen Aufklappzustand wiederfinden.
10. Einen Hauptordner mit Kind löschen und prüfen, dass das Kind samt Meetings als Hauptordner erhalten bleibt.
11. Alle Schritte mit einem nicht maximierten Fenster durchführen und prüfen, dass Größe und Zustand unverändert bleiben.
12. Prüfen, dass der erste Hauptordner nach Start, Suche und Refresh sichtbar ist.

- [ ] **Step 6: Behebe nur tatsächlich reproduzierte Abnahmefehler testgetrieben.**

Für jeden Fehler zuerst den kleinsten roten automatisierten Test ergänzen, dann den minimalen Fix schreiben und nur den fokussierten Test erneut ausführen.
Falls ausschließlich eine perzeptive Drag-Hervorhebung betroffen ist, dokumentiere die manuelle Reproduktion und prüfe den Fix erneut in derselben isolierten Bibliothek.
Wiederhole die unveränderte vollständige Suite nicht ohne konkreten Grund.

- [ ] **Step 7: Räume nur task-eigene temporäre Artefakte auf.**

Beende den isolierten Debug-Build, prüfe, dass kein Prozess die beiden `mktemp`-Verzeichnisse verwendet, und entferne ausschließlich diese beiden Verzeichnisse.
Behalte `.build` als einzigen aktuellen runnable Build für eine mögliche Nutzerabnahme.
Berühre weder echte Steno-Aufnahmen noch fremde Worktrees oder Caches.

- [ ] **Step 8: Aktualisiere Handoff und sichere einen eventuell nötigen Abschlussfix.**

Wenn Step 6 dieses Tasks einen Codefix erzeugt hat, committe ausschließlich dessen Test und Implementierung mit einer spezifischen Nachricht.
Aktualisiere danach uncommittet `HANDOFF-audio-core-extraction.md` mit Branch, letztem Commit, verifizierten Befehlen, manueller Abnahme, behaltenem `.build` und entfernten temporären Verzeichnissen.

- [ ] **Step 9: Prüfe den finalen lokalen Stand.**

Run: `git status --short && git log -10 --oneline`

Expected: Kein beabsichtigter Featurecode ist uncommittet; `.superpowers/`, `UEBERGABE-sprecher-erkenntnisse.md` und der Handoff bleiben ungetrackt beziehungsweise ignoriert und wurden nicht committed.
Es erfolgt kein Push.
