# Working in this repository

Steno records meetings, transcribes and diarizes them locally, and produces meeting minutes.
Everything runs on the device.
Only a text model explicitly selected for report generation may receive meeting content externally.

This repository contains both apps and their shared core.
The name `steno-macos` is historical.

## Platform target

Steno is built and tested exclusively for Apple Silicon.
The macOS app, the iOS and iPadOS app, and custom build or fixture helpers are ARM64-only.
Intel, x86_64, Rosetta, and Universal Binaries are unsupported and receive no compatibility work.
In an Asset Catalog, `universal` refers to the Apple device class, not a processor architecture.

## Repository layout

| Path | Contents |
|---|---|
| `StenoKit/` | The shared core, a SwiftPM package with ten library targets. Both apps depend on it. |
| `App/` | The macOS app. |
| `iOS/App/`, `iOS/StenoiOSKit/` | The iOS and iPadOS app. `StenoiOSKit` is a separate package rather than a StenoKit target because it depends on the `AVAudioSession` lifecycle, which does not exist on macOS. |
| `docs/` | Plans and measurement records. Read the root `ARCHITECTURE.md` and `docs/PLAN-IOS.md` first. |
| `scripts/` | `build-app.sh` for macOS, `build-ios.sh` for iOS and iPadOS, and `generate-model-checksums.sh` for the model checksum manifest. |

Target membership determines which code is platform-specific:

- `StenoAudioCore` is portable and contains everything that makes a recording trustworthy: `TrackWriter`, `CaptureRecovery`, `DiskSpaceChecker`, and `RecordingSession`.
  Both platforms record through this target.
  Do not rebuild any of it elsewhere.
- `StenoMacAudio` is macOS-only.
  It contains Mac microphone capture through `MicRecorder`, `MicrophoneDiscovery`, and `CoreAudioInputDevice`; the CoreAudio process tap for system audio through `SystemAudioRecorder`; permission checks; and sleep prevention.
  It is never built for iOS.
  Its iOS counterpart is `StenoiOSAudio` in `StenoiOSKit`.

## Building and testing

```sh
swift test --package-path StenoKit      # shared core
scripts/build-app.sh [--run]            # macOS app
scripts/build-ios.sh                    # iOS, build only
scripts/build-ios.sh --simulator [UDID] # booted simulator, or the first one without a UDID
scripts/build-ios.sh --ipad-simulator   # boot or create an iPad simulator
scripts/build-ios.sh --device [UUID]    # first iPhone or iPad when no UUID is supplied
```

There are four test suites, not one.
The other three use Xcodebuild and do not run `xcodegen` automatically.
After switching branches, run `xcodegen generate` first or the build may fail with `cannot find type ...` because the generated project is stale.

```sh
xcodebuild -project Steno.xcodeproj -scheme Steno \
  -destination 'platform=macOS' test                     # macOS app

cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData test                # iOS app

cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test   # iOS audio package
```

Record test counts during final verification so that a silent drop is noticeable.

Tests use Swift Testing.
Two failure modes have already caused problems:

- `#expect` wraps its expression in a closure with an immutable receiver.
  Calling a mutating method inside it does not compile with `cannot use mutating member on immutable value`.
  Perform the mutation first and assert only the result.
- A test that inserts a breakpoint into production async code and then waits synchronously blocks a cooperative-pool thread.
  Enough concurrent waits can stall the complete run.
  Use `withBlockingTestExecutor` and `blockingTestTask` from `TestSupport.swift`, which place these waits on a dedicated dispatch queue.

Both Xcode projects are generated from their `project.yml` and ignored by Git.
After every branch switch, merge, or rebase, run `xcodegen generate` before diagnosing missing types.
The build scripts do this automatically.

Settings belong in `project.yml`, never in Xcode's interface, because the next XcodeGen run discards interface-only changes.
This is especially important for signing, bundle identifiers, and Info.plist keys.
`App/Info.plist` and `iOS/App/Info.plist` are generated from the `info:` block and ignored by Git.
Direct edits disappear without warning.

## Repository language

English is the repository's default and normative language.
Write all new documentation, source comments, test names, script output, commit messages, and default user-interface strings in English.
When editing an actively maintained German document or comment, translate the relevant surrounding section rather than adding more mixed-language prose.

German remains valid only where the language itself is part of the product or test contract:

- translated values in localization catalogs;
- speech, transcript, and named-term fixtures for German-language tests;
- the bundled synthetic German demo meetings; and
- quoted titles or source material whose original wording matters.

Historical development records may remain German when they are clearly marked as non-normative and are not linked as current guidance.
Do not rename historical files merely to translate their path unless every reference is updated in the same change.

## Local model and resource safety

Do not download, install, or execute a local language, translation, transcription, embedding, or other machine-learning model for repository maintenance unless Ben explicitly authorizes that exact model and run after seeing the estimated download size, peak memory, disk use, and expected duration.
The fact that inference stays local is not permission to consume machine resources.
Prefer the current agent's own capabilities or an already authorized service over ad hoc local inference.

Apple MPS uses unified system memory.
GPU offload is therefore not a memory limit and can exhaust the RAM needed by every other application.
A checkpoint's file size is not a valid estimate of peak memory because weights, caches, activations, framework copies, and generated output may coexist.

If Ben explicitly authorizes a local model run, all of the following are mandatory:

1. Record a baseline using `memory_pressure`, `sysctl vm.swapusage`, available disk space, and the largest current process groups.
2. Calculate a conservative peak-memory estimate before downloading or loading the model.
3. Use a hard per-process resource limit or an independent watchdog that measures physical footprint and can terminate the entire task-owned process tree.
   If neither can be enforced, do not run the model.
4. Start with one tiny representative input.
   Do not start a corpus, repository-wide, or multi-file run until that sample has completed and its measured peak is safe.
5. Abort immediately when physical footprint exceeds 4 GiB, swap grows by more than 1 GiB from baseline, memory pressure turns yellow or red, or usage grows without a stable bound.
6. Run only one local model process at a time and never overlap it with a full build or test suite.
7. After stopping, verify the parent and all children are gone before deleting files.
   Recheck memory pressure and swap, then remove every task-owned model, environment, cache, and session artifact.

Never repeat a local model attempt with a larger model after a smaller model produces poor output.
Report the quality limitation and use a different workflow.

## Non-negotiable rules

- The recording is the only irreplaceable artifact.
  Transcription, diarization, and reports can be repeated, but a lost recording cannot.
  A missing speech model, unsupported language, or transcription failure must therefore never stop recording.
  Both apps keep recording and processing in separate tasks, and that separation must remain intact.
- Originals are immutable.
  They are written once and never overwritten.
  Corrections create a new revision as described in section 4 of `ARCHITECTURE.md`.
- Never guess anything the user will read as fact.
  An unconfirmed speaker cluster remains generic, an inference is labeled as an inference, and a cluster containing multiple voices receives no name.
- The system locale is not the spoken language.
  A device configured in English while located in Germany may report `en_DE`, which could silently transcribe German speech as plausible English text.
  Both apps therefore maintain an explicit persisted transcription language.
  `Locale.current` does not belong in the transcription path.
- Models do not download themselves.
  Since the onboarding work, every installation passes through `ModelInstallationCoordinator` with consent and checksums.
  Providers no longer download models independently.
- Voice evidence is excluded, never deleted.
  Prototypes and hard negatives carry `excludedAt`, and every evaluation filters through `isActive`.
  Removing entries instead of excluding them bypasses exclusion and revocation, and the loss becomes invisible when recognition later fails without an apparent reason.
- Run and revision provenance are foundational.
  A listening sample comes from the exact track diarized by that run, not merely another track of the same type.
  A correction is based on the current revision or `RevisionStore` rejects it as a conflict.
  When provenance is ambiguous, return nothing rather than the wrong result.

## Changes to the shared core

A change in `StenoKit` affects both apps.
That is why both applications live in one repository: breakage should surface during the build rather than days later.
Every core change requires the complete build chain:

```sh
xcodegen generate && scripts/build-app.sh && scripts/build-ios.sh && swift test --package-path StenoKit
```

Building alone is insufficient when core behavior changes.
Run both app suites listed above as well, because they catch failures that the compiler does not.

Two regressions on 8 August 2026 were invisible to Git because both sides changed different lines and surfaced only through this chain.
One new view used a type that had just moved modules, while the iOS app still called provider initializers whose parameters had been removed.

## Parallel work

Use worktrees for concurrent tasks.
The ignored `.worktrees/` directory is reserved for them:

```sh
git worktree add .worktrees/<name> -b <branch>
```

Worktrees do not solve every conflict:

- They isolate files, not semantic changes in the shared core.
  Keep branches short, rebase on `main` early, and run the complete chain afterward.
- Every Mac build shares the library under `~/Library/Application Support/Steno/Library`.
  Set `STENO_LIBRARY_DIR` and `STENO_MODEL_DIR` to disposable directories for every test that must not touch user recordings.
- A device can contain bundle identifier `org.steno.Steno` only once.
  Two worktrees installing to the same device overwrite one another.

`iOS/StenoiOSKit/Package.resolved` is intentionally unversioned.
The sole external pin lives in `StenoKit/Package.resolved`; keeping two pins for the same dependency caused drift.

## Practical iOS notes

- Automatic signing uses `DEVELOPMENT_TEAM` from the ignored local `.steno-signing.xcconfig`.
  Copy `.steno-signing.xcconfig.example` as a template.
  With a free Apple account, the app stops launching after seven days and must be reinstalled.
  This is expected behavior.
- After its first wired pairing, a device connects over the local network with `transportType: localNetwork`.
  Being unlocked and on the same network is sufficient.
- The simulator cannot provide `SpeechTranscriber` and reports no supported languages.
  Live transcription, language selection, and model installation can be tested only on a physical device.
- Do not control the simulator with `cliclick`.
  Several attempts on 7 August 2026 missed their intended controls.
  Use `xcrun simctl io <udid> screenshot` for screenshots, never `screencapture`, which captures the entire desktop and unrelated windows.

## Handoffs

`HANDOFF.md`, `HANDOFF-*.md`, and `UEBERGABE*.md` are session artifacts.
They are ignored by Git and never committed.
When leaving unfinished work, write a handoff containing the branch, current state, open work, and known dead ends.
A handoff belongs to the task that created it.
Never overwrite another task's handoff.
