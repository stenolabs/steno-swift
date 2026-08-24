# Synthetic Demo Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three reproducible synthetic demo meetings that both apps can install, update, and remove safely without models, network access, real meeting data, or global speaker evidence.

**Architecture:** Add persisted demo provenance to the domain, then introduce a portable `StenoDemo` target that verifies a bundled manifest into immutable byte snapshots before preparing each meeting through the existing atomic import boundary.
Meeting metadata remains the ownership truth, while a small root index is only a cache.
Enforce the speaker-evidence prohibition in the shared review write path and expose the same lifecycle through platform-native settings on macOS and iOS.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, StenoDomain, StenoLibrary, StenoPipeline, XcodeGen, Piper offline TTS, PCM WAV/CAF fixtures, SHA-256

**Spec:** `docs/superpowers/specs/2026-08-23-cross-platform-ui-modernisierung-und-demo-design.md`

## Global Constraints

- Demo installation never opens or inspects the operator's real meeting library in tests or QA.
- Demo ownership is determined only by fixed IDs plus persisted `DemoProvenance`.
- Titles, the `DEMO:` prefix, and folder names are never ownership or deletion criteria.
- Demo operations start no model, job, network request, person creation, prototype, or hard negative.
- Every meeting is published only through `Library.commitPreparedMeeting`.
- Every removal uses `Library.trashMeeting`.
- The install index is a repairable cache and never outranks meeting metadata.
- AMI and CCC files remain outside the product bundle.
- New pure presentation types return `LocalizedStringResource` for user-visible text from their first implementation.
- No dependency changes, remote push, merge, or publication.

---

### Task 1: Persist demo provenance without breaking schema-one documents

**Files:**
- Modify: `StenoKit/Sources/StenoDomain/Meeting.swift`
- Modify: `StenoKit/Sources/StenoDomain/TranscriptRevision.swift`
- Create: `StenoKit/Tests/StenoDomainTests/DemoProvenanceTests.swift`

**Interfaces:**
- Produces: `DemoProvenance`, `MeetingMetadata.demoProvenance`, `Meeting.isDemo`, and `TranscriptOrigin.demo(DemoProvenance)`.
- Preserves: decoding of every existing meeting and transcript revision.

- [ ] **Step 1: Write failing additive-Codable tests**

Test round trips for `DemoProvenance(datasetID:datasetVersion:itemID:)` and `.demo(provenance)`.
Decode a literal schema-one meeting whose metadata has no demo key and require `demoProvenance == nil`.
Prove that rename and folder changes preserve `isDemo`, while a real meeting titled `DEMO: Real meeting` is not a demo.

- [ ] **Step 2: Run the domain tests and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter DemoProvenanceTests
```

Expected: compilation fails because the provenance and transcript-origin cases do not exist.

- [ ] **Step 3: Add the minimal domain API**

Define `DemoProvenance` as public, Codable, Equatable, Hashable, and Sendable with immutable dataset ID, dataset version, and item ID.
Add `demoProvenance: DemoProvenance? = nil` to `MeetingMetadata` without changing `Meeting.currentSchemaVersion`.
Add `Meeting.isDemo` as a computed property based only on persisted provenance.
Add `.demo(DemoProvenance)` to `TranscriptOrigin`.

- [ ] **Step 4: Rerun and verify GREEN**

Run the command from Step 2.
Expected: all old and new domain tests pass.

### Task 2: Add the portable manifest and closed resource verifier

**Files:**
- Modify: `StenoKit/Package.swift`
- Create: `StenoKit/Sources/StenoDemo/DemoManifest.swift`
- Create: `StenoKit/Sources/StenoDemo/DemoResourceBundle.swift`
- Create: `StenoKit/Sources/StenoDemo/DemoLibraryError.swift`
- Create: `StenoKit/Tests/StenoDemoTests/DemoManifestTests.swift`
- Create: `StenoKit/Tests/StenoDemoTests/TestSupport.swift`

**Interfaces:**
- Produces: `StenoDemo`, `DemoDatasetManifest`, `DemoMeetingManifest`, `DemoResourceDescriptor`, `DemoAudioManifest`, and verified access to bundled resources.
- Depends only on: `StenoDomain` and `StenoLibrary`.

- [ ] **Step 1: Add a failing package import test**

Create the `StenoDemoTests` target and import `StenoDemo` from `DemoManifestTests` before adding the product.
Run:

```bash
swift test --package-path StenoKit --filter DemoManifestTests
```

Expected: SwiftPM fails because the product and module do not exist.

- [ ] **Step 2: Add product, target, resources, and test target**

Add a `StenoDemo` library product.
Add a target depending on `StenoDomain` and `StenoLibrary`, copying `Resources/DemoDataset` as one resource tree.
Add `StenoDemoTests` with the same dependencies.

- [ ] **Step 3: Write the complete manifest validation matrix**

Require schema version 1, one fixed dataset ID, one nonempty version, exactly three unique meetings, unique meeting/revision/media/run/item/resource IDs, fixed UTC dates, positive sample rates and durations, and titles beginning with `DEMO:`.
Reject absolute paths, `..`, symlinks, path escape, missing files, wrong byte counts, wrong SHA-256 values, duplicate IDs, and transcript JSON whose meeting ID, revision ID, or demo provenance disagrees with the manifest.

- [ ] **Step 4: Implement minimal manifest types and resource verification**

Model generator, model revision, speaker IDs, input-script checksum, mix parameters, license, and modification provenance explicitly.
Resolve every resource below the copied bundle root after standardization and symlink checks.
Verify the full dataset before exposing any `PreparedMeetingImport`.

- [ ] **Step 5: Rerun and verify GREEN**

Run the focused test command.
Expected: a valid temporary manifest passes and every single corruption fixture fails with a specific `DemoLibraryError`.

### Task 3: Generate and license the byte-stable synthetic dataset

**Files:**
- Create: `scripts/demo/demo-script.json`
- Create: `scripts/demo/render-demo-audio.sh`
- Create: `scripts/demo/mix_demo_audio.py`
- Create: `docs/DEMO-FIXTURE.md`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/manifest.json`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/ATTRIBUTION.md`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/projektauftakt/audio.wav`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/projektauftakt/transcript.json`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/projektauftakt/notes.md`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/projektauftakt/report.md`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/projektauftakt/reference.txt`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/projektauftakt/reference.rttm`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/wochenrunde/audio.wav`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/wochenrunde/transcript.json`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/wochenrunde/notes.md`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/wochenrunde/reference.txt`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/wochenrunde/reference.rttm`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/produktinterview/audio.wav`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/produktinterview/transcript.json`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/produktinterview/report.md`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/produktinterview/reference.txt`
- Create: `StenoKit/Sources/StenoDemo/Resources/DemoDataset/produktinterview/reference.rttm`
- Modify: `StenoKit/Tests/StenoDemoTests/DemoManifestTests.swift`

**Interfaces:**
- Consumes: a pinned Piper binary and pinned `de_DE-mls-medium` voice revision during development only.
- Produces: three redistributable pre-rendered recordings, fixed transcript/report fixtures, reference transcripts and speaker timelines, and complete attribution.

- [ ] **Step 1: Lock generator inputs and licenses before rendering**

Pin the Piper binary release, voice repository revision, exact `de_DE-mls-medium` model revision, chosen speaker IDs, and SHA-256 values in `demo-script.json` and `docs/DEMO-FIXTURE.md`.
Read the license files at those exact revisions.
Require Piper and voice-repository MIT notices plus the model card's stated CC BY 4.0 dataset attribution.
Stop this task if the pinned artifacts do not carry those terms.

- [ ] **Step 2: Write deterministic scripts and a failing fixture test**

Make the shell wrapper download only into a task-owned cache, verify every checksum before execution, and invoke the mixer with explicit PCM16 sample rate, gain, start time, and output path.
Extend `DemoManifestTests` to open every bundled audio file with AVFoundation where available, compare duration and sample rate to the manifest, and verify all hashes.
Expected RED: bundled resources are still missing.

- [ ] **Step 3: Render three fictions and manually review the reference data**

Render the three fixed meetings with no real names or companies.
Ensure `DEMO: Projektauftakt Musterstadt` contains 60 to 90 seconds of three-speaker German speech with short documented overlaps.
Use only `SpeakerReference.importedTextLabel` in revisions and create no `Person` records.
Listen to each recording against its transcript and RTTM timeline, then record reviewer, date, audible limitations, and deliberate edits in `docs/DEMO-FIXTURE.md`.

- [ ] **Step 4: Freeze the manifest and verify GREEN**

Compute byte counts and SHA-256 values only after manual approval.
Run `swift test --package-path StenoKit --filter DemoManifestTests`.
Expected: all assets open, all metadata matches, all hashes pass, and no model or generator binary is bundled.

### Task 4: Implement idempotent installation, resume, conflict detection, and cache repair

**Files:**
- Modify: `StenoKit/Sources/StenoLibrary/LibraryLayout.swift`
- Modify: `StenoKit/Sources/StenoLibrary/PreparedMeetingImport.swift`
- Modify: `StenoKit/Sources/StenoLibrary/FolderStore.swift`
- Modify: `StenoKit/Tests/StenoLibraryTests/FolderStoreTests.swift`
- Create: `StenoKit/Sources/StenoDemo/DemoInstallationIndex.swift`
- Create: `StenoKit/Sources/StenoDemo/DemoLibraryStatus.swift`
- Create: `StenoKit/Sources/StenoDemo/DemoLibrarySeeder.swift`
- Create: `StenoKit/Tests/StenoDemoTests/DemoLibrarySeederTests.swift`

**Interfaces:**
- Produces: `DemoLibrarySeeder.status()` and `install()`.
- Reserves typed-unavailable `replace(policy:)` and `remove()` entry points only if needed for source stability; Task 5 owns their real policy and lifecycle behavior.
- Produces in StenoLibrary: package-scoped transaction-aware folder lookup/create and prepared-meeting commit overloads that accept one existing `LibraryMutationTransaction` and never acquire a nested lock.
- Uses: `PreparedMeetingImport`, `LibraryMutationCoordination`, and `AtomicFile.write`.

- [ ] **Step 1: Write failing status and installation tests**

With a temporary real `Library` and `FolderStore`, require first install to publish three meetings in one top-level `Demo Meetings` folder, second install to be a byte-preserving no-op, and a simulated interruption after one complete commit to resume only the two missing items.
Require notes and exactly two reports, an empty `JobStore`, and an empty `IdentityStore`.
Pause after the initial unlocked preflight, install a real meeting at one fixed demo ID through another library handle, resume the seeder, and require the winner to remain byte-identical with no demo folder, demo meeting, or index mutation.

- [ ] **Step 2: Add conflict and cache-truth tests**

Seed a non-demo meeting at one fixed demo meeting ID and require preflight failure with a byte-identical root snapshot, no new folder, and no index.
Require missing or stale index data to be repaired from meeting provenance without duplicates.
Require a same-named user folder to be reused and never marked as seeder-owned.

- [ ] **Step 3: Run and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter DemoLibrarySeederTests
```

Expected: compilation fails because the lifecycle API does not exist.

- [ ] **Step 4: Implement preflight and per-meeting atomic commits**

Verify the manifest and every resource first.
Inspect all fixed meeting IDs before calling `folder(named:)` or writing the index.
Treat matching meeting ID plus dataset ID plus item ID as installed, a missing ID as installable, and every other occupant as a closed conflict.
Prepare each complete media, revision, immutable legacy note, and report import from the already verified byte snapshots and publish it only with `commitPreparedMeeting`.
Do not install the reference RTTM as a finished diarization run: it is benchmark ground truth, while runtime diarization consumers require a typed `DiarizationArtifact` in `diarization.json`.
Keep reference transcript and RTTM resources in the verified bundle and use the manifest run IDs only as stable report identifiers, following the existing legacy-import report pattern.
Atomically update the root index after each visible commit so a process interruption between meetings is resumable.
Acquire one exclusive `LibraryMutationCoordination` transaction before the first mutation, recheck all fixed IDs inside it, then create or reuse the folder and publish each prepared meeting through transaction-aware no-nested-lock overloads.
Keep that transaction through every per-meeting commit and per-commit index update so another cooperating process cannot occupy a later fixed ID after preflight.
Allow injected interruption only after a complete meeting and its index checkpoint, then release the transaction normally.

- [ ] **Step 5: Implement status and index repair**

Return per-item states `missing`, `installed`, `modified`, `outdated(installedVersion:)`, and `conflictingMeeting`.
Determine modification at minimum from a current revision ID that differs from the manifest revision, and conservatively classify every unexplained divergence as modified.
Use index data only to remember version and folder ownership after confirming matching meeting provenance.

- [ ] **Step 6: Rerun and verify GREEN**

Run the focused suite.
Expected: complete install, no-op, resume, conflict, and cache-repair tests pass without jobs, people, or evidence.

### Task 5: Add generation-safe replacement, recoverable removal, and race-safe folder cleanup

**Files:**
- Modify: `StenoKit/Sources/StenoDomain/Meeting.swift`
- Modify: `StenoKit/Sources/StenoDomain/Job.swift`
- Modify: `StenoKit/Sources/StenoAudioCore/CaptureRecovery.swift`
- Modify: `StenoKit/Sources/StenoLibrary/Library.swift`
- Modify: `StenoKit/Sources/StenoLibrary/FolderStore.swift`
- Modify: `StenoKit/Sources/StenoLibrary/JobStore.swift`
- Modify: `StenoKit/Sources/StenoLibrary/RecoverySweep.swift`
- Modify: `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift`
- Modify: `StenoKit/Sources/StenoPipeline/TemplateRenderRequest.swift`
- Modify: `StenoKit/Sources/StenoPipeline/MeetingDiarizationRequest.swift`
- Modify: `StenoKit/Sources/StenoPipeline/MeetingProcessingJobRequest.swift`
- Modify: `StenoKit/Sources/StenoPipeline/MeetingReview.swift`
- Modify: `StenoKit/Sources/StenoDemo/DemoInstallationIndex.swift`
- Modify: `StenoKit/Sources/StenoDemo/DemoLibraryStatus.swift`
- Modify: `StenoKit/Sources/StenoDemo/DemoLibrarySeeder.swift`
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/AppModel+Review.swift`
- Modify: `App/Sources/SpeakerProcessingJobSelection.swift`
- Modify: `iOS/App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/AppModel+Review.swift`
- Modify or create the directly corresponding Domain, Library, Pipeline, macOS, iOS, and Demo tests.

**Interfaces:**
- Produces: an optional installation-generation ID in `DemoProvenance`, a general `Meeting.processingGenerationID`, and a source-compatible `Job.processingGenerationID` alias over the persisted import-generation field.
- Produces: generation-pinned job creation and generation-aware commit and completion checks for every productive processing path.
- Produces: `FolderStore.deleteFolderIfEmpty(_:) -> EmptyFolderDeletionResult`, a transaction-aware Trash boundary, real `DemoReplacementPolicy`, and honest per-item `DemoLifecycleResult` values.
- Uses: recoverable Trash semantics for every matching demo meeting and never deletes a visible meeting directory directly.

- [ ] **Step 1: Reproduce the generation ABA failure**

Install generation G1, prepare or enqueue an old G1 job, replace the meeting under the same fixed ID with generation G2, and then allow the stale job to resume or enqueue.
Expected RED: the old job can currently observe the same meeting ID and reach a G2 write boundary.
Require the final implementation to cancel or fail every stale job before any Run, revision, report, review, participant, person, or meeting mutation.

- [ ] **Step 2: Persist a backward-compatible processing generation**

Add an optional installation-generation ID to `DemoProvenance` so older meetings and immutable bundled transcript provenance still decode with `nil`.
Make `Meeting.processingGenerationID` select demo installation generation first, transfer generation second, and `nil` otherwise.
Keep the existing persisted Job Codable key and expose a general processing-generation alias instead of performing a destructive Job migration.
Create a fresh UUID for first install, version upgrade, explicit same-version replacement, and install after removal.
Preserve the existing UUID for no-op, Keep, and crash resume after a visible commit.
Raise the Demo installation index schema and validate each stored generation against Meeting provenance under the library transaction.

- [ ] **Step 3: Pin every productive job creation path**

Pin `Job.finalASR(for:)`, the explicit Apple retry on both apps, template rendering, diarization requests, meeting-processing requests, the two legacy review job creation paths, and every other productive raw `Job(kind:meetingID:)` construction found by a whole-tree search.
Retries of an existing Job preserve that Job's generation.
Downstream Jobs copy the parent generation.
Imported-meeting generation behavior must remain unchanged.
Make Job equivalence, recovery lookups, speaker-processing selection, and app-level active-job presentation compare the processing generation instead of Meeting ID alone.

- [ ] **Step 4: Make Pipeline commits and completion generation-aware**

Generalize the current transfer-generation guard to `Meeting.processingGenerationID` at every artifact and model write boundary.
Make `PipelineCompletionPolicy` ignore queued, running, or failed Jobs from other generations so an old G1 Job cannot keep G2 in `processing`.
Complete the Job status transition and final Meeting generation check inside one root transaction, including template-render completion.
Prevent stale Jobs from committing even if a raw enqueue races just after replacement.

- [ ] **Step 5: Write and implement the empty-folder transaction API**

Require `.deleted` for an empty folder, `.notFound` for an absent folder, and `.notEmpty` for a folder with a child or any assigned meeting.
Inject a mutation checkpoint to prove child inspection, meeting assignment inspection, and document mutation share one `LibraryMutationCoordination` transaction.
Delete only the exact requested folder.
Do not promote children or move meetings in this specialized cleanup API.

- [ ] **Step 6: Add a transaction-aware recoverable Trash boundary**

Recheck Meeting ownership and processing generation inside the same root transaction that performs the same-volume move to Trash.
Return an uncertain outcome if the move throws after the source disappears, because absence alone does not prove rollback or success.
Never call the lock-acquiring public `trashMeeting` from an outer transaction, never hard-delete Job history, and never empty Trash automatically.

- [ ] **Step 7: Write replacement and removal RED tests**

Create real v1 and v2 test manifests with the same fixed ownership IDs, distinct dataset versions, distinct revision IDs, and explicit installation generations.
Require `.keepModifiedMeetings` to upgrade only demonstrably unchanged outdated items and leave every edited item byte-identical.
Require `.replaceModifiedMeetings` to Trash an edited item only after explicit destructive policy.
Require already-current unmodified items to remain byte- and inode-identical.
Cover title, folder, note, transcript, audio, report, unexpected file, missing baseline, stale index, active Job, queued-late Job, and generation mismatch cases.
Interrupt after the first complete Trash, install, baseline, generation, and index checkpoint, rerun, and require convergence without duplicate Trash entries or a third generation.
Require removal to find renamed and moved demos by provenance while preserving real `DEMO:` meetings, real meetings inside the demo folder, and foreign occupants of fixed IDs.
Require an owned empty folder to disappear and every user-owned, unknown-ownership, renamed, moved, or nonempty folder to remain.
Inject failure and uncertain Trash outcomes after one successful item and require an honest per-item result that supports safe retry.

- [ ] **Step 8: Implement replacement conservatively**

Verify the complete bundled dataset and construct immutable blueprints before the first mutation.
Within a separate exclusive transaction per item, prove fixed Meeting ID plus dataset ID plus item ID ownership, validate the current generation and raw-tree baseline, and inspect relevant Jobs before Trash.
Treat every missing or unprovable baseline as modified.
Keep leaves modified Meetings untouched.
Replace moves the old generation to Trash, publishes a complete new generation with `commitPreparedMeeting`, fingerprints the visible tree, and checkpoints the per-item index before returning success.
Do not overwrite a visible Meeting directory in place and do not claim multi-Meeting atomicity.

- [ ] **Step 9: Implement recoverable removal and folder cleanup**

Accept older versions only when fixed ID, dataset ID, item ID, and persisted generation prove ownership.
Trash each matching Meeting in its own transaction and checkpoint the result so reruns converge safely.
Keep the seeder-created folder claim resumable after the last Meeting is trashed and until cleanup is conclusively `.deleted`, `.notFound`, or `.notEmpty`.
Delete the folder only when the exact stored ownership claim still matches and `deleteFolderIfEmpty` returns `.deleted`.

- [ ] **Step 10: Run focused invariance verification**

Run:

```bash
swift test --package-path StenoKit --filter FolderStoreTests
swift test --package-path StenoKit --filter DemoLibrarySeederTests
```

Also run the focused Domain, Pipeline, macOS, and iOS tests that cover generation pinning and retry job creation.
Expected: every generation guard, replacement, Trash, partial-result, folder-race, and byte-invariance case passes.

### Task 6: Block every demo action that can create positive or negative voice evidence

**Files:**
- Modify: `StenoKit/Sources/StenoIdentity/IdentityReviewFlow.swift`
- Modify: `StenoKit/Tests/StenoIdentityTests/IdentityInvariantTests.swift`
- Modify: `StenoKit/Sources/StenoPipeline/MeetingReviewController.swift`
- Modify: `StenoKit/Tests/StenoPipelineTests/MeetingReviewControllerTests.swift`

**Interfaces:**
- Produces: required `VoiceEvidenceMutationPolicy`, `IdentityReviewError.voiceEvidenceForbidden`, and `MeetingReviewController.ReviewActionError.demoMeetingCannotCreateVoiceEvidence`.
- Protects: positive prototypes, hard negatives, participants, review state, and person creation.

- [ ] **Step 1: Write failing identity-engine tests**

Construct an `IdentityReviewState` whose evidence policy is forbidden.
Require confirm, reassign, mark-multiple, and reset-to-generic to fail before removing, appending, or rebuilding any evidence.
Require `keepGeneric` to remain available because it marks only the local review state and never rebuilds hard negatives.

- [ ] **Step 2: Add the fail-closed shared evidence policy and verify GREEN**

Add an immutable `VoiceEvidenceMutationPolicy` value to `IdentityReviewState` with explicit `.allowed` and `.forbidden` cases and no default argument.
Update every existing state construction site to pass `.allowed` explicitly so any future caller must make the decision at compile time.
Guard every path that calls `removePositiveEvidence`, appends `SpeakerPrototype`, or calls `rebuildHardNegatives`.
Run `swift test --package-path StenoKit --filter IdentityInvariantTests`.

- [ ] **Step 3: Write failing controller-store tests**

Create a real demo meeting in a temporary library and attempt confirm, reassign, confirm-as-new-person, mark-multiple, and reset-to-generic.
Require the typed demo error and byte-identical persons, participants, review, prototypes, and hard negatives.
Specifically prove confirm-as-new-person persists no `Person`.

- [ ] **Step 4: Apply the policy before any controller mutation**

After loading the meeting, build review state with evidence mutation forbidden for demo provenance.
Preflight `confirmAsNewPerson` before `IdentityStore.makePerson` so the prohibited intent is explicit even though the current local append would not persist after a throw.
Map the engine error to the typed controller error.

- [ ] **Step 5: Run pipeline and identity suites**

Run:

```bash
swift test --package-path StenoKit --filter IdentityInvariantTests
swift test --package-path StenoKit --filter MeetingReviewControllerTests
```

Expected: all demo evidence mutations fail without store changes, while normal meetings retain current behavior.

### Task 7: Expose demo lifecycle, badges, and speaker explanation on macOS

**Files:**
- Modify: `project.yml`
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/SettingsView.swift`
- Create: `App/Sources/DemoDataSettingsView.swift`
- Create: `App/Sources/DemoBadge.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `App/Sources/MeetingDetailView.swift`
- Modify: `App/Sources/SpeakerReviewSection.swift`
- Create: `App/Tests/DemoDataPresentationTests.swift`

**Interfaces:**
- Consumes: `DemoLibrarySeeder` from the current opened runtime and folder store.
- Produces: install, keep/replace, remove, attribution, badge, and evidence-block explanation UI.

- [ ] **Step 1: Write failing pure presentation tests**

Require exact confirmation copy for installing three local synthetic meetings with no model or network.
Require edited-item replacement options `Keep edited meetings` and destructive `Replace all demo data`.
Require removal copy to say marked demo meetings and their user changes move to Trash.
Require the badge policy to depend only on `meeting.isDemo`.

- [ ] **Step 2: Add the package dependency and AppModel boundary**

Link the `StenoDemo` product through `project.yml`.
Create the seeder only from the currently opened `Library` and `FolderStore`.
Serialize each lifecycle action, publish progress/error state, and call `refreshMeetings()` afterward.

- [ ] **Step 3: Build settings and badges**

Add a `Demo Data` settings tab with status, attribution, install, replace, and remove actions.
Show `Demo` badges in sidebar and at the start of meeting detail without changing titles.
For demo review, explain that demo audio cannot create or change real voice profiles; expose only the evidence-free generic action.

- [ ] **Step 4: Run the focused macOS test**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' -derivedDataPath .build/ui-modernization/DerivedData-mac -only-testing:StenoTests/DemoDataPresentationTests test
```

Expected: presentation, badge, and lifecycle-state tests pass.

### Task 8: Expose the same lifecycle and badges in the existing iOS navigation

**Files:**
- Modify: `iOS/project.yml`
- Modify: `iOS/App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/ContentView.swift`
- Modify: `iOS/App/Sources/MeetingSidebarView.swift`
- Create: `iOS/App/Sources/DemoDataSettingsView.swift`
- Create: `iOS/App/Sources/DemoBadge.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Sources/SpeakerReviewSection.swift`
- Create: `iOS/App/Tests/DemoDataPresentationTests.swift`

**Interfaces:**
- Produces: `SidebarItem.demoData` in the existing `NavigationSplitView` and the same safe lifecycle semantics as macOS.
- Preserves: one adaptive iPhone/iPad hierarchy with no outer `TabView`.

- [ ] **Step 1: Write failing iOS presentation and routing tests**

Require `.demoData` to route through the existing sidebar tools section in compact and regular width.
Reuse the same lifecycle copy and badge rules as macOS while keeping platform-specific view types.

- [ ] **Step 2: Link StenoDemo and add the AppModel boundary**

Add the product in `iOS/project.yml`.
Construct the seeder inside `AppModel.swift`, where the private folder store is available, serialize lifecycle actions, and call `reloadMeetings()` after completion.

- [ ] **Step 3: Add the tool route, settings view, badges, and review explanation**

Insert `Demo Data` into the current Tools section and switch in `ContentView`.
Show install, replace, remove, attribution, and partial-result states.
Render badges from provenance and hide evidence-producing speaker actions while explaining why.

- [ ] **Step 4: Run the focused iOS test**

Run:

```bash
cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData -only-testing:StenoTests/DemoDataPresentationTests test
```

Expected: routing, copy, badges, and lifecycle-state tests pass.

### Task 9: Review and isolated lifecycle acceptance

**Files:**
- Verify all files changed above.
- Update: `docs/DEMO-FIXTURE.md`

**Interfaces:**
- Consumes: the completed demo implementation.
- Produces: independent review findings and a measured lifecycle record for final QA.

- [ ] **Step 1: Request an independent implementation review**

Review ownership, conflict preflight, resource path containment, index repair, partial commits, Trash use, folder cleanup, and both positive and negative evidence paths.
Resolve Critical and Important findings and request one targeted re-review.

- [ ] **Step 2: Run the focused package and app tests**

Run all test filters from Tasks 1 through 8.
Expected: every focused suite passes before the consolidated final run.

- [ ] **Step 3: Exercise lifecycle only in a fresh isolated library**

Install twice, simulate and resume a partial install, rename and move a demo, create a user revision, exercise keep and explicit replace, add a real `DEMO:` meeting, add a real meeting to the demo folder, and remove the dataset.
Confirm preserved real meetings, Trash behavior, folder ownership, visible badges, two reports, no jobs, and no people/evidence.

- [ ] **Step 4: Record measured versus inferred facts**

Record exact fixture hashes, durations, sample rates, installed IDs, lifecycle results, and store checks as measured.
Record synthetic audio's usefulness for real-world WER or DER only as intentionally unsupported, not inferred quality.
