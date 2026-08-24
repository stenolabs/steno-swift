# Persistente Aufnahmeannotationen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notizen und Zeitmarken verwenden auf macOS und iOS dieselbe serialisierte, absturzrobuste Bearbeitungssitzung.

**Architecture:** Eine `@MainActor`-gebundene `MeetingNotesEditingSession` in StenoLibrary besitzt den aktuellen Text, Debounce-Generation und Fehlerzustand. Beide Apps cachen genau eine Session pro Meeting, sodass Editor und Marker niemals mit getrennten Snapshots schreiben.

**Tech Stack:** Swift 6.3, Observation, Swift Testing, StenoLibrary, SwiftUI.

## Global Constraints

- Ein Notizfehler darf Audioaufnahme, Spurregistrierung und Final-ASR nicht verhindern.
- Marker bleiben Text im Format `[HH:MM:SS] ` in `user-notes.md`.
- `legacy-user-notes.md` und Audiooriginale bleiben unveraendert.
- Kein neues Persistenzschema und keine Migration bestehender Meetings.
- Alte Debounce-Tasks duerfen neuere Texte oder Marker nicht ueberschreiben.

---

### Task 1: Gemeinsame Bearbeitungssitzung

**Files:**
- Create: `StenoKit/Sources/StenoLibrary/MeetingNotesEditingSession.swift`
- Create: `StenoKit/Tests/StenoLibraryTests/MeetingNotesEditingSessionTests.swift`
- Modify: `StenoKit/Sources/StenoLibrary/MeetingNotesStore.swift`
- Modify: `StenoKit/Tests/StenoLibraryTests/MeetingNotesStoreTests.swift`

**Interfaces:**
- Consumes: `MeetingNotesStore`, `MeetingID`, `Duration`.
- Produces: `MeetingNotesPersistence`, `MeetingNotesEditingSession.load()`, `update(_:)`, `appendMarker(elapsed:)`, `flush()`, observable `text`, `isSaving`, `errorMessage`.

- [ ] **Step 1: Write failing store and session tests**

```swift
@Test @MainActor func pendingTextAndImmediateMarkerAreSavedTogether() async throws {
    try await withTemporaryDirectory { root in
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Rat", status: .recording)
        let store = MeetingNotesStore(layout: library.layout)
        let session = MeetingNotesEditingSession(
            meetingID: meeting.id,
            store: store,
            autosaveDelay: .seconds(60)
        )
        await session.load()
        session.update("Budgetfreigabe")
        await session.appendMarker(elapsed: 65)
        #expect(session.text == "Budgetfreigabe\n[00:01:05] ")
        #expect(try await store.notes(meeting.id) == session.text)
    }
}

@Test @MainActor func staleAutosaveCannotOverwriteMarker() async throws {
    try await withTemporaryDirectory { root in
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Rat", status: .recording)
        let store = MeetingNotesStore(layout: library.layout)
        let session = MeetingNotesEditingSession(
            meetingID: meeting.id,
            store: store,
            autosaveDelay: .milliseconds(20)
        )
        await session.load()
        session.update("Erster Stand")
        await session.appendMarker(elapsed: 3)
        try await Task.sleep(for: .milliseconds(60))
        #expect(try await store.notes(meeting.id) == "Erster Stand\n[00:00:03] ")
    }
}
```

Add tests named `markerStartsEmptyNote`, `markerCopiesLegacyTextIntoOwnNote`, `markerFormatsMoreThanOneHour` and `writeFailureLeavesTextVisibleForRetry`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --package-path StenoKit --filter MeetingNotesEditingSessionTests`

Expected: compilation fails because `MeetingNotesEditingSession` does not exist.

- [ ] **Step 3: Implement generation-safe editing and marker formatting**

```swift
public protocol MeetingNotesPersistence: Sendable {
    func notes(_ meetingID: MeetingID) async throws -> String?
    func setNotes(_ meetingID: MeetingID, to notes: String?) async throws
}

@MainActor
@Observable
public final class MeetingNotesEditingSession {
    public private(set) var text = ""
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    public func load() async
    public func update(_ value: String)
    public func appendMarker(elapsed: TimeInterval) async
    public func flush() async
}
```

Conform `MeetingNotesStore` to `MeetingNotesPersistence` and inject that protocol into the session so the write-failure test uses a deterministic throwing actor without changing the filesystem.
Every `update` increments a generation and replaces the delayed save task.
`appendMarker` cancels that task, appends to the current in-memory text, increments the generation and persists immediately.
Only a save whose captured generation is still current may update `savedText`, `isSaving` or `errorMessage`.

- [ ] **Step 4: Run the focused and library tests and verify GREEN**

Run: `swift test --package-path StenoKit --filter MeetingNotesEditingSessionTests`

Run: `swift test --package-path StenoKit --filter MeetingNotesStoreTests`

Expected: all focused tests pass.

- [ ] **Step 5: Commit the shared session**

```bash
git add StenoKit/Sources/StenoLibrary/MeetingNotesEditingSession.swift StenoKit/Sources/StenoLibrary/MeetingNotesStore.swift StenoKit/Tests/StenoLibraryTests/MeetingNotesEditingSessionTests.swift StenoKit/Tests/StenoLibraryTests/MeetingNotesStoreTests.swift
git commit -m "feat(core): Aufnahmeannotationen serialisieren"
```

### Task 2: macOS-Editor und Cmd-M auf dieselbe Session legen

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/AppModel+Review.swift`
- Modify: `App/Sources/NotesSection.swift`

**Interfaces:**
- Consumes: `MeetingNotesEditingSession` from Task 1.
- Produces: `AppModel.notesSession(for:)`, session-backed `NotesSection`, session-backed `markMoment()`.

- [ ] **Step 1: Add a failing marker-format regression at the shared boundary**

Extend `MeetingNotesEditingSessionTests` with a sequence that updates text twice, invokes a marker between both updates and flushes.
Assert that both text edits and the marker remain in their visible order.

- [ ] **Step 2: Run the regression and verify RED**

Run: `swift test --package-path StenoKit --filter MeetingNotesEditingSessionTests`

Expected: the new ordering assertion fails until the session update path preserves the canonical current text.

- [ ] **Step 3: Wire macOS to one cached session per meeting**

Add a stored cache to `AppModel`:

```swift
private var notesSessions: [MeetingID: MeetingNotesEditingSession] = [:]

func notesSession(for meetingID: MeetingID) async -> MeetingNotesEditingSession?
```

Make `NotesSection` bind through `session.update(_:)` and render `session.isSaving` plus `session.errorMessage`.
Make `markMoment()` call `session.appendMarker(elapsed:)` instead of a separate read-modify-write.
Flush the session on view disappearance and meeting switch.

- [ ] **Step 4: Verify the regression and macOS build**

Run: `swift test --package-path StenoKit --filter MeetingNotesEditingSessionTests`

Run: `scripts/build-app.sh`

Expected: both commands exit successfully.

- [ ] **Step 5: Commit the macOS integration**

```bash
git add App/Sources/AppModel.swift App/Sources/AppModel+Review.swift App/Sources/NotesSection.swift StenoKit/Tests/StenoLibraryTests/MeetingNotesEditingSessionTests.swift
git commit -m "fix(mac): Marker und Notizen gemeinsam speichern"
```

### Task 3: iOS-Notizen und Marker persistieren

**Files:**
- Modify: `iOS/App/Sources/RecordingModel.swift`
- Modify: `iOS/App/Sources/RecordingView.swift`
- Modify: `iOS/App/Tests/RecordingPresentationTests.swift`
- Modify: `iOS/App/Tests/RecordingFinalizerTests.swift`

**Interfaces:**
- Consumes: `MeetingNotesEditingSession` from Task 1.
- Produces: session-backed `RecordingModel.updateNotes(_:)`, async `mark()`, nonfatal `annotationFailure`.

- [ ] **Step 1: Write failing iOS presentation and lifecycle tests**

```swift
@Test func savedAnnotationsDoNotShowTheLossWarning() {
    #expect(RecordingPresentation.annotationMessage(
        hasContent: true,
        isSaving: false,
        failure: nil
    ) == nil)
}

@Test func annotationFailureIsSeparateFromRecordingFailure() {
    #expect(RecordingPresentation.annotationMessage(
        hasContent: true,
        isSaving: false,
        failure: "Disk full"
    ) == "Notes could not be saved: Disk full")
}
```

Add a `RecordingModel` integration test with a temporary `PipelineRuntime` that writes a note, marks, stops and reopens `MeetingNotesStore`.

- [ ] **Step 2: Run the iOS tests and verify RED**

Run: `cd iOS && xcodegen generate && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:StenoTests/RecordingPresentationTests test`

Expected: compilation fails because `annotationMessage` and the persistent annotation API do not exist.

- [ ] **Step 3: Integrate the shared session without coupling it to audio success**

After meeting creation, create and load one session from the runtime layout.
Route the text binding through `updateNotes(_:)` and make `mark()` async.
After the audio session is closed, call `flush()` before returning to idle, but map its error only to `annotationFailure`.
Remove the loss warning and render saving or failure state from `RecordingPresentation.annotationMessage`.

- [ ] **Step 4: Verify iOS tests and build**

Run: `scripts/build-ios.sh`

Run: `cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test`

Expected: the build passes; the test command passes after Task 4 of the iPad plan has selected and booted the named runtime.

- [ ] **Step 5: Commit the iOS integration**

```bash
git add iOS/App/Sources/RecordingModel.swift iOS/App/Sources/RecordingView.swift iOS/App/Tests/RecordingPresentationTests.swift iOS/App/Tests/RecordingFinalizerTests.swift
git commit -m "feat(ios): Aufnahmeannotationen behalten"
```
