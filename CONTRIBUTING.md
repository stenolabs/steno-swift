# Contributing to Steno

Steno is a source-only public beta for Apple Silicon.
Bug reports, focused fixes, tests, and documentation improvements are welcome.

## Language

English is the repository's default language.
Use English for documentation, source comments, test names, script output, commit messages, and default user-interface strings.

German localization values and deliberate German speech, transcript, named-term, benchmark, and demo fixtures remain German.
Do not translate language fixtures merely to make the source tree look uniform.

## Before changing code

Read `AGENTS.md`, `ARCHITECTURE.md`, and `docs/PLAN-IOS.md`.
The recording is Steno's only irreplaceable artifact, originals are immutable, and recording must remain independent from transcription and post-processing failures.

Both Xcode projects are generated from `project.yml` and are ignored by Git.
Run XcodeGen after switching branches, merging, or rebasing.

## Verification

Run focused tests while iterating.
For lasting changes to the shared core, run all four suites documented in `AGENTS.md` before submitting the change.

Use disposable `STENO_LIBRARY_DIR` and `STENO_MODEL_DIR` locations for tests that must not touch an existing Steno installation.
Never use real recordings, transcripts, participant data, or credentials in tests, screenshots, issues, or pull requests.

## Reporting problems

Public bug reports should include the device, OS version, Steno commit, reproduction steps, and whether recording or only post-processing is affected.
Prefer the bundled synthetic demo meetings or a minimal generated fixture.

Report suspected security vulnerabilities privately by following `SECURITY.md`.
