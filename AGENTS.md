# Repository guide

Steno records meetings, transcribes and diarizes them locally, and produces meeting minutes.
Recording safety, privacy, and provenance take priority over convenience.

## Supported platforms

Steno targets Apple Silicon only.
The supported application targets are macOS 26, iOS 26, and iPadOS 26.
Intel, Rosetta, and Universal Binaries are outside the supported scope.

## Repository layout

| Path | Contents |
|---|---|
| `StenoKit/` | Shared SwiftPM package used by both applications. |
| `App/` | macOS application. |
| `iOS/App/` | iPhone and iPad application. |
| `iOS/StenoiOSKit/` | iOS-specific audio-session and microphone-capture package. |
| `Shared/` | Presentation code and resources shared by both applications. |
| `docs/` | Architecture, privacy contracts, fixture policies, and measurements. |
| `scripts/` | Build, benchmark, and reproducible fixture tools. |

`StenoAudioCore` contains the platform-independent recording machinery shared by both applications.
`StenoMacAudio` contains macOS-only microphone, system-audio, permission, and sleep-prevention code.
`StenoiOSAudio` is its iOS-specific counterpart.

## Build and test

Both Xcode projects are generated from `project.yml` and are not versioned.
Run XcodeGen after switching branches, merging, or rebasing.

```sh
swift test --package-path StenoKit

xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno \
  -destination 'platform=macOS' test

cd iOS
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData test

cd StenoiOSKit
xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Run focused checks while iterating.
A lasting change to `StenoKit` requires all four suites because it affects both applications.
Record test counts during final verification so an accidental loss of coverage is visible.

## Architectural invariants

- The recording is the only irreplaceable artifact.
  A missing model, unsupported language, or processing failure must never stop recording.
- Original recordings are immutable.
  Corrections and retranscriptions create new revisions.
- Unconfirmed speaker identities remain generic.
  Inferences must be identified as inferences.
- The system locale is not the spoken language.
  Transcription uses the explicitly selected and persisted language.
- Model installation is explicit and passes through `ModelInstallationCoordinator` with consent and checksum verification.
- Voice evidence is excluded rather than deleted so revocation and evaluation remain observable.
- Run and revision provenance must be exact.
  Return no result when the source run or revision is ambiguous.

See `ARCHITECTURE.md` for the complete design and data model.

## Generated files and local state

Settings belong in `project.yml`, not in Xcode's interface.
XcodeGen recreates the projects and generated `Info.plist` files.

Use disposable `STENO_LIBRARY_DIR` and `STENO_MODEL_DIR` locations for tests that could otherwise touch a real installation.
Do not download or execute large machine-learning models during routine repository maintenance.
Any model-specific validation must be explicitly scoped, resource-bounded, and approved by a maintainer.

## Language and test data

English is the repository's normative language for documentation, source comments, test names, scripts, commit messages, and default UI strings.

German remains appropriate only for:

- localized UI values;
- deliberate speech, transcript, and named-term fixtures;
- synthetic German demo meetings; and
- quoted source material whose original wording matters.

Never put real recordings, transcripts, participant details, credentials, or other private meeting data in the repository, an issue, or a pull request.
