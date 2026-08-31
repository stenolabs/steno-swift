# Native Gemma service

`GemmaService` is the isolated macOS 27 build boundary for exposing a local Gemma 4 model through Apple's Foundation Models `LanguageModel` API while MLX performs checkpoint loading and inference.

Apple's Foundation Models framework does not load external Gemma checkpoints.
The `MLXFoundationModels` adapter provides API compatibility with `LanguageModelSession`; it does not turn Gemma into Apple's `SystemLanguageModel` or make Apple responsible for the model runtime.

It is intentionally a separate Swift package.
The MLX runtime package is not a dependency of `StenoKit`, either supported Xcode 26 application target, or the Xcode 27 application process.
Only the embedded Xcode 27 XPC helper links the MLX runtime.
This keeps MLX and Metal out of the process that owns an irreplaceable recording and leaves the supported Xcode 26 build unchanged.

## Current status

This first slice provides:

- a macOS 27 executable process;
- an exact source pin for the unreleased MLX `LanguageModel` adapter and a minimal vendored adapter subtree at that revision;
- complete manifest verification of a local checkpoint at each verification instant;
- a model-free self-check;
- a model-free adapter seam that can adopt a prebuilt local `ModelContainer` through an immutable `ModelDescriptor`;
- a one-shot byte-backed Gemma 4 loader that constructs that container only after strict configuration, tokenizer, Safetensors, quantization, parameter-set, preparation, and checked-evaluation validation; and
- tests that do not download or execute model weights;
- a dependency-free strict-concurrency IPC module with a closed, size-bounded request and response schema;
- a fail-closed XPC service core whose process runtime atomically binds at most one exact model executor before handling requests, with lifecycle operations owned by the process-wide registry;
- a separate Xcode 27 project variant that embeds and code-signs the XPC helper with App Sandbox enabled and incoming and outgoing network access disabled; and
- mutual designated-requirement, dynamic-code, canonical-path, request-ID, and channel validation between the signed app and helper;
- a bounded client request lifecycle with cancellable deadlines and no eager helper launch or reconnect;
- two-phase transport initialization that verifies the model asynchronously before any process-gate acquisition and atomically rejects late capabilities after recording preemption;
- a process-wide server request registry with unique active request IDs, targeted cancellation outside the model actor, one inference-like task at a time, and prepare/arm quiescence only after tasks return and replies finish;
- one app-process-wide recording coordinator that closes native Gemma admission before the first recording permission await and retains the lease through capture cleanup;
- an exact-process exit protocol in which the authenticated helper arms itself, the client closes that exact connection without another message, and recording proceeds only after the observed helper PID exits; and
- a global crash-releasing recording and model gate, with the execution-gate and verified model-root descriptors atomically bound in the first XPC control frame;
- a session-scoped client with automatic terminal retirement; and
- a consent chokepoint with one-shot, pin-bound, source-inode-bound confirmations and an empty production checkpoint catalog;
- an MLX-free importer that copies only a fully pinned local manifest into a content-addressed Steno-controlled store, publishes without replacement, and returns path-free provenance;
- descriptor-bound source and installed-tree verification with exact ownership, mode, hard-link, entry, size, checksum, and root-inode checks; and
- an app-side resolver that opens only one exact app-approved installed digest as a verified descriptor-owned capability, without discovery, hierarchy creation, repair, or path return;
- helper-side exact-profile activation with fixed memory and prompt limits, byte-backed MLX materialization, one shared tokenizer and input processor for counting and generation, and a fresh `LanguageModelSession` for every generation request; and
- an inactive app-side native `TextModelProvider` that keeps one exact helper session across a complete template render and uses one strict JSON prompt contract for both counting and generation; and
- signed positive XPC integration and app tests that verify fail-closed inference, exact helper absence within the owning app process before a recording lease, failure before permission UI, permission-denial release, and concurrent first-use initialization; and
- an arm64 Release policy that enables Hardened Runtime for the app and helper, grants the app only microphone and calendar resource entitlements, suppresses injected debug entitlements, rejects unsafe code-signing profiles, and passes strict nested-signature and helper-entitlement inspection.

It does not yet provide:

- an app setting, an approved production checkpoint catalog, or a user-facing import flow;
- automatic checkpoint downloads;
- user-selectable or production-approved native Gemma report generation from the Steno app;
- end-to-end Release recording, system-audio, and calendar validation under Hardened Runtime;
- negative signed abuse and multiprocess XPC integration coverage;
- an approved production activation profile and app-facing provider selection;
- a real model run; or
- a production support commitment for any specific converted checkpoint.

The standalone SwiftPM package contains the verified local model-loading path, and the Xcode 27 variant links that runtime only into the XPC helper.
The helper has no incoming or outgoing network entitlement in that project variant, while the application process remains MLX-free.
The pinned tokenizer and MLX dependency graph still contributes dormant Hub and URL-session code to the helper binary, but Steno's activation path never calls it and App Sandbox denies network access because the helper has no network entitlement.
The independent production checkpoint, app-provider, and helper-activation catalogs are deliberately empty, so no checkpoint can currently create an executor and native Gemma remains unavailable for user selection.
A standalone SwiftPM executable has no operating-system network sandbox, so source-level absence of a download path must not be described as a hard network guarantee.

The standalone command-line factory is isolated in a package-only prototype target that is not linked into the XPC helper.
The production-intended loader instead consumes one-shot activation bytes and constructs the path-free adapter around a prebuilt `ModelContainer` before final descriptor-rooted revalidation publishes it.
That loader is wired into the helper only behind an exact helper-controlled activation profile.
An unapproved pin is verified, closed without retaining a filesystem capability, and kept model-free.

Store mutation and native Gemma execution share byte 1 of the same crash-releasing gate exclusively, while recording intent uses byte 0.
The importer verifies the source before store access, acquires a mutation lease before touching `Models/v1`, observes recording intent at bounded checkpoints, removes its own staging tree before a namespace commit, and closes the lease before its final non-cancellable verification after no-replace publication.
The store root and gate-file path come from the same gate configuration.
Each store hierarchy parent is synchronized even on an idempotent retry, so a later authorized import can complete namespace durability after an earlier crash.
The app-level coordinator still drains the exact active import task before it grants the recording lease.

## Accepted crash-recovery design

Native Gemma crash recovery is an explicit, manually invoked engine.
It is not startup or UI wiring, does not auto-publish, and does not run a model.

Recovery uses monotone v2 owner, bound, and prepared documents that are write-once after their initial durable record.
The owner document is durable before staging begins.
The bound document records the exact root identity before any staging contents are created.
The complete manifest is durable in staging before any other model path is created.
All model files are pre-created as empty regular files, and the prepared canonical inode ledger is durable before any payload is written.

Recovery uses byte 1 of the same mutation lease and byte 0 recording intent.
All inspection and mutation is descriptor-based, uses no-follow operations, and checks ownership, modes, and inode identity before cleanup.
Cleanup uses a deterministic no-replace rename, synchronizes the parent directory, removes only the resulting descriptor-bound tree, and synchronizes the parent again.
Old v1 entries, malformed v2 documents, and suspicious entries are retained and reported.
Published targets named by 64 lowercase hexadecimal characters are never deleted.
A valid committed target is only synchronized and verified.
A corrupt published target is retained and reported separately from any future user-authorized repair.

## Model boundary

The production-intended loader never accepts a Hub model identifier or filesystem URL as a loading source.
It gives the MLX adapter a cache identity derived from the pinned manifest, consumes the configuration, tokenizer, and weights only from descriptor-rooted activation bytes, and defines no remote fallback in Steno's loading code.

Before the directory can be used, every regular file must appear in a manifest with its exact byte count and SHA-256 digest.
The verifier rejects traversal paths, hidden components, non-ASCII paths, case or normalization collisions, absolute paths, a symbolic-link root, symbolic-link entries inside the snapshot, missing files, unexpected files, duplicate entries, hard-linked installed files, wrong ownership or modes, size differences, hash differences, and an unpinned or mismatched manifest.
It also rejects safetensors indexes whose shard paths escape the snapshot or refer to files absent from the manifest.
The verifier holds directory descriptors, opens descendants with `openat` and `O_NOFOLLOW`, compares metadata before and after reads, and binds the verified capability to the root device and inode.
The standalone command-line prototype repeats that complete path-backed check immediately before its prototype MLX loading path, but this does not make previously checked child files immutable against another process running as the same user.
The one-shot activation boundary now retains the exact manifest-listed child files, copies non-shard files into immutable `Data`, and exposes shard bytes only through a synchronous consume operation with full-hash revalidation.
The strict Safetensors parser validates every complete verified shard before the trusted activation callback and exposes immutable metadata and tensor descriptors.
The byte-backed loader rejects duplicate JSON keys, correlates MLX's decoded tensor names, metadata, dtypes, and shapes with that parser, evaluates every shard before its bytes expire, rejects raw and sanitized collisions and sanitizer-unsafe MoE shapes, validates quantization before MLX, requires compatible parameter dtypes and an exact sanitized model weight set, and publishes no adapter until preparation, checked evaluation, cancellation checks, and final activation revalidation succeed.
The client completes the helper's authenticated bind under a distinct activation deadline before starting the first ordinary request deadline.
An activation failure faults model use until a later recording cycle independently proves helper absence through the process gate, which prevents immediate helper relaunch loops.
The importer writes through retained descriptors into a private sibling staging directory, synchronizes files and directories, sets files to `0400` and directories to `0500`, and publishes to `~/Library/Application Support/Steno/NativeGemma/Models/v1/<manifest-sha256>` with a no-replace rename.
Those modes prevent accidental changes and expose tampering, but they are not a security boundary against another process running as the same macOS user.
The complete import and recovery contract is documented in [Native Gemma model store](../docs/NATIVE-GEMMA-MODEL-STORE.md).

The manifest records model provenance and license metadata, but recording those strings is not a license review.
Steno does not include or distribute Gemma weights in this repository.
Google's official Gemma 4 model card labeled Gemma 4 as Apache-2.0 when checked on 2026-08-30, while the referenced MLX community instruction checkpoint labeled itself `gemma` on the same date.
Do not add a checkpoint to a Steno installation catalog until its exact source, conversion, revision, notices, and redistribution terms have been reviewed.

- [Official Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4)
- [Current MLX community E4B instruction checkpoint](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit)

## Build

Use Xcode 27 or later and install its Metal Toolchain component.

The exact MLX dependency snapshot builds with Xcode 27 Beta 6 after its matching Metal Toolchain component is installed.
The full package passes 37 tests with one intentional Metal opt-in sentinel skipped, without downloading or loading a checkpoint.
Keep the dependency revisions exact and do not replace them with floating versions.

```bash
swift test --package-path GemmaService
```

The model-free IPC and client packages are independently buildable and testable with Xcode 27:

```bash
swift test --package-path GemmaService/IPC
swift test --package-path GemmaService/Client
```

If Xcode 27 is not the active developer directory, prefix the command with `DEVELOPER_DIR` pointing to that installation.

Generate the separate Xcode 27 project variant and run the XPC integration test with:

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
The command applies the installed-store contract: the root and nested directories must be owner-only `0500`, regular files must be owner-only `0400`, and the tree must contain no hidden or unlisted entries.

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

The remaining production work is to review and add one exact checkpoint and matching resource profile to all three currently empty production catalogs, expose the consented import and provider-selection flows, add an explicit user-authorized repair flow for retained corrupt targets, complete end-to-end Release recording and calendar validation under Hardened Runtime, and complete a resource-measured real offline model run.
Negative signed abuse and multiprocess XPC coverage must be complete before native Gemma is activated.
The normative design for that boundary is [Native Gemma cross-process gate](../docs/NATIVE-GEMMA-GATE.md).
Approved manifests and expected digests must live in Steno-controlled metadata, and installation must route through `ModelInstallationCoordinator` with explicit consent.
The provider must remain unavailable in the app until those conditions, the exact checkpoint licensing, and the associated recovery behavior are accepted.
