# iOS Meeting Actions and Job Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make retranscription and recoverable meeting deletion discoverable on iOS and show durable queued/running pipeline state.

**Architecture:** Keep `JobStore` and `Library.trashMeeting` as the authoritative persistence boundaries. Extend the shared notes-session lifecycle so deletion cannot race autosave, then expose small AppModel operations and pure presentation policies to the existing SwiftUI views.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, StenoKit, XcodeGen

**Spec:** `docs/superpowers/specs/2026-08-23-ios-meeting-actions-und-jobstatus-design.md`

## Global Constraints

- Original recordings are moved to the system Trash, never overwritten or hard-deleted.
- A currently active recording cannot be deleted or retranscribed.
- The status UI uses persisted job states and never invents a percentage.
- Existing transcript revisions remain unchanged.
- No dependency changes.
- No remote push or merge.

---

### Task 1: Make notes sessions safe for meeting removal

**Files:**
- Modify: `StenoKit/Sources/StenoLibrary/MeetingNotesEditingSession.swift`
- Modify: `StenoKit/Sources/StenoLibrary/MeetingNotesSessionPool.swift`
- Test: `StenoKit/Tests/StenoLibraryTests/MeetingNotesEditingSessionTests.swift`
- Test: `StenoKit/Tests/StenoLibraryTests/MeetingNotesSessionPoolTests.swift`

**Interfaces:**
- Consumes: `MeetingNotesPersistence.setNotes(_:to:)`
- Produces: `MeetingNotesSessionPool.prepareForMeetingRemoval(_:) async throws`, `cancelMeetingRemoval(_:)`, and `completeMeetingRemoval(_:)`

- [ ] **Step 1: Write failing session tests**

Add tests which load a real `MeetingNotesEditingSession`, update pending text, prepare it for removal, and assert that the pending text is persisted while further edits are rejected.
Add a failure test which makes persistence reject the preparation write, then asserts that editing becomes available again and a later retry can save.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter MeetingNotesEditingSessionTests
```

Expected: compilation fails because the removal lifecycle does not exist.

- [ ] **Step 3: Implement the minimal session lifecycle**

Add an internal prepare/cancel/complete state to `MeetingNotesEditingSession`.
Preparation must disable edits before its first suspension, cancel and await the former autosave, persist the latest snapshot, and restore editability on failure.
Completion must permanently invalidate the session so later `flush()` and `update(_:)` calls cannot write.

- [ ] **Step 4: Add and run the pool contract test**

Test that the pool forwards preparation and removes the completed session from its cache.
Run:

```bash
swift test --package-path StenoKit --filter MeetingNotesSessionPoolTests
```

Expected: PASS, including the existing shared-load test.

### Task 2: Add the AppModel deletion boundary

**Files:**
- Modify: `iOS/App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/AppModel+Review.swift`
- Create: `iOS/App/Tests/AppModelMeetingDeletionTests.swift`

**Interfaces:**
- Consumes: the notes-session removal API from Task 1, `PipelineCoordinator.cancel(jobID:)`, `Library.trashMeeting(_:)`, and `JobStore.removeJobs(meetingID:)`
- Produces: `AppModel.deleteMeeting(_:) async throws -> MeetingDeletionOutcome`

- [ ] **Step 1: Write failing AppModel integration tests**

Build a temporary real library and job store with an injectable meeting trasher.
Test that deletion cancels a queued job, invokes the trasher once, removes the meeting from `app.meetings`, and removes the job record.
Test that a trash failure keeps the meeting visible and releases the prepared notes session.
Test the pure runtime guard that rejects the currently active recording.

- [ ] **Step 2: Run the focused iOS tests and verify RED**

Regenerate the project, then run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  -only-testing:StenoTests/AppModelMeetingDeletionTests test
```

Expected: compilation fails because `deleteMeeting(_:)` and its outcome do not exist.

- [ ] **Step 3: Implement minimal deletion orchestration**

Add an injectable `meetingTrasher` with the live default `Library.trashMeeting`.
In `deleteMeeting(_:)`, serialize against folder/runtime transitions, protect the active recording, prepare notes, cancel queued/running jobs, move the meeting, complete the note removal, clear review state, publish an explicit process-lifetime removal marker and immediate list removal, remove job records, and reload meetings.
Map `PipelineError.cancellationTooLate` to a user-facing retry error.
Return a cleanup warning only when the meeting moved successfully but job-record cleanup failed.

- [ ] **Step 4: Run the focused AppModel tests and verify GREEN**

Run the command from Step 2 again.
Expected: PASS without warnings introduced by the change.

### Task 3: Present durable pipeline activity

**Files:**
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Test: `iOS/App/Tests/MeetingPresentationTests.swift`

**Interfaces:**
- Consumes: `[Job]` returned by `AppModel.meetingJobs(for:)`
- Produces: `MeetingJobPresentation.make(_:)` and a compact job-status banner

- [ ] **Step 1: Write the failing presentation matrix**

Use literal expectations for queued and running `finalASR`, `diarization`, and `identitySuggestion` jobs.
Assert that finished, failed, cancelled, report, and export jobs do not create the active pipeline banner.
Assert that a running job wins over a queued job.

- [ ] **Step 2: Run the focused presentation tests and verify RED**

Run:

```bash
cd iOS
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  -only-testing:StenoTests/MeetingPresentationTests test
```

Expected: compilation fails because `MeetingJobPresentation` does not exist.

- [ ] **Step 3: Implement presentation and observation**

Add the pure presentation type and render it above the detail list with `ProgressView`.
Poll `meetingJobs(for:)` in the existing one-second observation loop, update the banner from persisted status, and call `load(_:)` only when job or diarization state changed.
Hide the old diarization presentation while an active pipeline job is shown.

- [ ] **Step 4: Run the focused presentation tests and verify GREEN**

Run the command from Step 2 again.
Expected: PASS.

### Task 4: Expose actions in detail and sidebar

**Files:**
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Sources/MeetingSidebarView.swift`
- Test: `iOS/App/Tests/MeetingPresentationTests.swift`

**Interfaces:**
- Consumes: `requestRetranscription(meetingID:)`, `deleteMeeting(_:)`, and `NavigationRouter`
- Produces: visible `Meeting actions` menu, matching context-menu shortcuts, confirmations, and route-away behavior

- [ ] **Step 1: Write failing action-policy tests**

Add literal policy tests proving that recording meetings disable retranscription and deletion and that a loaded detail leaves its route after the meeting disappears.

- [ ] **Step 2: Run the focused tests and verify RED**

Run the focused `MeetingPresentationTests` command from Task 3.
Expected: FAIL because the action and route policies do not exist.

- [ ] **Step 3: Implement the visible action flows**

Add an ellipsis toolbar menu to `MeetingDetailView` and add `Move to Trash...` to the sidebar context menu.
Reuse the approved confirmation copy in both surfaces.
After sidebar retranscription, select the meeting so the job banner is visible.
After deletion, route the current detail to `.recording` only if it is still selected; other open detail views do the same when the explicit process-lifetime removal marker contains their meeting ID.
Show request, deletion, and cleanup errors in local alerts.

- [ ] **Step 4: Run focused iOS tests and verify GREEN**

Run the focused presentation and deletion tests.
Expected: PASS.

### Task 5: Review, full verification, and device acceptance

**Files:**
- Verify all files changed above

**Interfaces:**
- Consumes: completed Tasks 1 through 4
- Produces: reviewed local commit and installed device builds

- [ ] **Step 1: Inspect the diff and obtain an independent review**

Review specifically for recording deletion, autosave resurrection, cancellation-too-late, stale multi-window routes, and truthful job status.

- [ ] **Step 2: Run all four suites**

Run the exact commands from `AGENTS.md`:

```bash
swift test --package-path StenoKit
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' test
cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData test
cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: all suites PASS.

- [ ] **Step 3: Commit only task-owned files**

Create a local commit without a co-author.
Do not push or merge.

- [ ] **Step 4: Install and inspect both devices**

Install with `scripts/build-ios.sh --device` on the target iPhone and iPad.
Verify the toolbar menu, both confirmations, queued/running banner, route after deletion, and the Files-app Trash behavior without deleting a real recording.
