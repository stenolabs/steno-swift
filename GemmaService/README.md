# Native Gemma service

`GemmaService` is the isolated macOS 27 build boundary for exposing a local Gemma 4 model through Apple's Foundation Models `LanguageModel` API while MLX performs checkpoint loading and inference.

Apple's Foundation Models framework does not load external Gemma checkpoints.
The `MLXFoundationModels` adapter provides API compatibility with `LanguageModelSession`; it does not turn Gemma into Apple's `SystemLanguageModel` or make Apple responsible for the model runtime.

It is intentionally a separate Swift package.
The MLX runtime package is not a dependency of `StenoKit`, either supported Xcode 26 application target, or the model-free Xcode 27 application target.
The Xcode 27 application target links only the dependency-free IPC client and embeds the model-free helper.
This keeps MLX and Metal out of the process that owns an irreplaceable recording and leaves the supported Xcode 26 build unchanged.

## Current status

This first slice provides:

- a macOS 27 executable process;
- an exact source pin for the unreleased MLX `LanguageModel` adapter;
- complete manifest verification of a local checkpoint at each verification instant;
- a model-free self-check;
- construction of an `MLXLanguageModel` backed only by the verified local directory; and
- tests that do not download or execute model weights;
- a dependency-free strict-concurrency IPC module with a closed, size-bounded request and response schema;
- a model-free, fail-closed XPC service core that handles handshake while rejecting token counting and generation as unavailable, with lifecycle operations owned by the process-wide registry;
- a separate Xcode 27 project variant that embeds and code-signs the XPC helper with App Sandbox enabled and incoming and outgoing network access disabled; and
- mutual designated-requirement, dynamic-code, canonical-path, request-ID, and channel validation between the signed app and helper;
- a bounded client request lifecycle with cancellable deadlines and no eager helper launch or reconnect;
- a process-wide server request registry with unique active request IDs, targeted cancellation outside the model actor, one inference-like task at a time, and prepare/arm quiescence only after tasks return and replies finish;
- one app-process-wide recording coordinator that closes native Gemma admission before the first recording permission await and retains the lease through capture cleanup;
- an exact-process exit protocol in which the authenticated helper arms itself, the client closes that exact connection without another message, and recording proceeds only after the observed helper PID exits; and
- a global crash-releasing recording and model gate, with the file descriptor bound in the first XPC control frame;
- a session-scoped client with automatic terminal retirement; and
- signed positive XPC integration and app tests that verify fail-closed inference, exact helper absence within the owning app process before a recording lease, failure before permission UI, permission-denial release, and concurrent first-use initialization.

It does not yet provide:

- an app setting or production model installer or importer and store;
- automatic checkpoint downloads;
- report generation from the Steno app;
- Hardened Runtime validation for the production app and a Release-specific entitlement policy;
- negative signed abuse and multiprocess XPC integration coverage;
- activation of the MLX provider through the XPC helper;
- a real model run; or
- a production support commitment for any specific converted checkpoint.

The standalone SwiftPM package contains the verified local model-loading path, while the Xcode 27 variant currently exercises only the model-free XPC boundary.
The helper has no incoming or outgoing network entitlement in that project variant, and the app-facing provider remains deliberately unavailable.
The verified model runtime is not yet activated through the helper, and the app does not expose this provider.
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

The current exact `mlx-swift-lm` source pin still resolves a transitive MLX Metal header that Xcode 27 Beta 6 rejects.
Therefore the full runtime package is not currently a green Xcode 27 build.
Do not activate the runtime or replace the pin with a floating dependency.
A matched and reviewed MLX, MLX-C, and `mlx-swift-lm` snapshot is required first.

```bash
swift test --package-path GemmaService
```

The model-free IPC and client packages are independently buildable and testable with Xcode 27:

```bash
swift test --package-path GemmaService/IPC
swift test --package-path GemmaService/Client
```

If Xcode 27 is not the active developer directory, prefix the command with `DEVELOPER_DIR` pointing to that installation.

Generate the separate Xcode 27 project variant and run the model-free XPC integration test with:

```bash
xcodegen generate --spec project-xcode27.yml
xcodebuild -project Steno27.xcodeproj -scheme Steno27 \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:StenoTests/StenoGemmaXPCIntegrationTests test
```

The generated `Steno27.xcodeproj` is ignored and must not be committed.

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

## Remaining production work

The remaining production work is to validate Hardened Runtime and the Release entitlement policy, implement the consented immutable model importer and store, select a buildable matched MLX dependency snapshot, activate the MLX provider through the helper, and complete a real model run.
Negative signed abuse and multiprocess XPC coverage must be complete before native Gemma is activated.
The normative design for that boundary is [Native Gemma cross-process gate](../docs/NATIVE-GEMMA-GATE.md).
Approved manifests and expected digests must live in Steno-controlled metadata, and installation must route through `ModelInstallationCoordinator` with explicit consent.
The provider must remain unavailable in the app until those conditions, the exact checkpoint licensing, and the associated recovery behavior are accepted.
