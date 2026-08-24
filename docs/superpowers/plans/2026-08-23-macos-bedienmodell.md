# macOS Operating Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac app an honest single-window application with contextual menus, conflict-free shortcuts, native sidebar search, a customizable toolbar, deferred permissions, correctly placed status, keyboard-visible transcript correction, and native small presentation fixes.

**Architecture:** Replace the multiwindow-capable main `WindowGroup` with one `Window` while keeping purpose-specific scenes.
Move commands into a dedicated type and publish current meeting, folder, detail, and transcript-line actions through focused values so menu items reuse existing mutations.
Keep UI availability in pure policies, retain store validation as the final authority, and layer this work on the typed recovery states from the preceding recovery plan.

**Tech Stack:** Swift 6, SwiftUI, AppKit command conventions, FocusedValues, Observation, XcodeGen, Swift Testing

**Spec:** `docs/superpowers/specs/2026-08-23-cross-platform-ui-modernisierung-und-demo-design.md`

## Global Constraints

- The main app has one primary window; onboarding, legacy import, and Settings remain separate purpose-specific scenes.
- Commands and context menus capture exact IDs synchronously before starting asynchronous work.
- UI disablement never replaces validation in AppModel or StenoKit.
- Plain `Cmd-M` and plain `Cmd-I` remain system-reserved.
- Bootstrap and note-recovery types from the recovery plan are reused, not replaced.
- Every runtime check uses explicit isolated `STENO_LIBRARY_DIR` and `STENO_MODEL_DIR` paths.
- New pure presentation types return `LocalizedStringResource` for user-visible text from their first implementation.
- No dependency changes, remote push, merge, or publication.

---

### Task 1: Define one main window and a testable shortcut contract

**Files:**
- Create: `App/Sources/StenoCommands.swift`
- Modify: `App/Sources/StenoApp.swift`
- Create: `App/Tests/StenoCommandTests.swift`

**Interfaces:**
- Produces: `StenoCommandID`, `StenoCommandShortcut`, `StenoCommandShortcuts`, `StenoCommandState`, and `StenoCommands`.
- Consumes: existing AppModel recording, draft, import, and setup actions.

- [ ] **Step 1: Write the shortcut and availability RED matrix**

Require every app command shortcut to be unique.
Require no entry for plain `Cmd-M` or plain `Cmd-I`.
Require exactly one `Cmd-N` owner.
Require Start, Stop, New Meeting, and Import availability to follow runtime, recording, and recording-start state.

- [ ] **Step 2: Regenerate and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -derivedDataPath .build/ui-modernization/DerivedData-mac -only-testing:StenoTests/StenoCommandTests test
```

Expected: compilation fails because the command contract does not exist.

- [ ] **Step 3: Add the fixed shortcut table**

Use `Cmd-R` Start Recording, `Cmd-.` Stop Recording, `Shift-Cmd-M` Mark This Moment, `Cmd-N` New Meeting, `Shift-Cmd-I` Import Audio, `Option-Cmd-I` Import Meeting Package, `Cmd-F` Find in Transcript, `Control-Cmd-I` Inspector, and `Cmd-Delete` Move to Trash.
Keep legacy import and setup discoverable in menus without taking a standard shortcut.

- [ ] **Step 4: Replace the main WindowGroup and inline commands**

Use `Window("Meetings", id: "main")` for ContentView.
Keep the existing default size and separate onboarding, legacy import, and Settings scenes.
Move inline commands into `StenoCommands` and replace the `.newItem` group rather than appending a second New action.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite.
Expected: shortcut uniqueness, reservations, and availability pass.

### Task 2: Read permissions at launch and request them only after explanation

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/StenoApp.swift`
- Modify: `App/Sources/OnboardingView.swift`
- Modify: `App/Tests/OnboardingPermissionPresentationTests.swift`

**Interfaces:**
- Produces: injectable `MacRecordingPermissionClient`, `refreshRecordingPermissionStatus()`, and explicit `requestRecordingPermissions(forceSystemAudioProbe:)`.
- Consumes: `AudioPermissions.microphoneStatus`, existing cached system-audio status, and explicit request APIs.

- [ ] **Step 1: Write a no-prompt launch test**

Inject counters for status reads, microphone requests, and system-audio probes.
Call the launch-status method and require one read, zero microphone requests, and zero system-audio probes.
Call the explicit onboarding action and require the request/probe path.

- [ ] **Step 2: Run and verify RED**

Run `OnboardingPermissionPresentationTests`.
Expected: current `resolveRecordingPermissions` combines reads and requests and cannot satisfy the contract.

- [ ] **Step 3: Split status read from explicit request**

At launch, read `AudioPermissions.microphoneStatus()` and a reusable code-identity-bound system-audio cache, defaulting unknown system status to `.notDetermined`.
Do not call `requestAccess`, prepare a process tap, or start an audio source.
Keep the explicit onboarding button and first recording attempt as the only request paths.

- [ ] **Step 4: Update app launch and onboarding wiring**

Replace the startup call with `refreshRecordingPermissionStatus()` before bootstrap.
Rename the onboarding action to the explicit request API and preserve the forced recheck button.
Keep active-recording and starting-recording guards.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite.
Expected: launch reads status only and explicit user action performs the request.

### Task 3: Publish focused contexts and complete native menus

**Files:**
- Create: `App/Sources/StenoFocusedCommands.swift`
- Modify: `App/Sources/StenoCommands.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarState.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `App/Sources/MeetingDetailView.swift`
- Modify: `App/Tests/MeetingSidebarStateTests.swift`
- Modify: `App/Tests/StenoCommandTests.swift`

**Interfaces:**
- Produces: `MacMeetingCommandAvailability`, `MacMeetingCommandContext`, `MacFolderCommandContext`, and `MacMeetingDetailCommandContext` in `FocusedValues`.
- Consumes: existing AppModel rename, move, retranscribe, export, share, import, and trash methods.

- [ ] **Step 1: Write the contextual availability tests**

Require one ready meeting with audio to expose all single-meeting actions.
Require multiple selection to expose only operations that are genuinely implemented for multiple meetings.
Require recording state and absent audio to disable affected actions.
Require focused folder context to override a stale meeting selection.

- [ ] **Step 2: Add the async target-capture test**

Capture a meeting or folder context, change focus, then execute the already-created async closure.
Require it to act on the original captured ID, never the new focus.

- [ ] **Step 3: Run and verify RED**

Run `StenoCommandTests` and `MeetingSidebarStateTests`.
Expected: focused context types and menu policies do not exist.

- [ ] **Step 4: Publish focused values from the owning views**

Publish meeting selection from the sidebar, folder commands only from the focused folder row, and Find/Inspector/Share from meeting detail.
Make folder rows keyboard focusable.
Capture IDs and destinations before creating Tasks.

- [ ] **Step 5: Build the complete menu surface**

Add Recording, Audio/Package/Legacy Import, Markdown/Audio Export, Share, Inspector, Find in Transcript, Rename, Move to Folder, Transcribe Again, Trash, and valid folder actions.
Have menu and context-menu entries call the same helper closures.

- [ ] **Step 6: Rerun and verify GREEN**

Run both focused suites.
Expected: availability, focus precedence, and target capture pass.

### Task 4: Adopt native sidebar search and a stable customizable toolbar

**Files:**
- Create: `App/Sources/MacToolbarPresentation.swift`
- Create: `App/Tests/MacToolbarPresentationTests.swift`
- Modify: `App/Sources/ContentView.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `App/Sources/MeetingDetailView.swift`
- Modify: `App/Sources/RecordingView.swift`

**Interfaces:**
- Produces: stable `MacToolbarID` and `MacToolbarItemID` values plus default-visibility policy.
- Preserves: `MeetingSearch.matching` and the current temporary disclosure behavior.

- [ ] **Step 1: Write the toolbar policy RED tests**

Require all semantic toolbar IDs to be unique.
Require one Import menu item, no Settings item, and visible defaults for recording, New Meeting, import, and inspector where context allows.

- [ ] **Step 2: Run and verify RED**

Run `MacToolbarPresentationTests`.
Expected: the ID and default policy types do not exist.

- [ ] **Step 3: Replace the custom sidebar field with native search**

Remove the hand-built sidebar TextField and apply `.searchable(text:placement:.sidebar,prompt:)` to the sidebar.
Keep transcript search as the separate contextual Cmd-F surface and do not add a second `.searchable` to the same split view.

- [ ] **Step 4: Consolidate and identify toolbar items**

Use `.toolbar(id:)` and stable `ToolbarItem(id:showsByDefault:)` values.
Combine Audio, Package, and Legacy imports into one menu.
Remove the Settings gear while retaining the native Settings scene and `Cmd-,`.
Remove local duplicate Cmd-F shortcuts so the Commands type is the only shortcut owner.

- [ ] **Step 5: Rerun and verify GREEN**

Run the toolbar and sidebar state suites.
Expected: IDs, defaults, one import surface, and native search state pass.

### Task 5: Place global and meeting status where it belongs and respect Reduce Motion

**Files:**
- Create: `App/Sources/MacStatusPresentation.swift`
- Create: `App/Tests/MacStatusPresentationTests.swift`
- Modify: `App/Sources/ContentView.swift`
- Modify: `App/Sources/MeetingDetailView.swift`

**Interfaces:**
- Produces: `MacGlobalStatusSurface` and `MeetingPipelineStatusPresentation`.
- Builds on: typed bootstrap failure presentation from the recovery plan.

- [ ] **Step 1: Write status placement and supersession tests**

Require errors to use the top surface and noncritical confirmations/export activity to use the bottom surface.
Require a later successful job of the same pipeline kind to suppress an older failure.
Require template and export jobs not to appear as transcription status.

- [ ] **Step 2: Run and verify RED**

Run `MacStatusPresentationTests`.
Expected: current bottom insets do not satisfy the policy.

- [ ] **Step 3: Move status to contextual surfaces**

Render critical AppModel notices and persistent startup failure at the top of the main content.
Render meeting pipeline failures and recovery actions inside the meeting's existing top status stack.
Keep noncritical confirmations and audio export activity in a lower status surface.
Avoid double-rendering legacy upgrade status.

- [ ] **Step 4: Respect Reduce Motion**

Read `accessibilityReduceMotion` and use opacity-only or no animation for status changes when enabled.
Keep the existing combined transition only when motion is allowed.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite.
Expected: placement, job supersession, and motion policy pass.

### Task 6: Make Correct Line visible to keyboard focus and menus

**Files:**
- Modify: `App/Sources/StenoFocusedCommands.swift`
- Modify: `App/Sources/StenoCommands.swift`
- Modify: `App/Sources/MeetingDetailView.swift`
- Create: `App/Tests/TranscriptCorrectionPresentationTests.swift`

**Interfaces:**
- Produces: `TranscriptCorrectionPresentation.showsAction` and `MacTranscriptLineCommandContext`.
- Consumes: the existing append-only macOS transcript editing path.

- [ ] **Step 1: Write the visibility and context RED matrix**

Require the pencil to show on hover or row focus, hide while editing, and expose Correct Line only for the focused row.
Require pencil, context menu, and Edit menu to call the same `beginCorrection()` action.

- [ ] **Step 2: Run and verify RED**

Run `TranscriptCorrectionPresentationTests` and the command suite.
Expected: current hover-only opacity and missing focused context fail.

- [ ] **Step 3: Add row/editor focus and shared start logic**

Make nonediting transcript rows focusable.
Use separate row and editor FocusState values.
Have `beginCorrection()` initialize the draft, enter edit mode, then focus the editor.
Clear line context when filtering, revision changes, cancellation, or row disappearance ends editing.

- [ ] **Step 4: Add Edit-menu and context-menu access**

Publish Correct Line through focused values and add the same action to the row context menu.
Retain Escape, Cancel, and Cmd-Return behavior.

- [ ] **Step 5: Rerun and verify GREEN**

Run both focused suites.
Expected: hover, keyboard focus, edit state, and common action tests pass.

### Task 7: Apply small native corrections without changing domain behavior

**Files:**
- Modify: `App/Sources/MeetingTransferExportView.swift`
- Modify: `App/Tests/MeetingTransferExportPresentationTests.swift`
- Modify: `App/Sources/ContentView.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarState.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `App/Tests/MeetingSidebarStateTests.swift`
- Modify: `App/Tests/WindowLayoutTests.swift`

**Interfaces:**
- Produces: `SidebarNameValidation` and the tested share symbol constant.

- [ ] **Step 1: Write validation, title, and symbol RED tests**

Require whitespace-only names to be invalid, same-parent case-insensitive folder duplicates to be rejected, and rename to the same folder's current name to remain valid.
Require share action symbol `square.and.arrow.up` and empty/main titles `Meetings`.

- [ ] **Step 2: Run and verify RED**

Run sidebar, export presentation, and window layout tests.
Expected: current permissive dialogs, AirPlay share icon, and Steno titles fail.

- [ ] **Step 3: Apply presentation fixes**

Use `square.and.arrow.up` for sharing, while retaining AirDrop-specific provenance imagery only where it actually means AirDrop.
Use `Meetings` for sidebar and empty/multiple-selection titles.
Disable Create/Rename for normalized empty values and show duplicate validation inside the open dialog.
Keep the store as the final race-safe validator.

- [ ] **Step 4: Rerun and verify GREEN**

Run all three focused suites.
Expected: validation, symbol, and title tests pass.

### Task 8: Independent review and isolated macOS acceptance

**Files:**
- Verify all files changed above.

**Interfaces:**
- Consumes: completed Tasks 1 through 7 and the recovery plan.
- Produces: review findings and measured Mac interaction results for final QA.

- [ ] **Step 1: Request independent review**

Review focused-value lifetime, async target capture, command conflicts, store validation, permission prompts, single-window reopen behavior, status supersession, toolbar IDs, and transcript-row focus cleanup.
Resolve Critical and Important findings and request one targeted re-review.

- [ ] **Step 2: Build and run the macOS app suite**

Run:

```bash
xcodegen generate
scripts/build-app.sh
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' test
```

Expected: build and full macOS app suite pass.

- [ ] **Step 3: Perform isolated interactive acceptance**

Launch with fresh explicit temporary library and model paths.
Confirm one main window, Dock reopen, Cmd-N, system Cmd-M, new marker/import shortcuts, contextual menus, native search, toolbar customization, no startup TCC prompt, explicit onboarding prompt, top errors, meeting pipeline status, Reduce Motion, keyboard Correct Line, valid titles, and in-dialog name validation.
Record runtime effects as measured only after this check.
