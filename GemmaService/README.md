# Native Gemma service

`GemmaService` is the isolated macOS 27 build boundary for exposing a local Gemma 4 model through Apple's Foundation Models `LanguageModel` API while MLX performs checkpoint loading and inference.

Apple's Foundation Models framework does not load external Gemma checkpoints.
The `MLXFoundationModels` adapter provides API compatibility with `LanguageModelSession`; it does not turn Gemma into Apple's `SystemLanguageModel` or make Apple responsible for the model runtime.

It is intentionally a separate Swift package.
The package is not a dependency of `StenoKit`, the macOS app target, or the iOS app target.
This keeps the experimental MLX and Metal runtime out of the process that owns an irreplaceable recording and leaves the supported Xcode 26 build unchanged.

## Current status

This first slice provides:

- a macOS 27 executable process;
- an exact source pin for the unreleased MLX `LanguageModel` adapter;
- complete manifest verification of a local checkpoint at each verification instant;
- a model-free self-check;
- construction of an `MLXLanguageModel` backed only by the verified local directory; and
- tests that do not download or execute model weights.

It does not yet provide:

- an app setting or model installer;
- automatic checkpoint downloads;
- report generation from the Steno app;
- a signed and embedded App Sandbox helper; or
- a production support commitment for any specific converted checkpoint.

The executable currently proves the local loading path and rejects unmanifested model input.
Production app integration must embed it as a signed helper without outgoing or incoming network entitlements before Steno sends meeting text to it.
A standalone SwiftPM executable has no operating-system network sandbox, so source-level absence of a download path must not be described as a hard network guarantee.

## Model boundary

The service never accepts a Hub model identifier as a loading source.
It gives the MLX adapter a cache identity derived from the pinned manifest, resolves model weights and the tokenizer from the verified directory, and defines no remote fallback in Steno's loading code.

Before the directory can be used, every regular file must appear in a manifest with its exact byte count and SHA-256 digest.
The verifier rejects traversal paths, absolute paths, a symbolic-link root, symbolic-link entries inside the snapshot, missing files, unexpected files, duplicate entries, size differences, hash differences, and an unpinned or mismatched manifest.
It also rejects safetensors indexes whose shard paths escape the snapshot or refer to files absent from the manifest.
The factory revalidates the directory immediately before MLX loads it.
This path-based revalidation narrows but cannot eliminate a time-of-check-to-time-of-use window if another process can mutate the directory concurrently.
A production installer must therefore place the verified snapshot in a Steno-controlled location whose sandbox permissions prevent untrusted mutation while the helper can access it.

The manifest records model provenance and license metadata, but recording those strings is not a license review.
Steno does not include or distribute Gemma weights in this repository.
Google's official Gemma 4 model card labeled Gemma 4 as Apache-2.0 when checked on 2026-08-30, while the referenced MLX community instruction checkpoint labeled itself `gemma` on the same date.
Do not add a checkpoint to a Steno installation catalog until its exact source, conversion, revision, notices, and redistribution terms have been reviewed.

- [Official Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4)
- [Current MLX community E4B instruction checkpoint](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit)

## Build

Use Xcode 27 or later and install its Metal Toolchain component.

```bash
swift test --package-path GemmaService
```

If Xcode 27 is not the active developer directory, prefix the command with `DEVELOPER_DIR` pointing to that installation.

The package pins `mlx-swift-lm` to commit `37688d2cf7d3906e08c74479c9d9949ce6b81136` because the required Foundation Models adapter is not consumed through a released version here.
Do not replace the revision with a branch or floating version.

Run the model-free executable check with:

```bash
swift run --package-path GemmaService steno-gemma-service --self-check
```

Model verification requires a local checkpoint directory, its pinned identity and license metadata, and the SHA-256 digest of the exact manifest bytes.
No model is loaded during verification.

```bash
swift run --package-path GemmaService steno-gemma-service \
  --verify-model /path/to/checkpoint \
  --model-identifier REVIEWED_MODEL_IDENTIFIER \
  --checkpoint-revision REVIEWED_CHECKPOINT_REVISION \
  --license-identifier REVIEWED_LICENSE_IDENTIFIER \
  --manifest-sha256 EXPECTED_MANIFEST_SHA256
```

The expected manifest digest belongs in a reviewed model catalog or another trusted caller-owned configuration.
It must not be read from the same untrusted checkpoint directory it is meant to authenticate.

## Next production slice

App integration requires all of the following together:

1. Ship the executable as a signed App Sandbox helper with no network client or server entitlement.
2. Define a narrow request and response protocol that contains report text but never audio, library paths, API keys, or unrelated meeting data.
3. Store approved manifests and expected digests in Steno-controlled metadata, copy verified snapshots into an immutable Steno-controlled location, and route installation through `ModelInstallationCoordinator` with explicit consent.
4. Stop or unload the helper before a recording starts, and treat helper failure as a report failure that cannot affect capture.
5. Add the provider to persisted selection and provenance only after compatibility, checkpoint licensing, and recovery behavior are accepted.

Until those conditions are met, this package remains an isolated integration boundary and is not exposed in the app.
