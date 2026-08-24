# iOS Editing Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let iPhone and iPad users correct transcript lines, manage additional participants, focus transcript search from hardware keyboards, and complete endpoint forms without weakening revision or speaker-evidence rules.

**Architecture:** Port the proven macOS transcript and additional-participant boundaries into iOS, but expose them through touch-sized sheets and window-local command routing.
Every correction appends against the exact visible revision, every concurrent revision conflict stays visible, and additional participants remain separate from evidence-backed speakers.
Pure presentation types preserve original turn indices through filtering and make focus order testable.

**Tech Stack:** Swift 6, SwiftUI, Observation, StenoDomain, StenoLibrary, StenoPipeline, StenoIdentity, Swift Testing, XcodeGen

**Spec:** `docs/superpowers/specs/2026-08-23-cross-platform-ui-modernisierung-und-demo-design.md`

## Global Constraints

- Transcript source revisions are immutable and every correction creates a new `.userEdit(parentRevisionID)` revision.
- A conflict never silently rebases against a newer transcript.
- Search filtering never converts a filtered-row offset into an original turn index.
- `participantIDs` remain evidence-backed speakers and are never changed by the additional-participant editor.
- Additional participants create no prototypes or hard negatives.
- A failed meeting update after person creation does not silently delete the new person.
- Commands act only on the focused window's `NavigationRouter`.
- New pure presentation types return `LocalizedStringResource` for user-visible text from their first implementation.
- No dependency changes, remote push, merge, or publication.

---

### Task 1: Add a typed iOS transcript-correction boundary

**Files:**
- Modify: `iOS/App/Sources/AppModel.swift`
- Create: `iOS/App/Sources/AppModel+Transcript.swift`
- Create: `iOS/App/Tests/AppModelTranscriptEditTests.swift`

**Interfaces:**
- Consumes: `TranscriptEdit.replacingText`, `Library.appendRevision`, `Library.pendingRevision`, and `Library.adoptPendingRevision`.
- Produces: `TranscriptCorrectionSaveResult`, `TranscriptCorrectionError`, `saveTranscriptEdit`, `pendingTranscript`, and `adoptPendingTranscript(meetingID:expectedCurrentRevisionID:expectedCandidateID:)`.

- [ ] **Step 1: Write real-library RED tests**

Create a temporary `Library`, meeting, and current revision.
Require a correction to append `.userEdit(oldRevision.id)`, preserve the old revision, preserve speaker/start/end, and clear word timings only in the edited line.
Require wrong meeting, empty text, out-of-range turn, and two simultaneous saves for the same meeting to return distinct typed errors.

- [ ] **Step 2: Add the revision-conflict and pending tests**

Append a competing revision between sheet open and save, then require `.revisionConflict` and unchanged stored revisions.
Require unchanged text to return `.unchanged` without a new file.
Require a later automatic revision to remain pending until explicit adoption.
Capture both the visible current revision ID and pending candidate ID, replace either one before adoption, and require the stale action to adopt nothing.
Require two windows that inspected different current/candidate pairs to affect only the pair each displayed.

- [ ] **Step 3: Regenerate and verify RED**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData -only-testing:StenoTests/AppModelTranscriptEditTests test
```

Expected: compilation fails because the typed iOS API does not exist.

- [ ] **Step 4: Implement the minimal append-only API**

Add a per-meeting in-flight set to reject overlapping edits before suspension.
Validate `revision.meetingID == meetingID`, call `TranscriptEdit.replacingText`, and append exactly the returned revision.
Map `invalidRevisionParent` to `.revisionConflict` and retain other failures as stable user-facing error cases with technical detail logged separately.
Expose pending load and explicit adoption without automatic takeover.
Pass both inspected IDs to `Library.adoptPendingRevision(meetingID:expectedCurrentRevisionID:expectedCandidateID:)`; never call either permissive overload from the iOS action.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite.
Expected: append, conflict, unchanged, pending, and concurrency cases pass.

### Task 2: Add an explicit touch-sized correction action to every transcript row

**Files:**
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Create: `iOS/App/Sources/TranscriptCorrectionSheet.swift`
- Create: `iOS/App/Sources/TranscriptCorrectionPresentation.swift`
- Modify: `iOS/App/Tests/MeetingPresentationTests.swift`

**Interfaces:**
- Produces: `TranscriptTurnMatch`, `TranscriptTurnPresentation.matches`, and `TranscriptCorrectionTarget`.
- Consumes: the AppModel API from Task 1 and `TranscriptSearch.matchingTurnIndices`.

- [ ] **Step 1: Write failing original-index tests**

Build a revision where a search matches original turns 0 and 2.
Require the presented matches to retain indices `[0, 2]`, not `[0, 1]`.
Require the sheet draft to contain the complete selected turn text.

- [ ] **Step 2: Write sheet-state tests**

Require a revision conflict to keep the sheet open and preserve typed text.
Require successful save to replace the local visible revision with the returned revision.
Require pending adoption to occur only after the visible `Use the new one` action.

- [ ] **Step 3: Run and verify RED**

Run `MeetingPresentationTests`.
Expected: the correction presentation types and action do not exist.

- [ ] **Step 4: Build the correction sheet and row action**

Give every transcript row an explicit Correct button with at least a 44-point hit area and stable identifier.
Open a sheet with the exact visible revision and original turn index.
Show Cancel and Save, disable empty input, preserve draft and error on failure, and dismiss only after `.saved` or deliberate Cancel.

- [ ] **Step 5: Present pending transcription without overwriting edits**

When a newer automatic transcript is pending, show `A newer transcription is ready.`
Show `Your correction is shown instead.` and an explicit `Use the new one` action alongside it.
Explain that the correction remains as an earlier revision after adoption.
Bind the action to the visible current revision ID and visible pending candidate ID captured before the async call.

- [ ] **Step 6: Rerun and verify GREEN**

Run the focused suite.
Expected: index, draft, conflict, success, and pending-adoption tests pass.

### Task 3: Separate speaker-backed and additional participant presentation

**Files:**
- Modify: `iOS/App/Sources/MeetingParticipantsSection.swift`
- Modify: `iOS/App/Tests/SpeakerReviewPresentationTests.swift`

**Interfaces:**
- Produces: `MeetingParticipantRole`, `MeetingParticipantRow`, `MeetingParticipantSections`, and `MeetingParticipantsPresentation.sections`.

- [ ] **Step 1: Write the participant classification matrix**

Require evidence-backed meeting IDs and current confirmed clusters to appear in Speakers.
Require additional IDs to appear in Additional only when the same ID is not already a speaker.
Require stale, multiple, self, and unknown clusters not to create a named speaker.
Require same-name people to remain distinct by `PersonID`.

- [ ] **Step 2: Add unresolved and removability tests**

Require missing stored person IDs to set `hasUnresolvedPeople`.
Require only `.additional` rows to have `canRemove == true`.

- [ ] **Step 3: Run and verify RED**

Run `SpeakerReviewPresentationTests`.
Expected: the current flattened `names` presentation cannot express role or safe removal.

- [ ] **Step 4: Implement the pure section resolver**

Resolve known persons by ID, deduplicate speaker IDs first, subtract them from additional IDs, sort deterministically by localized display name then ID, and retain unresolved state.
Keep the existing current-run checks for named clusters.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite.
Expected: all role, overlap, stale-cluster, same-name, and unresolved cases pass.

### Task 4: Persist additional participants through one serialized review boundary

**Files:**
- Modify: `iOS/App/Sources/AppModel+Review.swift`
- Modify: `iOS/App/Sources/MeetingParticipantsSection.swift`
- Create: `iOS/App/Sources/MeetingParticipantEditorSheet.swift`
- Modify: `iOS/App/Tests/MeetingReviewIntegrationTests.swift`

**Interfaces:**
- Produces: `addAdditionalParticipant(_:name:meetingID:) async -> Bool` and `removeAdditionalParticipant(_:meetingID:) async -> Bool`.
- Uses: `IdentityStore.createPerson`, `Library.updateAdditionalMeetingParticipants`, and the existing `MeetingReviewPublication` path.

- [ ] **Step 1: Write failing temporary-store integration tests**

Require a known person to be added only to `additionalParticipantIDs`.
Require a newly created person to have empty prototypes and hard negatives.
Require `participantIDs` to remain byte-for-byte unchanged.
Require removal to affect only the additional array.

- [ ] **Step 2: Add publication and failure tests**

Require a coherent reload to publish the changed meeting to other iPad windows immediately.
Require a duplicate person name to produce a visible typed error.
Inject meeting-update failure after person creation and require the now-unused person to remain visible rather than being silently deleted.

- [ ] **Step 3: Run and verify RED**

Run `MeetingReviewIntegrationTests`.
Expected: the iOS mutation methods and participant editor do not exist.

- [ ] **Step 4: Port the proven mutation order and serialize it**

Use `reviewActionsInFlight` to serialize additional-participant changes against speaker review for the same meeting.
Resolve or create the person, reload the meeting, reject duplicates across both participant arrays, update only additional IDs, then publish a freshly assembled coherent review snapshot.
Never append a prototype or rebuild hard negatives.

- [ ] **Step 5: Build the participant editor sheet**

Add an Edit Participants button to the section.
List known nonparticipants, offer a field for a new name, separate Speakers from Additional, and show Remove only for Additional.
Use native controls with 44-point targets and keep errors inside the sheet.

- [ ] **Step 6: Rerun and verify GREEN**

Run the integration and presentation suites.
Expected: persistence, publication, evidence exclusion, and touch presentation pass.

### Task 5: Focus transcript search through the window-local iPad command path

**Files:**
- Modify: `iOS/App/Sources/NavigationRouter.swift`
- Modify: `iOS/App/Sources/StenoCommands.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Tests/NavigationRouterTests.swift`
- Modify: `iOS/App/Tests/StenoCommandStateTests.swift`

**Interfaces:**
- Produces: `NavigationRouter.transcriptSearchFocusRequest`, `requestTranscriptSearchFocus()`, and `StenoCommandActions.focusTranscriptSearch(in:)`.

- [ ] **Step 1: Write command locality tests**

Require every request to increment the focused router's counter and leave a second router unchanged.
Require Find in Transcript to be disabled without a selected meeting.

- [ ] **Step 2: Run and verify RED**

Run `NavigationRouterTests` and `StenoCommandStateTests`.
Expected: the focus request and command do not exist.

- [ ] **Step 3: Add Cmd-F and bind the native search focus**

Add a Find in Transcript command with `Cmd-F`.
Use `@FocusState` and `.searchFocused` in MeetingDetailView, reacting to the router's monotonically increasing request.
Keep the router in focused scene values so two iPad windows cannot redirect each other.

- [ ] **Step 4: Add stable focusable controls**

Ensure Inspector, meeting menu, search, Correct, Edit Participants, Cancel, and Save are native Button/Menu/TextField controls with stable identifiers and no tap-gesture-only alternative.

- [ ] **Step 5: Rerun and verify GREEN**

Run both focused suites.
Expected: locality, repeated request, and command availability pass.

### Task 6: Give the endpoint editor deterministic Next, Done, and input semantics

**Files:**
- Modify: `iOS/App/Sources/TextModelSettingsView.swift`
- Modify: `iOS/App/Tests/TextModelEndpointPresentationTests.swift`

**Interfaces:**
- Produces: `EndpointEditorField` and `EndpointEditorFocusOrder`.
- Consumes: `TextModelAPIDialect` and SwiftUI `FocusState`.

- [ ] **Step 1: Write the dialect-specific focus order tests**

Require OpenAI-compatible order Name, Base URL, Model, Context Window, API Key.
Require Bedrock order Name, Inference Profile, Model, Context Window, API Key, with disabled URL skipped.
Require `next(after:)` to return nil after the final visible field.

- [ ] **Step 2: Run and verify RED**

Run `TextModelEndpointPresentationTests`.
Expected: the focus-order types do not exist.

- [ ] **Step 3: Apply field semantics**

Use normal words and Next for Name.
Use URL keyboard, URL content type, no autocorrection, and no capitalization for Base URL.
Use ASCII-capable, no autocorrection, and no capitalization for profile and model IDs.
Use number pad plus keyboard-toolbar Next and Done for Context Window.
Use `SecureField`, `.privacySensitive()`, ASCII-capable input, no autocorrection/capitalization, and Done for API Key.

- [ ] **Step 4: Wire FocusState to the pure order**

On submit or keyboard-toolbar Next, move to the next visible field for the current dialect.
Done clears focus.
Do not focus disabled or hidden fields.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused suite.
Expected: both dialect orders and final Done behavior pass.

### Task 7: Independent review and iPad form-factor editing acceptance

**Files:**
- Verify all files changed above.

**Interfaces:**
- Consumes: completed Tasks 1 through 6.
- Produces: review findings and measured editing results for final QA.

- [ ] **Step 1: Request independent implementation review**

Review revision-parent selection, filtered turn indices, pending-adoption semantics, participant/evidence separation, partial person creation, multi-window publication, router locality, and endpoint privacy semantics.
Resolve Critical and Important findings and request one targeted re-review.

- [ ] **Step 2: Run the complete iOS app suite**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData test
```

Expected: the full iOS app suite passes.

- [ ] **Step 3: Exercise touch, keyboard, and conflict flows on the iPad simulator form factor**

Correct searched and unsearched turns, force a revision conflict, adopt a pending transcript, add and remove additional participants, verify speakers remain nonremovable, invoke Cmd-F repeatedly in two windows, and traverse every endpoint field with Full Keyboard Access.
Repeat the hardware-dependent subset on an explicitly authorized selected iPad or other iOS device when available.
Record keyboard focus order and sheet layout as measured only on the surface actually inspected.
