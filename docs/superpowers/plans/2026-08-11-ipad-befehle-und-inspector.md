# iPad-Befehle und funktionaler Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das aktive iPad-Fenster kann Steno per Menueleiste und Tastatur steuern und im Inspector Notizen sowie Sprecherzuweisungen bearbeiten.

**Architecture:** Ein fensterlokaler `NavigationRouter` stellt seine Aktionen ueber `FocusedSceneValue` den App-Commands bereit. `MeetingDetailView` verwendet die portable Notizsession und `MeetingReviewController` fuer einen echten schreibenden Inspector.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, FocusedSceneValue, Swift Testing, XcodeGen, iOS Simulator.

## Global Constraints

- Aufnahme und Bibliothek bleiben prozessweit, Auswahl, Suche und Inspector bleiben fensterlokal.
- Cmd-R startet, Cmd-Punkt stoppt, Cmd-M markiert, Cmd-N erstellt einen Entwurf und Cmd-F fokussiert die Suche.
- Ein fehlendes Sprachmodell darf die Aufnahme nicht sperren.
- Sprecheraktionen verwenden den gemeinsamen Wahrheitsschutz und `MeetingReviewController`.
- Simulatorbefunde duerfen nicht als Hardwareabnahme ausgegeben werden.

---

### Task 1: Fensterlokales Routing und Commands

**Files:**
- Create: `iOS/App/Sources/NavigationRouter.swift`
- Create: `iOS/App/Sources/StenoCommands.swift`
- Modify: `iOS/App/Sources/StenoApp.swift`
- Modify: `iOS/App/Sources/ContentView.swift`
- Create: `iOS/App/Tests/NavigationRouterTests.swift`
- Create: `iOS/App/Tests/StenoCommandStateTests.swift`

**Interfaces:**
- Consumes: `AppModel`, `RecordingModel`, `MeetingID`.
- Produces: `NavigationRouter`, `SidebarItem`, `StenoFocusedActions`, `StenoCommands`, `StenoCommandState`.

- [ ] **Step 1: Write failing router and availability tests**

```swift
@Test @MainActor func selectingMeetingKeepsWindowLocalState() {
    let first = NavigationRouter()
    let second = NavigationRouter()
    let id = MeetingID()
    first.select(.meeting(id))
    #expect(first.selection == .meeting(id))
    #expect(second.selection == .recording)
}

@Test func stopAndMarkRequireActiveRecording() {
    let idle = StenoCommandState(libraryReady: true, recordingActive: false, hasMeeting: true)
    #expect(idle.canStartRecording)
    #expect(!idle.canStopRecording)
    #expect(!idle.canMark)
}
```

- [ ] **Step 2: Run the focused iOS tests and verify RED**

Run: `cd iOS && xcodegen generate && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:StenoTests/NavigationRouterTests -only-testing:StenoTests/StenoCommandStateTests test`

Expected: compilation fails because the router and command state do not exist.

- [ ] **Step 3: Implement focused scene actions and menus**

```swift
@MainActor
@Observable
final class NavigationRouter {
    private(set) var selection: SidebarItem = .recording
    var findRequest = 0
    var inspectorRequest = 0
    func select(_ item: SidebarItem) { selection = item }
}

struct StenoFocusedActions {
    let showRecording: () -> Void
    let showMeeting: (MeetingID) -> Void
    let requestFind: () -> Void
    let toggleInspector: () -> Void
}
```

Expose the active window's actions through `FocusedSceneValue`.
Capture the process-wide `AppModel` in `StenoApp.commands` only for recording work; use focused actions for navigation, find and inspector.

- [ ] **Step 4: Verify focused tests and iOS build**

Run the two focused test classes from Step 2.

Run: `scripts/build-ios.sh`

Expected: tests and build pass.

- [ ] **Step 5: Commit routing and commands**

```bash
git add iOS/App/Sources/NavigationRouter.swift iOS/App/Sources/StenoCommands.swift iOS/App/Sources/StenoApp.swift iOS/App/Sources/ContentView.swift iOS/App/Tests/NavigationRouterTests.swift iOS/App/Tests/StenoCommandStateTests.swift
git commit -m "feat(ipad): Menuebefehle fensterbezogen anbinden"
```

### Task 2: Draft, Suche und Inspectorzustand

**Files:**
- Modify: `iOS/App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/ContentView.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Create: `iOS/App/Tests/MeetingInspectorPresentationTests.swift`
- Modify: `iOS/App/Tests/MeetingPresentationTests.swift`

**Interfaces:**
- Consumes: `NavigationRouter` and focused requests from Task 1, `MeetingNotesEditingSession` from the annotations plan.
- Produces: `AppModel.createDraftMeeting()`, programmatic search focus, inspector visibility and automatic draft inspector opening.

- [ ] **Step 1: Write failing draft and inspector-state tests**

```swift
@Test func draftOpensInspectorWhileOrdinaryMeetingDoesNotForceIt() {
    #expect(MeetingInspectorPresentation.shouldOpenAutomatically(status: .draft, review: nil))
    #expect(!MeetingInspectorPresentation.shouldOpenAutomatically(status: .complete, review: nil))
}
```

Add a temporary-library integration test that creates a draft through the same AppModel helper and verifies status plus selection target.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:StenoTests/MeetingInspectorPresentationTests test`

Expected: compilation fails because the inspector presentation helper does not exist.

- [ ] **Step 3: Implement draft creation, search focus and inspector shell**

```swift
@discardableResult
func createDraftMeeting() async -> MeetingID? {
    guard let runtime else { return nil }
    let meeting = try await runtime.library.createMeeting(
        title: Self.draftTitle(),
        status: .draft
    )
    await reloadMeetings()
    return meeting.id
}
```

Make Cmd-N await this method and select the result in the focused window.
Use `searchFocused` for Cmd-F and `.inspector(isPresented:)` for details.
In compact width keep the system's sheet behavior rather than a second custom layout.

- [ ] **Step 4: Verify focused tests and iPhone/iPad builds**

Run the focused tests from Step 2.

Run: `scripts/build-ios.sh`

Expected: tests and build pass.

- [ ] **Step 5: Commit the inspector shell**

```bash
git add iOS/App/Sources/AppModel.swift iOS/App/Sources/ContentView.swift iOS/App/Sources/MeetingDetailView.swift iOS/App/Tests/MeetingInspectorPresentationTests.swift iOS/App/Tests/MeetingPresentationTests.swift
git commit -m "feat(ipad): Entwuerfe und Inspector anbinden"
```

### Task 3: Schreibende Sprecherpruefung im Inspector

**Files:**
- Create: `iOS/App/Sources/SpeakerReviewSection.swift`
- Create: `iOS/App/Sources/MeetingNotesSection.swift`
- Modify: `iOS/App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Create: `iOS/App/Tests/SpeakerReviewPresentationTests.swift`

**Interfaces:**
- Consumes: `MeetingReviewController`, `SpeakerPresentationResolver`, `MeetingNotesEditingSession`.
- Produces: `AppModel.performReview`, `AppModel.allPersons`, `AppModel.notesSession`, functional inspector sections.

- [ ] **Step 1: Write failing speaker action tests**

```swift
@Test func multipleClusterOffersNoPersonConfirmation() {
    let cluster = IdentityCluster(
        meetingID: MeetingID(),
        runID: RunID(),
        channel: MediaAsset.Kind.micTrack.rawValue,
        clusterID: "SPEAKER_0",
        recordingType: .inPerson,
        embedding: [1, 0],
        speechDurationSeconds: 20,
        segmentCount: 3,
        containsMultipleSpeakers: true,
        reviewState: .multiple
    )
    let actions = SpeakerReviewPresentation.actions(
        for: cluster,
        suggestion: nil
    )
    #expect(!actions.contains(.confirmSuggestion))
    #expect(!actions.contains(.assignPerson))
    #expect(actions.contains(.resetToGeneric))
}
```

Add tests named `confirmedSuggestionCanBeConfirmed`, `possibleSuggestionCannotBeConfirmed`, `selfClusterHasNoNamingActions`, `confirmedClusterCanBeReassigned` and `genericClusterCanBeAssigned`.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:StenoTests/SpeakerReviewPresentationTests test`

Expected: compilation fails because `SpeakerReviewPresentation` does not exist.

- [ ] **Step 3: Implement portable write calls and truthful controls**

```swift
func performReview(
    _ action: MeetingReviewController.Action,
    on cluster: IdentityCluster,
    data: MeetingReviewData,
    meetingID: MeetingID
) async -> MeetingReviewData?
```

Use this method for all inspector actions and replace the local review only with the returned current state.
Render known participants from confirmed people.
Render notes through the cached `MeetingNotesEditingSession`.
Do not add sample playback or a guessed participant.

- [ ] **Step 4: Verify focused tests and iOS build**

Run the focused tests from Step 2.

Run: `scripts/build-ios.sh`

Expected: tests and build pass.

- [ ] **Step 5: Commit the functional inspector**

```bash
git add iOS/App/Sources/SpeakerReviewSection.swift iOS/App/Sources/MeetingNotesSection.swift iOS/App/Sources/AppModel.swift iOS/App/Sources/MeetingDetailView.swift iOS/App/Tests/SpeakerReviewPresentationTests.swift
git commit -m "feat(ipad): Sprecher im Inspector pruefen"
```

### Task 4: Reproduzierbare iPad-Simulatorauswahl

**Files:**
- Modify: `scripts/build-ios.sh`
- Create: `scripts/tests/test-build-ios-arguments.sh`

**Interfaces:**
- Consumes: `xcrun simctl` device list and an optional simulator UDID.
- Produces: `scripts/build-ios.sh --simulator [UDID]` and `--ipad-simulator` with deterministic destination selection.

- [ ] **Step 1: Write failing argument tests**

```bash
#!/bin/bash
set -euo pipefail

actual="$(scripts/build-ios.sh --print-destination --simulator AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)"
test "$actual" = "platform=iOS Simulator,id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

if SIMCTL_DEVICES_JSON='{"devices":{}}' scripts/build-ios.sh --print-destination --ipad-simulator 2>"${TMPDIR}/steno-ipad-error"; then
    exit 1
fi
grep -F "No available iPad simulator" "${TMPDIR}/steno-ipad-error"
```

- [ ] **Step 2: Run the script tests and verify RED**

Run: `bash scripts/tests/test-build-ios-arguments.sh`

Expected: the new options are rejected by the current script.

- [ ] **Step 3: Implement destination parsing without changing device builds**

Keep `--device [UUID]` behavior unchanged.
For `--simulator [UDID]`, use the provided identifier or the first booted simulator.
For `--ipad-simulator`, select a booted iPad or create and boot the installed iPad model named by the script.
`--print-destination` prints the resolved destination and exits before generating or building.

- [ ] **Step 4: Verify script, simulator build and full iOS tests**

Run: `bash scripts/tests/test-build-ios-arguments.sh`

Run: `scripts/build-ios.sh --ipad-simulator`

Run: `cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination "$(../scripts/build-ios.sh --print-destination --ipad-simulator)" test`

Expected: the argument tests pass and, when CoreSimulatorService is healthy, build and tests succeed on the selected iPad.

- [ ] **Step 5: Commit deterministic simulator support**

```bash
git add scripts/build-ios.sh scripts/tests/test-build-ios-arguments.sh
git commit -m "build(ios): iPad-Simulator gezielt auswaehlen"
```
