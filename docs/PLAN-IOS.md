# Steno for iPhone and iPad - Current product and implementation plan

Status: 24 August 2026.
This is the English entry point for current iOS work.
The complete German design session from 7 August 2026 is preserved as a non-normative historical record in [`history/PLAN-IOS-2026-08-07.de.md`](history/PLAN-IOS-2026-08-07.de.md).
Current code, tests, `ARCHITECTURE.md`, and `FEATURE-PARITY.md` take precedence over that historical record.

## 1. Product decision

Build one universal, local-first iPhone and iPad app.
The iPhone is optimized for room recording and a live transcript.
The iPad is the primary review station with full speaker review, people management, notes, and reports.
The Mac remains responsible for system-audio capture, legacy import, and benchmark work.

Devices exchange individual meetings through explicit export and import before any library-sync system exists.
The same origin meeting identifier and canonical content digest produce a no-op; a changed package with the same origin produces a conflict rather than an implicit merge.

Reconsider the standalone iPhone product if any blocking hardware measurement fails:

- A 60-minute recording cannot complete final transcription and diarization sequentially within the target iPhone memory limit.
- One hour of recording with live ASR causes unacceptable thermal throttling or battery use.
- Single-track diarization is unusable on representative room recordings.

System-audio and call capture remain Mac-only because iOS provides no third-party capture path for them.

## 2. One app, adaptive layout

Use one SwiftUI app target for iPhone and iPad with `NavigationSplitView`, size classes, and no device-type branching for layout.
Narrow iPad windows must behave like compact iPhone layouts.

- Sidebar: meeting and folder navigation.
- Detail: transcript, reports, and current job state.
- Inspector: speakers, participants, and notes; a column on iPad and a sheet on iPhone.
- Recording: a focused full-screen workflow on compact width and a recording strip on regular width.
- State: one process-wide observable app model so multiple iPad windows show the same recording.
- Restoration: `@SceneStorage` stores the selected meeting per scene; the library remains restorable from disk.
- Commands: Command-Period to stop, Command-M to mark a moment, Command-F for transcript search, and Command-N for a new meeting.

Three iOS-specific interfaces require dedicated design rather than a direct Mac port:

1. A one-handed iPhone recording screen readable in under three seconds.
2. Visible interruption and route-change states for calls, Siri, and disconnected microphones, including the time through which audio is safe.
3. One combined view of app job status and `BGContinuedProcessingTask` progress.

Use system sharing, `fileImporter`, `fileExporter`, and `ShareLink` instead of AppKit panels and pasteboards.
Use the input picker and active AVAudioSession route for external USB-C microphones.
Do not add Apple Pencil-specific features without a real data-model need; Scribble already works in text fields.

## 3. Platform baseline

The deployment target remains iOS 26.
Recording, SpeechAnalyzer ASR, diarization, identity, the file-based library, export, Foundation Models, background processing APIs, split views, inspectors, keyboard shortcuts, and input-device selection are available on iOS 26.

iOS 27 features may be added behind availability checks after verification with an installed iOS 27 SDK.
They are optional enhancements, not foundations of the product.
Examples include Private Cloud Compute language models, image input to models, and improved list reordering.
Private Cloud Compute is a cloud provider and must follow the same explicit-choice and disclosure rules as every external model.

## 4. Architecture

Both apps share the portable StenoKit targets:

- `StenoDomain`
- `StenoLibrary`
- `StenoTranscription`
- `StenoDiarization`
- `StenoIdentity`
- `StenoIntelligence`
- the generic portion of `StenoExchange`
- `StenoPipeline`

iOS never builds `StenoMacAudio` or the command-line executables.
`StenoiOSKit` remains a separate local SwiftPM package because it owns the `AVAudioSession` lifecycle that does not exist on macOS.
Its `StenoiOSAudio` target configures recording permission and session category, microphone capture, interruption and route-change handling, levels, and single-track recording.

Portable capture guarantees belong in `StenoAudioCore`: `TrackWriter`, `AudioLevelMeter`, `AudioBufferTransfer`, `CaptureRecovery`, `DiskSpaceChecker`, audio errors, audio sources, and `RecordingSession`.
Both platform audio targets build on that shared core.

Xcode projects are generated from `project.yml`.
Platform declarations and signing settings belong there, never in generated project files or generated Info.plists.

## 5. Library, Files, and transfer

The iOS library lives under `Documents/StenoLibrary` and is visible in Files.
The protection boundary remains the existing schema validation, integrity checks, and corrupt-artifact quarantine.
The plaintext library and private validation root are excluded from iCloud device backup until library encryption exists.
This prevents an unintended plaintext cloud copy but creates a clear local-loss risk when no deliberate backup exists.
Downloaded Core ML model caches are also excluded from backup.
Steno does not use an iCloud container, ubiquitous documents, or CloudKit.

One exported meeting is a regular, uncompressed, unencrypted `.stenomeeting` Apple Archive file.
Audio is off by default and is included only after explicit local confirmation for that transfer.
The UI may direct the user to AirDrop, but the system share sheet can offer other destinations and cannot guarantee AirDrop-only transport.

## 6. Milestones and current state

### i1: shell, library, microphone recording, and live transcript

Implemented: app structure, shared audio core, single-track capture, library startup and recovery, live SpeechAnalyzer transcription, explicit model installation, and resumption of final ASR jobs.
Acceptance remains tied to real hardware for interruptions, route changes, long recording, and background behavior.

### i2: on-device post-processing

Implement and verify final transcription, diarization, identity suggestions, persistent jobs, cancellation, and background continuation.
A second iOS ASR engine must pass a benchmark using real German reference material before it is exposed in the product.
The provider implementation alone is not an engine-selection decision.

### i3: iPad review station

Implemented: shared folder tree and persistent disclosure state, date-grouped unfiled meetings, context-menu management, search normalization, transfer reveal, and adaptive sidebar presentation.
Context menus remain the complete functional path when drag and drop is unreliable.
Multi-selection and batch movement remain macOS-specific.

Open manual gates include compact iPhone sidebar behavior, context menus and dialogs, actual drag gestures, search and transfer reveal, external microphone route changes, Stage Manager widths, and a complete keyboard-driven review.

### i4: reports, intelligence, and privacy registry

Implemented: Apple as the default local provider, explicitly selected external endpoints, pinned input and revision, immutable report versions, progress, error, cancellation, copy, and share payloads.
Settings never contacts an endpoint automatically.

Open gates:

- Generate and regenerate on Apple Intelligence-capable iPhone or iPad hardware in airplane mode using a harmless German fixture; observe Copy, Share, and Cancel.
- Test a deliberately selected LM Studio endpoint with a non-sensitive synthetic fixture and real `/models` and `/chat/completions` requests.
- Visually verify report layouts, long scrolling, version selection, external-provider disclosure, old-version retention during pending and failed states, Copy, Share, and passive Settings behavior.
- Direct Gemma downloads, custom templates, and paid cloud-provider tests remain open.

### i5: device bridge without sync

Export and import one `.stenomeeting` package without mutation or implicit merge.
An unchanged package imports as a no-op.
Changed content with the same origin is rejected as a visible conflict.

### i6: encrypted library sync, deferred

Do not build sync before the encryption beta and a dedicated architecture review.
A future sync may include transcript, meeting and person documents, notes, and reports, but never original audio.
Voice embeddings require a separate explicit decision because they are biometric data.
Pair devices by QR-carried secret without an account.
Transport, conflict resolution, device revocation, key rotation, and recovery remain open design questions.

## 7. Required measurements

- **R1 memory and jetsam:** three sequential final-transcription and diarization runs over a 60-minute target-iPhone recording, with measured peak memory and no jetsam termination.
- **R2 background and interruption:** a 60-minute locked-screen recording, accepted and rejected incoming calls, and a post-processing run after immediately switching apps. Audio must remain intact, interruption state must be explicit, and jobs must resume idempotently.
- **R3 thermal and battery:** one hour of recording with live ASR on iPhone and iPad, recording thermal state and battery every five minutes. Define the acceptance threshold from the first measurement rather than inventing one.
- **R4 microphone mode:** compare Measurement, default, and user-selected Voice Isolation on one controlled multi-speaker table scene using WER and DER.
- **R5 single-track diarization:** measure real room recordings with four and more than four speakers, plus the existing eight-speaker benchmark, before considering another engine.
- **R6 Foundation Models availability:** show honest availability on iPhone and iPad hardware with and without Apple Intelligence.
- **R7 Files write access:** deliberately rename an original and edit JSON in Files; startup must report or quarantine the damage instead of crashing or overwriting silently.

Store results as `docs/BENCH-IOS-*.md` in English.

## 8. Do not pursue

- System-audio or call capture on iOS through CoreAudio taps, ReplayKit, CallKit, or conference-call workarounds.
- Copying StenoKit instead of sharing it as a package.
- Catalyst or a single shared Mac/iOS UI framework.
- Live diarization or live LLM execution during recording.
- Apple Pencil features without a product and data-model requirement.
- A sync service before encryption.
- A separate iPad UI target.

## 9. Source of truth

For current implementation status, use the code, test results, `ARCHITECTURE.md`, and `FEATURE-PARITY.md`.
Use the historical German plan only for rationale and dated evidence that has not yet been superseded.
