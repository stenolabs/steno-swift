# iOS Discoverability and Accessibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing iPhone and iPad workflows visibly reachable, place retranscription confirmation where the person acted, and make recording, permissions, progress, and dense layouts truthful and accessible.

**Architecture:** Preserve the single adaptive `NavigationSplitView` and route every new visible control through the same AppModel methods and presentation policies already used by commands and context menus.
Keep accessibility semantics in pure presenters, derive progress only from real callbacks, and use native controls and adaptive layouts instead of a parallel mobile UI tree.

**Tech Stack:** Swift 6, SwiftUI, Observation, AVFoundation, UIKit settings URL, Swift Testing, XcodeGen

**Spec:** `docs/superpowers/specs/2026-08-23-cross-platform-ui-modernisierung-und-demo-design.md`

## Global Constraints

- The existing `NavigationSplitView`, `NavigationRouter`, and `SidebarItem` remain the only iPhone/iPad navigation hierarchy.
- Visible menus and context menus call the same mutation methods and policy types.
- Retranscription state comes from persisted jobs, never an optimistic local percentage or phase.
- Model readiness comes from the installation coordinator after verification, never file existence.
- Level values are stable accessibility categories and never live announcements.
- Permission refresh never reconfigures an active recording session.
- New pure presentation types return `LocalizedStringResource` for user-visible text from their first implementation.
- No dependency changes, remote push, merge, or publication.

---

### Task 1: Expose the primary meeting, inspector, folder, and move actions

**Files:**
- Modify: `iOS/App/Sources/StenoCommands.swift`
- Modify: `iOS/App/Sources/ContentView.swift`
- Modify: `iOS/App/Sources/MeetingSidebarView.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Sources/NavigationRouter.swift`
- Create: `iOS/App/Sources/IOSMeetingActions.swift`
- Modify: `iOS/App/Tests/NavigationRouterTests.swift`
- Modify: `iOS/App/Tests/StenoCommandStateTests.swift`
- Modify: `iOS/App/Tests/IOSMeetingSidebarPresentationTests.swift`

**Interfaces:**
- Consumes: `StenoCommandActions.createDraft(in:)`, `IOSMeetingSidebarPresentation`, `AppModel.moveMeeting(_:to:)`, and the existing folder action methods.
- Produces: `NavigationRouter.toggleInspector()` and one shared `IOSMeetingMoveActions` menu body.

- [ ] **Step 1: Write failing routing and policy tests**

Require inspector toggling to affect only the focused router.
Require visible and context-menu move actions to expose identical destinations and enabled states.
Retain the existing test that `New Meeting` captures its window-local router before the first suspension.

- [ ] **Step 2: Regenerate and verify RED**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData -only-testing:StenoTests/NavigationRouterTests -only-testing:StenoTests/StenoCommandStateTests -only-testing:StenoTests/IOSMeetingSidebarPresentationTests test
```

Expected: compilation or assertions fail because the shared visible-action types do not exist.

- [ ] **Step 3: Add one reusable action boundary**

Add `StenoCommandActions.init(model:)` so the visible New Meeting button and `Cmd-N` use the same implementation.
Add `NavigationRouter.toggleInspector()`.
Implement `IOSMeetingMoveActions` from the existing meeting action policy and folder destinations, with `move(FolderID?)` as its only mutation closure.

- [ ] **Step 4: Add visible controls without removing shortcuts**

Add a visible New Meeting button to the sidebar.
Add a visible ellipsis `Menu` to every folder row using the same contents as its context menu.
Add `Move to Folder` to the existing meeting toolbar menu and reuse `IOSMeetingMoveActions` in both surfaces.
Add a visible Show/Hide Inspector toolbar button with identifier `meeting-inspector-toggle`, label, and hint.

- [ ] **Step 5: Rerun and verify GREEN**

Run the command from Step 2.
Expected: all three focused suites pass.

### Task 2: Replace positional retranscription dialogs with centered alerts

**Files:**
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Sources/MeetingSidebarView.swift`
- Modify: `iOS/App/Tests/MeetingPresentationTests.swift`
- Modify: `iOS/App/Tests/AppModelRetranscriptionTests.swift`

**Interfaces:**
- Consumes: `AppModel.requestRetranscription(meetingID:)` and persisted `MeetingJobPresentation`.
- Produces: the same `.alert(..., presenting:)` confirmation in detail and sidebar.

- [ ] **Step 1: Update the copy test first**

Require this complete consequence statement:

```text
Steno adds a new transcript revision and keeps the current transcript and corrections as earlier revisions.
Speaker separation runs again with new cluster identifiers, so speakers must be confirmed again.
Your corrections are never silently overwritten.
```

Require the existing queued-job tests to keep proving `.finalASR/.queued` and `Transcription queued` immediately after the request.

- [ ] **Step 2: Run and verify RED**

Run the focused `MeetingPresentationTests` and `AppModelRetranscriptionTests` through the common iOS xcodebuild command.
Expected: the copy expectation fails against the current shorter text.

- [ ] **Step 3: Use alerts on both action surfaces**

Replace both retranscription `.confirmationDialog` modifiers with `.alert(..., presenting:)`.
Keep Cancel and Transcribe Again actions, but invoke only `requestRetranscription` after confirmation.
From the sidebar, select the meeting after queueing so the durable job banner is immediately visible.
Do not add an in-memory pseudo-progress state.

- [ ] **Step 4: Rerun and verify GREEN**

Run both focused suites.
Expected: alert copy, persisted job, duplicate-job guard, and immediate presentation tests pass.

### Task 3: Make recording and transcript layouts adapt through Accessibility 5

**Files:**
- Modify: `iOS/App/Sources/RecordingView.swift`
- Modify: `iOS/App/Sources/RecordingStrip.swift`
- Modify: `iOS/App/Sources/LevelMeter.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Create: `iOS/App/Sources/IOSAccessibilityPresentation.swift`
- Create: `iOS/App/Tests/RecordingAccessibilityTests.swift`
- Create: `iOS/App/Tests/IOSAccessibilityLayoutTests.swift`

**Interfaces:**
- Produces: `IOSAdaptiveStackAxis.axis(for:)` and `RecordingAccessibilityPresentation`.
- Consumes: `DynamicTypeSize`, elapsed recording time, `AudioLevel`, and `SilenceMonitor.defaultThreshold`.

- [ ] **Step 1: Write the pure semantics matrix**

Require spoken duration `0 -> "0 seconds"` and `3665 -> "1 hour, 1 minute, 5 seconds"` in the fixed English test locale.
Require microphone values `idle`, `silent`, `low`, `normal`, `high`, and `clipping`, with clipping taking precedence.
Require `.accessibility1` through `.accessibility5` to choose the vertical layout and ordinary sizes to choose horizontal.

- [ ] **Step 2: Add failing hosting layout tests**

Host the recording strip and a transcript row at standard and `.accessibility5` sizes.
Require AX5 to use the vertical arrangement, preserve all controls, and avoid the current fixed 52-point timestamp width.

- [ ] **Step 3: Run and verify RED**

Run `RecordingAccessibilityTests` and `IOSAccessibilityLayoutTests`.
Expected: missing presenters and current fixed layout fail.

- [ ] **Step 4: Implement semantic text and stable VoiceOver values**

Change the large recording timer to `.system(.largeTitle, design: .rounded, weight: .semibold)` with `monospacedDigit()`.
Combine it as one accessibility element with label `Recording time` and the fully spoken duration value.
Combine `LevelMeter` as one element with label `Microphone level` and only the stable category value.
Do not add `accessibilityLiveRegion` or notifications for meter changes.

- [ ] **Step 5: Implement adaptive layouts and actionable semantics**

Use `AnyLayout`, `ViewThatFits`, or equivalent policy-driven stacks for RecordingStrip, transcript row, dense job status, and model-progress rows.
Move timestamps above speaker/text at accessibility sizes and remove the rigid width.
Give Record, Stop, Back, and Inspector controls stable labels, hints, and identifiers while retaining native Buttons.

- [ ] **Step 6: Rerun and verify GREEN**

Run both focused suites.
Expected: semantic matrices and both hosted sizes pass.

### Task 4: Add a recoverable denied-microphone path

**Files:**
- Modify: `iOS/App/Sources/RecordingModel.swift`
- Modify: `iOS/App/Sources/RecordingView.swift`
- Modify: `iOS/App/Sources/AudioReadinessView.swift`
- Create: `iOS/App/Sources/MicrophonePermissionPresentation.swift`
- Create: `iOS/App/Tests/MicrophonePermissionPresentationTests.swift`
- Modify: `iOS/App/Tests/AudioReadinessPresentationTests.swift`

**Interfaces:**
- Produces: `MicrophonePermissionAction`, `MicrophonePermissionPresentation.settingsURL`, and explicit permission refresh methods.
- Uses: `UIApplication.openSettingsURLString`, SwiftUI `openURL`, and scene-phase activation.

- [ ] **Step 1: Write the permission policy tests**

Require `.notDetermined -> .request`, `.denied -> .openSettings`, and `.authorized -> nil`.
Require the settings URL to equal the system app-settings URL.
Retain the existing lifecycle contract that active recording prevents readiness reconfiguration.

- [ ] **Step 2: Run and verify RED**

Run the two focused permission suites.
Expected: the new presenter and refresh APIs are missing.

- [ ] **Step 3: Add explicit refresh without session mutation**

Publish current microphone permission from `RecordingModel` and add `refreshMicrophonePermission()`.
Add the corresponding read-only refresh to the Audio Readiness model.
Refresh both on transition back to active scene, but return immediately when recording is active before any audio-session configuration.

- [ ] **Step 4: Add the visible recovery action**

In `.denied`, explain that recording is blocked until access is restored in Settings.
Show `Open Settings` in Audio Readiness and in the recording-start failure surface.
Use the same presentation policy and URL in both places.

- [ ] **Step 5: Rerun and verify GREEN**

Run both focused suites.
Expected: policy, foreground refresh, and active-recording guard pass.

### Task 5: Make Speech, diarization, and Parakeet installation cancellable and truthful

**Files:**
- Modify: `iOS/App/Sources/IOSModelInstallationState.swift`
- Modify: `iOS/App/Sources/AudioReadinessView.swift`
- Modify: `iOS/App/Sources/TranscriptionModelSettingsView.swift`
- Create: `iOS/App/Sources/IOSModelInstallationProgressView.swift`
- Modify: `iOS/App/Tests/IOSModelInstallationStateTests.swift`
- Modify: `iOS/App/Tests/TranscriptionModelSettingsLayoutTests.swift`

**Interfaces:**
- Produces: `IOSModelInstallProgressPresentation`, `IOSModelInstallationState.isCancelling`, one retained installation `Task`, and async idempotent `cancelInstall()`.
- Uses: the existing coordinator consent, progress callback, cancellation, and readiness APIs.

- [ ] **Step 1: Write the progress and cancellation RED matrix**

Require `Preparing` to be indeterminate before the first real callback.
Require a real callback to switch to clamped determinate progress.
Require the first cancel to enter Cancelling, a second cancel to return false, and consent to remain granted.
Require incomplete or unverified files to remain not ready after cancellation.
Use an installer double whose `cancelInstall` returns before the running install task exits, then require Cancelling to remain visible and readiness not to refresh until that task has actually completed.

- [ ] **Step 2: Run and verify RED**

Run `IOSModelInstallationStateTests` and `TranscriptionModelSettingsLayoutTests`.
Expected: current fabricated zero progress and missing cancelling state fail.

- [ ] **Step 3: Implement honest installation state**

Leave `progress` nil until the coordinator publishes a callback.
Derive `.indeterminate(title: "Preparing")` while installing with no callback, then `.determinate` from validated progress.
Retain the exact `Task<Bool, Never>` that owns the active coordinator install and clear it only by identity in its completion path.
Make `cancelInstall()` await `cancelAll()`, then await that retained installation task before refreshing coordinator readiness and leaving Cancelling.
Suppress duplicate cancellation and preserve consent throughout.

- [ ] **Step 4: Reuse one adaptive progress view on all model surfaces**

Show a visible Cancel button for Speech, diarization, and Parakeet.
Show Cancelling while cancellation is in flight and disable repeated actions.
Stack title, progress, and action vertically at accessibility sizes.
Do not mark anything installed until the coordinator reports verified readiness.

- [ ] **Step 5: Rerun and verify GREEN**

Run both focused suites.
Expected: all state and layout cases pass, including consent retention.

### Task 6: Present unknown meeting-import progress as indeterminate

**Files:**
- Create: `StenoKit/Sources/StenoExchange/MeetingTransferProgressPresentation.swift`
- Create: `StenoKit/Tests/StenoExchangeTests/MeetingTransferProgressPresentationTests.swift`
- Modify: `iOS/App/Sources/MeetingTransferImportSheet.swift`
- Modify: `iOS/App/Tests/MeetingTransferImportPresentationTests.swift`

**Interfaces:**
- Produces: `MeetingTransferProgressPresentation.make(_:)` with `.indeterminate` and `.determinate(Double)`.

- [ ] **Step 1: Write the shared progress policy tests**

Require nil progress, zero total bytes, and negative total bytes to be indeterminate.
Require only a positive total to be determinate and clamp the quotient to `0...1`.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter MeetingTransferProgressPresentationTests
```

Expected: the shared type does not exist.

- [ ] **Step 3: Implement the pure shared classifier**

Add the presentation type to StenoExchange with no SwiftUI dependency.
Return determinate progress only for `totalBytes > 0` and clamp completed bytes before division.

- [ ] **Step 4: Render the correct native ProgressView**

Use `ProgressView()` for `.indeterminate` and `ProgressView(value:)` only for `.determinate`.
Remove the fallback that invents zero percent.

- [ ] **Step 5: Rerun and verify GREEN**

Run the shared StenoExchange filter and the iOS `MeetingTransferImportPresentationTests` suite.
Expected: every total-size and clamping case passes in the shared policy and iOS rendering.

### Task 7: Focused review and iPhone/iPad form-factor acceptance

**Files:**
- Verify all files changed above.

**Interfaces:**
- Consumes: completed Tasks 1 through 6.
- Produces: review findings and device observations for the final QA record.

- [ ] **Step 1: Request independent review**

Review router locality, duplicate action implementations, retranscription persistence, permission/session races, cancellation completion races, VoiceOver noise, and AX5 overflow.
Resolve Critical and Important findings and request one targeted re-review.

- [ ] **Step 2: Run the consolidated iOS app suite**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData test
```

Expected: the complete iOS app suite passes.

- [ ] **Step 3: Inspect both form factors**

On iPhone and iPad simulator form factors, use simulated touch, VoiceOver, `.accessibility5`, pointer, and Full Keyboard Access to inspect New Meeting, folder ellipses, Move to Folder, inspector, centered retranscription alert, recording duration, meter category, Open Settings, Cancel/Cancelling, and unknown import progress.
Repeat the hardware-dependent subset on an explicitly authorized selected device when available.
Record alert placement and spoken ordering as measured only on the surface actually inspected.
