# Voluntary iOS Diarization Model Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** iPhone and iPad users can explicitly install the existing local speaker-separation models without coupling recording or Apple transcription to those models, and can deliberately resume only diarization jobs that failed because the models were absent.

**Architecture:** `StenoDiarization` continues to own the checked installer, model readiness, and an incomplete-install marker that keeps partially downloaded bundles hidden from the live provider, while `StenoPipeline` owns a typed, idempotent retry boundary for failed diarization jobs.
The iOS app creates a second installation state and a separate persisted consent record for the Hugging Face bundle, presents it as a distinct foreground-only section, blocks installation while recording, and restarts the idle pipeline only after a successful install so future and retried jobs use the existing local provider.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, Swift Testing, Swift Package Manager, XcodeGen, FluidAudio's existing model download support, and the existing StenoKit pipeline.

## Binding Constraints

- Recording, recording finalization, Apple speech installation, and final ASR never depend on diarization readiness or consent.
- The only network source presented and consented for this bundle is `huggingface.co`.
- The displayed transfer size comes from the existing measured `509,902,848` byte model bundle description and includes an exact byte count plus a readable rounded value.
- Diarization consent uses its own persisted key and record and is never inferred from Apple speech consent.
- Installation is a manually started foreground action and is unavailable while a recording is active.
- The existing `DiarizationModelInstaller`, bundled checksum manifest, `LibraryLocation.modelCacheURL()`, cache location, and backup exclusion are reused without a new dependency.
- Successful installation may requeue only failed `.diarization` jobs whose persisted failure is exactly `DiarizationError.modelsNotInstalled`, plus pre-upgrade jobs whose untyped message exactly matches the former missing-model error shape.
- Retry is idempotent, never creates a final-ASR job, never retries another failure, and never creates an automatic retry loop.
- UI text promises speaker clusters or labels, not recognition or person names.
- No model download, installation, AirDrop action, or other device mutation occurs in this implementation session.

## Task 1: Persist a Typed Missing-Diarization-Model Failure

**Files:**
- Modify: `StenoKit/Sources/StenoDomain/Job.swift`
- Modify: `StenoKit/Sources/StenoLibrary/JobStore.swift`
- Modify: `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift`
- Test: `StenoKit/Tests/StenoPipelineTests/PipelineIntegrationTests.swift`
- Test: `StenoKit/Tests/StenoLibraryTests/JobStoreTests.swift`

- [x] Add RED tests proving that a `DiarizationError.modelsNotInstalled` failure persists a machine-readable failure reason while another diarization failure does not.
- [x] Add a backward-compatible optional job failure reason with a default of `nil`, and clear it on transitions that leave `.failed`.
- [x] Classify only the concrete diarization error at the pipeline failure boundary.
- [x] Run the focused JobStore and PipelineCoordinator tests GREEN.

## Task 2: Add a Shared Idempotent Retry Boundary

**Files:**
- Create: `StenoKit/Sources/StenoPipeline/MissingDiarizationModelJobRetrier.swift`
- Create: `StenoKit/Tests/StenoPipelineTests/MissingDiarizationModelJobRetrierTests.swift`

- [x] Add RED tests for one eligible retry, unrelated failures, other job kinds, already queued or finished jobs, a pre-upgrade missing-model job, and a second idempotent call.
- [x] Requeue only `.failed` `.diarization` jobs carrying the typed missing-model reason or the exact historical message shape.
- [x] Assert no new job is created and no `.finalASR` job changes.
- [x] Run the focused retrier tests GREEN.

## Task 3: Introduce Dedicated iOS Consent and Installation State

**Files:**
- Modify: `iOS/App/Sources/ModelConsent.swift`
- Modify: `iOS/App/Sources/IOSModelInstallationState.swift`
- Modify: `iOS/App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/StenoApp.swift`
- Modify: `iOS/App/Sources/RecordingView.swift`
- Modify: `iOS/App/Sources/LibraryLocation.swift`
- Modify: `StenoKit/Sources/StenoDiarization/ModelAccess.swift`
- Modify: `StenoKit/Sources/StenoDiarization/FluidSortformerProvider.swift`
- Modify: `StenoKit/Sources/StenoDiarization/DiarizationModelInstaller.swift`
- Test: `iOS/App/Tests/ModelConsentTests.swift`
- Test: `iOS/App/Tests/IOSModelInstallationStateTests.swift`
- Test: `iOS/App/Tests/LibraryBackupPolicyTests.swift`

- [x] Add RED tests proving speech and diarization consent persist independently and revoking either record does not alter the other.
- [x] Add RED tests for diarization readiness, exact model source and size, recording guard, monotonic progress, cancellation, visible error, and foreground-owned completion.
- [x] Construct the diarization coordinator from the existing installer, bundled manifest, and `LibraryLocation.modelCacheURL()`.
- [x] Keep speech and diarization readiness and installation locks separate while preventing either configuration change from racing bootstrap or recording.
- [x] Mark the live cache incomplete before download, clear the marker only after full checksum verification, and make the provider fail typed while it is present.
- [x] Verify the cache directory is created under Caches and remains excluded from backup.
- [x] Run the focused iOS state, consent, and backup-policy tests GREEN.

## Task 4: Restart Safely and Retry Eligible Jobs After Installation

**Files:**
- Modify: `iOS/App/Sources/AppModel.swift`
- Test: `iOS/App/Tests/LibraryBackupPolicyTests.swift`
- Test: `iOS/App/Tests/IOSModelInstallationStateTests.swift`

- [x] Add RED tests proving active recording blocks consent and installation without stopping the runtime.
- [x] Add RED tests proving successful install stops and rebuilds only an idle runtime, invokes the shared retrier once, and leaves final-ASR jobs untouched.
- [x] Add RED tests proving a new recording cannot start while the foreground install is active and backgrounding cancels without revoking consent.
- [x] Add RED tests proving cancellation, install failure, and retry persistence failure do not loop or falsely report readiness.
- [x] Wire the successful install path through the existing runtime-change serializer and idle-only detach boundary.
- [x] Run the focused AppModel and installation tests GREEN.

## Task 5: Add the Thin Separate iOS UI

**Files:**
- Modify: `iOS/App/Sources/AudioReadinessView.swift`
- Test: `iOS/App/Tests/AudioReadinessPresentationTests.swift`

- [x] Add RED presentation tests for the separate `Speaker separation` section, `huggingface.co`, exact `509,902,848 bytes`, readable size, foreground-only wording, active-recording lock, and cluster-not-name explanation.
- [x] Show independent readiness, progress, consent, install, revoke, and error state without changing the Apple speech section.
- [x] Ensure the install button is manual, unavailable during recording or another serialized configuration change, and never claims person recognition.
- [x] Run focused presentation tests and the complete iOS app test suite GREEN.

## Task 6: Verify, Review, and Hand Off

**Files:**
- Create or update: `HANDOFF-ios-diarization-model-installation.md`
- Update uncommitted task report or ledger only if already used by this milestone.

- [x] Run `xcodegen generate`.
- [x] Run focused StenoDiarization, StenoPipeline, StenoLibrary, and iOS tests.
- [x] Run the complete serial StenoKit suite once after the consolidated fixes.
- [x] Run the complete iOS app suite and StenoiOSKit suite.
- [x] Run `scripts/build-app.sh` and `scripts/build-ios.sh`.
- [x] Obtain one independent read-only review of the privacy, consent, retry, and recording-independence boundaries.
- [x] Fix only reproduced or specification-relevant findings, with at most one targeted re-review.
- [x] Commit only milestone-owned source, tests, and plan changes locally.
- [x] Preserve all existing untracked artifacts and stop before any real model installation or device action.
