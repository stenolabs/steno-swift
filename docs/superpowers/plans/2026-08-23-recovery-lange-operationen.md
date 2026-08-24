# Recovery and Long Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give both apps typed startup recovery, reliable meeting revision refresh, recoverable notes, cancellable atomic legacy import, confirmed endpoint deletion, honest shared progress, consent-preserving Mac model cancellation, and a clear first report-share disclosure.

**Architecture:** Separate fatal runtime opening from recoverable list/folder warnings so Retry invokes the operation that actually failed.
Keep one shared progress classification in StenoExchange.
Add cancellation checks only outside existing atomic import commits and return an explicit partial outcome.
Keep destructive endpoint writes in their existing transactional stores, but place a confirmation boundary before them.
Preserve model consent while cancellation is requested and refresh verified readiness after the race settles.

**Tech Stack:** Swift 6, SwiftUI, Observation, StenoLibrary, StenoExchange, StenoPipeline, Swift Testing, XcodeGen

**Spec:** `docs/superpowers/specs/2026-08-23-cross-platform-ui-modernisierung-und-demo-design.md`

## Global Constraints

- Startup Retry never deletes or recreates a library.
- Recoverable folder, list, capture, and model warnings never disable recording after the runtime opened successfully.
- A visible failure is cleared only while its actual retry is in flight or after that retry succeeds.
- Unknown progress is never converted to zero percent.
- Cancellation is observed only before preparation, after preparation, and between complete atomic commits.
- Already committed meetings remain after cancellation and are deduplicated on rerun.
- Endpoint deletion still uses the existing journaled registry/keychain transaction.
- Model cancellation preserves consent and never declares partial bytes installed.
- New pure presentation types return `LocalizedStringResource` for user-visible text from their first implementation.
- No dependency changes, remote push, merge, or publication.

---

### Task 1: Apply the shared meeting-transfer progress classifier on macOS

**Files:**
- Verify: `StenoKit/Sources/StenoExchange/MeetingTransferProgressPresentation.swift`
- Verify: `StenoKit/Tests/StenoExchangeTests/MeetingTransferProgressPresentationTests.swift`
- Modify: `App/Sources/MeetingTransferImportView.swift`
- Modify: `App/Tests/MeetingTransferImportPresentationTests.swift`

**Interfaces:**
- Produces: `MeetingTransferProgressPresentation.indeterminate` and `.determinate(Double)`.
- Consumes: `MeetingTransferProgress?`.

- [ ] **Step 1: Extend the Mac presentation tests before changing the view**

Require nil progress, zero total bytes, and negative total bytes to be indeterminate.
Require positive totals to produce a quotient clamped to `0...1`.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter MeetingTransferProgressPresentationTests
```

Expected: the shared policy passes from the preceding iOS plan, while the Mac view-level expectation fails because it still maps unknown totals to zero.

- [ ] **Step 3: Render native Mac progress from the shared policy**

Use `ProgressView()` for indeterminate and `ProgressView(value:)` for determinate in the macOS import view.
Delete the Mac-local helper that maps unknown totals to zero.

- [ ] **Step 4: Run both focused suites**

Run the StenoExchange test plus the macOS import-presentation suite.
Expected: every unknown/known-size case passes in the shared policy and Mac rendering.

### Task 2: Give iOS a fatal startup state and targeted library retry

**Files:**
- Modify: `iOS/App/Sources/AppModel.swift`
- Create: `iOS/App/Sources/IOSStartupPresentation.swift`
- Modify: `iOS/App/Sources/ContentView.swift`
- Modify: `iOS/App/Sources/MeetingSidebarView.swift`
- Modify: `iOS/App/Sources/RecordingView.swift`
- Modify: `iOS/App/Tests/LibraryBackupPolicyTests.swift`
- Modify: `iOS/App/Tests/PipelineStartupWarningPresentationTests.swift`

**Interfaces:**
- Produces: `IOSStartupState`, `IOSStartupFailure`, `IOSLibraryIssue`, `IOSActionNotice`, `retryStartup()`, and `retryLibraryIssue()`.
- Preserves: the existing coalesced bootstrap task and runtime generation barriers.

- [ ] **Step 1: Write the startup state transition tests**

With the existing injectable iOS pipeline starter, require initial Opening, successful Ready, fatal open failure, Retry back to Opening, and eventual Ready.
Require overlapping retry calls to join one bootstrap attempt.
Require a fatal message to remain until the replacement attempt actually starts.

- [ ] **Step 2: Write targeted issue tests**

Inject meeting-list and folder-list failures after runtime creation.
Require runtime and recording readiness to remain available.
Require retry of a meeting issue to reload meetings without trying to start a second runtime.
Require retry of a folder issue to reopen/reload only folders.
Exercise every current `startupFailure` writer and require this complete mapping: runtime open to fatal startup; meeting/folder availability to targeted library issue; capture recovery, missing-model requeue, and pipeline startup to nonfatal warning; Apple retry, draft creation, folder mutation, folder-state reload, and partial recovery to action notice.
Require clearing one category never to erase an unrelated visible category.

- [ ] **Step 3: Run and verify RED**

Run `LibraryBackupPolicyTests` and `PipelineStartupWarningPresentationTests`.
Expected: the current `startupFailure: String?` cannot distinguish fatal and recoverable stages.

- [ ] **Step 4: Split fatal startup from recoverable issues**

Use `IOSStartupState.opening`, `.ready`, and `.failed(IOSStartupFailure)` only for runtime opening.
Represent meeting and folder failures as `IOSLibraryIssue` with a typed retry action.
Keep capture recovery, missing-model requeue, and pipeline warnings as nonfatal warnings after Ready.
Move Apple retry queue failures, draft failures, folder mutation failures, folder-state reload messages, and partial recovery messages into `IOSActionNotice` rather than startup state.
Remove the old shared `startupFailure` writer only after an exhaustive source-tree search proves every assignment has moved to one of these categories.
Retain `isReady` only as a compatibility projection if existing call sites need it.

- [ ] **Step 5: Present Opening and Failed in the primary detail surface**

Show a ProgressView and explanation while Opening.
Show persistent `ContentUnavailableView` with Try Again while Failed.
Show recoverable library issues as visible banners with their targeted retry, including in compact width where the sidebar may be hidden.

- [ ] **Step 6: Rerun and verify GREEN**

Run both focused suites.
Expected: fatal, recoverable, coalesced, and recording-ready cases pass.

### Task 3: Refresh iOS transcript revisions on every relevant observation transition

**Files:**
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Tests/MeetingPresentationTests.swift`

**Interfaces:**
- Produces: `MeetingContentObservation` containing diarization state, current revision ID, and active job fingerprint.
- Consumes: status before revision from `MeetingDiarizationSnapshot.load`.

- [ ] **Step 1: Write the known transition regression test**

Start the observation in `.unavailable` with no revision.
Publish a revision, then transition to `.ready` and separately `.modelsRequired`.
Require the observation policy to reload and expose the new revision in both cases.

- [ ] **Step 2: Add same-state revision-change coverage**

Keep diarization state and jobs unchanged but change the current revision ID.
Require a reload so a completed transcript never waits indefinitely for another state transition.

- [ ] **Step 3: Run and verify RED**

Run `MeetingPresentationTests`.
Expected: the current loop compares only diarization state and jobs.

- [ ] **Step 4: Observe revision identity without tearing**

Read diarization state first and current revision second on every poll.
Compare state, revision ID, and active-job fingerprint.
Call the expensive full load only when one changes, preserving `ViewIdentityGeneration` cancellation checks before publishing.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite.
Expected: unavailable-to-ready, unavailable-to-modelsRequired, same-state revision, stale-view, and status-before-revision tests pass.

### Task 4: Give macOS fatal startup state and stage-specific Retry

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Create: `App/Sources/MacStartupPresentation.swift`
- Modify: `App/Sources/ContentView.swift`
- Create: `App/Tests/MacStartupPresentationTests.swift`
- Modify: `App/Tests/AppModelFolderBehaviorTests.swift`

**Interfaces:**
- Produces: injectable `MacPipelineStarter`, `MacStartupState`, `MacStartupFailure`, `MacLibraryIssue`, `retryStartup()`, and `retryLibraryIssue()`.
- Preserves: one runtime and the meeting-change observation task.

- [ ] **Step 1: Write fatal and recoverable RED tests**

Inject a failing pipeline open and require persistent Failed, then one successful Retry.
Inject meeting-list and folder-list failure after runtime creation and require Ready plus a targeted issue.
Require list Retry not to no-op behind the existing `runtime != nil` bootstrap guard.

- [ ] **Step 2: Run and verify RED**

Run `MacStartupPresentationTests` and `AppModelFolderBehaviorTests`.
Expected: one `bootstrapError` string cannot select the correct operation.

- [ ] **Step 3: Add injection and typed state**

Move the current `startPipeline` call behind a defaulted `MacPipelineStarter` closure in AppModel's initializer.
Use startup state only for the runtime open.
Use a typed library issue for meeting and folder refresh failures while preserving runtime and recording availability.

- [ ] **Step 4: Present a durable content state**

Replace the dismiss-only bootstrap alert with Opening and Failed content plus Try Again.
Render Ready content with a targeted retry banner for list/folder issues.
Leave capture-recovery warnings and original files untouched.

- [ ] **Step 5: Rerun and verify GREEN**

Run both focused suites.
Expected: correct retry path, runtime preservation, and persistent failure behavior pass.

### Task 5: Port the proven notes loading, unavailable, retry, and save states to macOS

**Files:**
- Modify: `App/Sources/NotesSection.swift`
- Create: `App/Tests/NotesSectionPresentationTests.swift`

**Interfaces:**
- Produces: `MacNotesSessionPresentation`, `MacNotesSessionLoader`, and transition-flush coordination.
- Consumes: the one canonical `MeetingNotesEditingSession` from AppModel.

- [ ] **Step 1: Write the presentation and retry tests**

Require Loading before the async session resolves, Loaded for a session, Unavailable for nil, and Retry to increment task identity while returning to Loading.
Require meeting changes and disappear to flush the prior canonical session.

- [ ] **Step 2: Run and verify RED**

Run `NotesSectionPresentationTests`.
Expected: current nil session renders only a disabled empty editor.

- [ ] **Step 3: Implement the macOS state surface**

Mirror the iOS semantic states with macOS layout: spinner while loading, ContentUnavailableView with Try Again when unavailable, editor when loaded, Saving indicator, and separate open/save error copy.
Never create a second editing session in the view.

- [ ] **Step 4: Rerun and verify GREEN**

Run the focused suite.
Expected: loading, retry, transition flush, save error, and canonical session cases pass.

### Task 6: Cancel legacy import only between atomic publication boundaries

**Files:**
- Modify: `StenoKit/Sources/StenoExchange/LegacyImportModels.swift`
- Modify: `StenoKit/Sources/StenoExchange/LegacyImporter.swift`
- Modify: `StenoKit/Tests/StenoExchangeTests/LegacyImporterTests.swift`
- Modify: `App/Sources/LegacyImportView.swift`
- Create: `App/Tests/LegacyImportPresentationTests.swift`

**Interfaces:**
- Produces: `LegacyImportOutcome.finished(ImportReport)` and `.cancelled(ImportReport)`, plus `LegacyImportModel.Phase.cancelling` and `.cancelled`.
- Preserves: `PreparedMeetingImport` atomic commit and legacy provenance deduplication.

- [ ] **Step 1: Write cancellation RED tests in StenoExchange**

Cancel before scanning/preparation and require no mutation.
Cancel after preparation but before commit and require no visible meeting.
Cancel after the first complete commit and require exactly that meeting plus a cancelled partial report.
Rerun and require the committed meeting to be deduplicated and the remaining meetings imported once.

- [ ] **Step 2: Prove CancellationError is not converted to a warning**

Inject cancellation from `prepareLegacyMeeting` and require the outer cancelled outcome, not an item warning or skipped-progress increment.
Require duplicate/postcommit folder repair to complete before the next cancellation checkpoint.

- [ ] **Step 3: Implement checkpoints outside atomic work**

Call `Task.checkCancellation()` before scan, before and after preparation, before each commit, after complete postcommit filing/report bookkeeping, before profile import, within profile loops, and before the one atomic person-document replace.
Catch `CancellationError` only at the outermost import boundary and return `.cancelled(currentReport)`.
Do not inject or observe cancellation inside `commitPreparedMeeting`.

- [ ] **Step 4: Run and verify StenoExchange GREEN**

Run:

```bash
swift test --package-path StenoKit --filter LegacyImporterTests
```

Expected: cancellation, resume, dedup, warnings, and existing import tests pass.

- [ ] **Step 5: Add a retained task and honest Mac phases**

Have `LegacyImportModel` own the running Task.
Show Cancel while importing, Cancelling while the task reaches the next safe boundary, and a Cancelled summary with committed meetings/files from the partial report.
Disable window-dismiss-sensitive actions while cancelling, but do not claim rollback.

- [ ] **Step 6: Run the Mac presentation suite**

Run `LegacyImportPresentationTests`.
Expected: duplicate clicks, first Cancel, repeated Cancel, late progress, partial report, and rerun availability pass.

### Task 7: Confirm endpoint deletion on iOS and macOS

**Files:**
- Modify: `iOS/App/Sources/TextModelSettingsView.swift`
- Modify: `iOS/App/Tests/TextModelEndpointPresentationTests.swift`
- Modify: `App/Sources/TextModelSettingsView.swift`
- Modify: `App/Tests/TextModelSettingsTests.swift`

**Interfaces:**
- Produces: platform presentation helpers for deletion title, display host, message, and destructive label.
- Consumes: the existing `TextModelSettings.remove(_:)` transaction only after confirmation.

- [ ] **Step 1: Write exact copy and target tests**

Require title to contain endpoint name and message to contain its display host.
Require the message to state that the saved API key is permanently removed and jobs pinned to this endpoint can no longer use that saved key.
Require dismiss/cancel to call no mutation.

- [ ] **Step 2: Run and verify RED**

Run the iOS endpoint presentation suite and macOS text model settings suite.
Expected: current Delete calls `remove` immediately.

- [ ] **Step 3: Add alert state and confirmation**

Store the complete `TextModelEndpoint` as the pending deletion target.
Open `.alert(..., presenting:)` from the menu, provide Cancel and destructive Delete Endpoint, and call the existing transactional remove method only from the destructive action.
Keep mutation errors on the endpoint row.

- [ ] **Step 4: Rerun and verify GREEN**

Run both focused suites.
Expected: copy, target identity, cancel, confirm, and existing transactional-recovery tests pass.

### Task 8: Disclose iOS report sharing before data leaves the app

**Files:**
- Modify: `iOS/App/Sources/MeetingReportsSection.swift`
- Create: `iOS/App/Sources/ReportShareDisclosure.swift`
- Modify: `iOS/App/Tests/MeetingReportsPresentationTests.swift`

**Interfaces:**
- Produces: `ReportShareDisclosureStore`, `ReportShareDisclosurePresentation`, and a programmatic native share sheet.
- Consumes: the existing `ReportSharePayload.text` only.

- [ ] **Step 1: Write the disclosure contract tests**

Require first-share copy to say the selected report text goes to the chosen app or service.
Require it to say audio, voice evidence, and embeddings are not included.
Require the seen flag to persist only after the person proceeds to the share sheet.

- [ ] **Step 2: Run and verify RED**

Run `MeetingReportsPresentationTests`.
Expected: the current direct ShareLink has no disclosure state.

- [ ] **Step 3: Add one-time disclosure and native sharing**

On the first Share action, show the disclosure before presenting `UIActivityViewController`.
On later actions, present the share sheet directly.
Pass only the existing report-text payload and never meeting audio, prototype, hard-negative, or embedding objects.

- [ ] **Step 4: Rerun and verify GREEN**

Run the focused suite.
Expected: first, cancel, proceed, subsequent, and payload-classification tests pass.

### Task 9: Make Mac model installation cancellable, indeterminate before callbacks, and quiet when ready

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Create: `App/Sources/MacModelInstallationPresentation.swift`
- Modify: `App/Sources/ModelStatusView.swift`
- Modify: `App/Sources/TranscriptionModelSettingsView.swift`
- Create: `App/Tests/ModelInstallationPresentationTests.swift`

**Interfaces:**
- Produces: `MacModelInstallProgressPresentation`, `MacModelInstallCancellationState`, one retained installation `Task`, and `cancelModelInstallation()`.
- Consumes: existing ModelInstallationCoordinator install, cancelAll, consent, and readiness APIs.

- [ ] **Step 1: Write progress, cancellation, and ready-action tests**

Require Installing with no callback to show indeterminate Preparing.
Require real progress to show clamped determinate state.
Require the first Cancel to show Cancelling, a second to do nothing, consent to remain, and verified readiness to be re-read afterward.
Require fully Ready state to expose no contradictory Allow and Install button.
Use an installer double whose cancellation request returns before its install task exits, then require Cancelling and the old readiness to remain until that exact task completes.

- [ ] **Step 2: Run and verify RED**

Run `ModelInstallationPresentationTests`.
Expected: current code fabricates zero progress, has no consent-preserving Cancel, and always shows Allow and Install.

- [ ] **Step 3: Implement state without fabricated progress**

Leave `modelInstallProgress` nil until the first coordinator callback in baseline and Parakeet installs.
Track cancellation separately from consent revocation and suppress cancellation-induced transport errors while the request is active.
Retain the exact active installation task and clear it only by identity in the install completion path.
After `cancelAll()` returns, await the retained task, then refresh baseline and Parakeet readiness and leave Cancelling; do not set readiness locally.

- [ ] **Step 4: Add visible Cancel/Cancelling to both Mac model surfaces**

Use an indeterminate ProgressView before callbacks and determinate afterward.
Show Cancel for baseline and Parakeet downloads, Cancelling while in flight, and hide or replace install CTA when verified Ready.
Keep Revoke as a separate destructive consent action.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite and existing transcription model integration tests.
Expected: progress, cancel race, consent, readiness, and ready CTA cases pass.

### Task 10: Review all recovery boundaries before broad UI work continues

**Files:**
- Verify all files changed above.

**Interfaces:**
- Consumes: completed Tasks 1 through 9.
- Produces: independent review findings and focused green suites.

- [ ] **Step 1: Request independent implementation review**

Review fatal versus recoverable startup state, retry routing, revision observation ordering, notes session ownership, legacy cancellation placement, partial reports, endpoint keychain semantics, report-share payload, and model cancellation/consent races.
Resolve Critical and Important findings and request one targeted re-review.

- [ ] **Step 2: Run every focused suite listed above**

Reuse one build root per platform and do not repeat unchanged full suites.
Expected: all focused StenoKit, iOS, and macOS suites pass.

- [ ] **Step 3: Perform isolated failure injection**

Use temporary libraries to fail runtime open, meeting list, folder list, notes load, legacy preparation, post-first commit, endpoint removal, and model cancellation.
Record what remained visible and what was retried as measured facts for final QA.
