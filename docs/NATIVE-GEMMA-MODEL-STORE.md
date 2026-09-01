# Native Gemma model store

Status: the model store and app-side text-model provider are implemented as inactive MLX-free app boundaries, and the byte-backed runtime is connected only inside the helper, as of 31 August 2026.

The independent production checkpoint, app-provider, and helper-activation catalogs are empty, no import or provider UI is exposed, no model is downloaded, and no imported model is activated.
This document defines the boundary that must remain intact when a reviewed checkpoint and UI are added later.

## Authorization boundary

`ModelInstallationCoordinator` owns authorization and the importer does not interpret consent itself.
The production catalog cannot be injected by application clients, and the concrete low-level importer is exposed to the app adapter only through a named `StenoApp` SPI so bypasses are explicit in code review.

The coordinator requires the existing explicit model consent, requires the complete model pin to exist in the fixed application catalog, opens the selected source directory with `O_DIRECTORY | O_NOFOLLOW`, and records its device and inode.
It then mints a process-local, non-Codable confirmation containing only an opaque nonce in its public API.

Starting an import atomically consumes the nonce before delegation, rechecks the catalog and source identity, and consumes the confirmation even if import later fails or is cancelled.
`cancelAll()` invalidates every pending confirmation, excludes new native confirmations while cancellation is running, cancels the exact in-flight task, and waits for that task's descriptor-safe cleanup to finish.

The model pin includes the model identifier, an exact 40-character lowercase hexadecimal checkpoint revision, the exact adapter revision, the license identifier, and the SHA-256 digest of the exact manifest bytes.
The coordinator rejects any returned provenance that differs from that pin.

## Source contract

The source is an already-materialized local directory, not a Hub identifier or download request.
The importer retains the approved root descriptor and rejects a changed root, a root owned by another user, symlinks, special files, missing entries, unexpected entries, changed entries, unsafe paths, size mismatches, checksum mismatches, and a manifest whose identity or license differs from the approved pin.

All source descendants are opened relative to retained directory descriptors with `openat` and `O_NOFOLLOW`.
The importer compares device, inode, type, owner, size, modification time, and change time before and after each read and checks the exact directory listing again before publication.

Source files may have normal user-controlled modes and may have other hard links because the copied bytes are hashed and the installed copy receives a new inode.
The selected directory must contain exactly the manifest and its listed files.
Finder metadata, AppleDouble files, `.gitattributes`, and every other hidden or unlisted entry are rejected rather than silently ignored.
Hugging Face cache snapshots commonly use symlinks and hidden metadata and must therefore be materialized into an exact regular-file directory before they can be selected.

## Store and publication contract

The production root is shared with the native Gemma process gate and is derived component by component without following links:

```text
~/Library/Application Support/Steno/NativeGemma
```

Calling `NativeGemmaModelStoreConfiguration.production` performs no filesystem action.
The shared root may already exist because the native Gemma process gate uses it independently of model consent.
The same gate configuration is the source of truth for both this store root and the stable gate file, so store mutation and model execution coordinate through the exact same byte ranges.
The `Models/v1` descendants are opened or created only after the coordinator has consumed a valid confirmation.
Installed-model resolution is separate from import and never creates that hierarchy.
It accepts one complete app-approved pin, opens only the exact digest leaf with no-follow descriptor operations, rechecks the store-parent identity, and transfers descriptor ownership directly into complete verification.
A missing hierarchy or digest and a corrupt installed snapshot are distinct fail-closed outcomes; resolution performs no discovery, repair, deletion, or path return.

The final model location is content-addressed by the pinned manifest digest:

```text
~/Library/Application Support/Steno/NativeGemma/Models/v1/<manifest-sha256>
```

The importer performs blocking filesystem work on a dedicated utility queue, creates a private `0700` sibling staging directory, copies only the manifest and its listed regular files in bounded chunks, verifies each chunk stream against the pinned size and SHA-256 digest, and checks an explicit cancellation signal throughout pre-publication copying and verification.
Each destination file is created exclusively as `0600`, synchronized, and changed to `0400` before close.
Directories are synchronized bottom-up, changed to `0500`, and synchronized again.
The store root and `Models` directory are synchronized while opening each hierarchy component, even when that component already exists, so an idempotent retry can complete namespace durability missed by an earlier crash.

The complete staging tree is then verified through retained descriptors and bound to its device and inode.
Only after source verification does the importer acquire a mutation lease that holds byte 1 exclusively, while observing the recording-intent lock on byte 0 at bounded checkpoints.
The importer rechecks the store-parent identity and publishes with `renameatx_np` using `RENAME_EXCL`, `RENAME_NOFOLLOW_ANY`, and `RENAME_RESOLVE_BENEATH`.
It synchronizes the parent namespace after publication, closes the mutation lease, and then performs the final full verification bound to the same root inode without honoring further cancellation.

An existing valid destination is idempotent and is never replaced.
That retry revalidates the approved source and installed snapshot, rechecks the store-parent identity, synchronizes the installed destination's parent namespace, and releases the mutation lease before returning the existing inode-bound capability.
An existing invalid destination produces a distinct fail-closed error and is retained unchanged for a future explicitly authorized repair flow.

## Failure and cleanup contract

Cancellation and source failures remove only the staging tree created by that exact importer invocation.
The importer validates the complete staging listing and every created inode, quarantines the root with a no-replace sibling rename, and removes only recorded files and directories with `unlinkat`.

Cancellation is honored through the last check immediately before the no-replace rename.
The rename is the logical namespace commit point: after it succeeds, Steno ignores cancellation, attempts synchronization, and fully verifies the installed snapshot before returning its provenance.
It does not report a cancellation that would falsely imply that the installed model vanished.

If the staging name, inode, or contents differ from the importer's records, cleanup stops and reports an orphan instead of recursively deleting an uncertain tree.
A cleanup failure deliberately supersedes the original import error because the retained uncertain tree is the immediate recovery condition that must be surfaced.
A crash can also leave a uniquely named staging directory because no process remains to run cleanup.
Automatic orphan sweeping is intentionally deferred until it has its own ownership, lock, age, capacity, and user-recovery contract.

Before the namespace commit, every failure path removes only the importer's own staging tree.
After a successful no-replace publish, the destination is retained and the importer completes synchronization and verification even if cancellation was requested.

Crash durability remains unconfirmed until parent synchronization succeeds.
If parent synchronization or final verification fails after that rename, the import returns an error even though the destination may exist.
The failed result must never activate the model; a later explicitly authorized retry revalidates the same content-addressed destination idempotently.

Read-only owner modes protect against accidental modification and provide a cheap tamper signal.
They are not a cryptographic or sandbox boundary against another process running as the same macOS user, which can change owner modes.
The implemented store integrity controls are exact pins, retained root descriptors, no-follow opens, content hashing, no-replace publication, helper sandboxing, and descriptor-rooted verification at each explicit verification instant.
A retained root descriptor does not freeze later child-file mutations by another process running as the same user.
The model store now turns a consumed verified root into one-shot activation assets that retain safetensors descriptors and copy non-shard files into immutable `Data`.
It fully hashes every manifest-listed file while creating the activation assets.
For safetensors, the later synchronous consume operation makes one complete `Data` copy per shard with `pread` and verifies the full hash again before its consumer receives the bytes.
Thus, “one copy” does not mean “one read” or “one hash pass.”
The capability exposes neither filesystem paths nor raw file-descriptor numbers, dynamically expires every borrowed view, revalidates every binding after the consumer returns, and closes all descriptors on success, error, cancellation, or explicit close.
An explicit close during `consume` marks the capability closed immediately, makes the next close-aware copy or verification checkpoint fail, and defers descriptor closure until the synchronous consume callback has returned.
The size limits bound the verified source bytes handed to the trusted consumer, not allocations that the consumer or MLX may derive from them, and their fit for a checkpoint remains unknown until an exact reviewed checkpoint is selected.
The trusted runtime publishes only the value returned by a successful activation consume operation and does not publish callback side effects before final revalidation.
MLX materialization is implemented only through this byte boundary and is wired into the XPC helper behind an exact helper-controlled activation profile.
Because the production activation catalog is empty, no installed pin can currently instantiate that runtime.
The whole-shard `Data` bridge has caller-provided bounds and is consumed synchronously by the inactive loader.
Whether those bounds fit a checkpoint remains unknown until an exact reviewed checkpoint is selected.
Every complete verified shard is strictly parsed before the trusted callback receives it.
The callback receives immutable metadata and tensor descriptors, and duplicate raw tensor names across shards fail closed before the duplicate shard is delivered.

## Resource-bounded MLX activation contract

The pinned public MLX API can load a complete safetensors shard from `Data`, so production may use that path only when an exact reviewed checkpoint fits explicit per-shard and aggregate activation limits and its peak memory has been measured on supported hardware.
Those limits belong to reviewed Steno-controlled configuration and must never rise automatically in response to model input.

Within the synchronous activation callback, Steno compares MLX's loaded tensor names, metadata, dtypes, and shapes with the strict parser result, materializes every returned array with checked evaluation before the shard bytes leave scope, and rejects raw-name or sanitized-name collisions.
It rejects duplicate JSON keys and sanitizer-unsafe MoE tensor shapes, validates every quantization declaration before invoking MLX, checks applicable group sizes against the constructed layer dimensions, and requires compatible parameter dtypes and a sanitized weight set that exactly equals the model-generated parameter set before structural decoding or update.
No model container is published until all shards, model updates, preparation, evaluation, cancellation checks, and the final descriptor-rooted activation revalidation succeed.
Asynchronous MLX evaluation is not permitted across this trust boundary.
The exact tokenizer and input processor returned by activation perform both prompt counting and generation preparation.
Each generation request uses a fresh Foundation Models `LanguageModelSession`, and the helper rejects prompts above the fixed profile limit before generation.

Small configuration and tokenizer inputs come from the already copied activation data.
The loader must not enumerate or reopen weight paths, and availability must use the stored verified-container predicate instead of a fabricated filesystem URL.

If the largest shard of the selected checkpoint does not fit the reviewed memory cap, Steno must not silently raise the cap.
The alternatives are a deterministic tensor-preserving re-shard during consented import with explicit source and derivation provenance in a later manifest version, or a separately reviewed authenticated reader exposed through a public MLX API.
That choice remains open because no production checkpoint has been selected or measured.

Steno must not redeclare or dynamically resolve private `Cmlx` symbols, depend on checkout-internal header paths, expose lazy custom-reader arrays, or use a temporary named clone as the integrity boundary.
No dependency fork or upstream change has been published.
The production helper remains model-free in practice because its activation catalog contains no approved pin, even though the authenticated helper now contains the reviewed byte-backed activation path.

## Activation boundary

The Xcode 27 app links the MLX-free store adapter, while the normal Xcode 26 application remains unchanged.
The adapter maps only a coordinator-approved pin and source identity into store requirements and maps only verified fields back into `NativeGemmaModelSnapshot`.
One app facade now acquires import admission from the same process-wide coordinator used by recording before it mints and consumes the coordinator confirmation or invokes the adapter.
The app's installed-model resolver separately requires the exact pin in the fixed app checkpoint catalog before it opens the existing digest leaf as a verified descriptor-owned capability.

Neither the coordinator, adapter, nor store can download a model, launch the helper, create an MLX runtime, select Ollama, select `SystemLanguageModel`, or fall back to another provider.
Model import now joins both the app-process recording coordinator and the global crash-releasing process gate.
Publishing recording intent in the same app process atomically excludes new imports, requests cancellation of the exact active import, and awaits that task's full quiescence, including uncancellable post-publication synchronization and verification, before the existing helper gate is acquired and before recording permission or capture is requested.
Across app processes, store mutation and model execution hold byte 1 exclusively, while recording holds it shared only after its byte 0 transition has excluded new exclusive admission.
An import that observes remote recording intent before publication reports explicit preemption and completes owned staging cleanup before releasing the mutation lease.
If intent arrives after the final pre-publication check, the recorder waits for the no-replace commit and parent synchronization to release byte 1, while the importer's final read-only verification may continue without blocking that remote recording lease.
Ordinary import failure is intentionally ignored by recording admission after the task is quiescent, because a model-store failure must not endanger audio capture.
The safe availability trade-off is explicit: an operating-system I/O operation that never returns also prevents recording admission because proceeding without proof of import quiescence would violate the exclusion contract.
That condition lasts for the remaining app-process lifetime, keeps the recording start state occupied, and currently requires restarting Steno before recording can be attempted again.
A follow-up user-facing path must explain the blocked state and offer a safe restart, but it must never turn a timeout or cancellation request into permission to begin capture while import quiescence remains unproven.
The user-facing import path must use the app facade rather than making the internal adapter a general app service.
The sandboxed helper cannot reopen the user store by path.
The authenticated XPC bind now transfers a verified model-directory descriptor together with the execution-gate descriptor.
The helper revalidates the tree from that retained descriptor at bind time and preserves the pinned root identity and exact model pin for the session.
The one-shot child-file activation boundary now retains exact shard descriptors and immutable non-shard bytes for a trusted consumer and strictly parses every verified shard before delivery.
For an exact helper-approved profile, the loader performs complete byte-backed MLX materialization inside that one-shot callback and constructs a stored, path-free adapter only after the activation capability's final revalidation.
The helper binds that executor atomically before acknowledging the session, checks recording intent around activation, and closes an unapproved model capability without publishing an executor.
The app completes the authenticated helper bind under a distinct 600-second activation deadline before it starts the first ordinary request deadline.
An activation or pre-bind connection failure faults model use until a later recording cycle independently proves helper absence through the process gate, rather than immediately relaunching the helper.
The app-side native `TextModelProvider` requires the same snapshot in an independent fixed resource-profile catalog and keeps one closure-scoped helper model session across a complete template render.
Every token count and generation request uses the same shared prompt assembly, generated output must decode as the exact strict JSON contract, and the session is retired before the render returns or throws.
This provider has no Ollama, network, or `SystemLanguageModel` fallback.
The exact MLX dependency snapshot builds with Xcode 27 Beta 6 and its matching Metal Toolchain component without loading a model.
Provider activation remains unavailable until one reviewed production checkpoint and matching limits are present in all three independent catalogs, user-facing consent and import flow, explicit recovery for retained corrupt installs or crash-orphaned staging, end-to-end Release recording and calendar validation under Hardened Runtime, app-facing provider selection, and a real offline model run are accepted.
