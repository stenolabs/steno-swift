# Native Gemma model store

Status: implemented as an inactive MLX-free boundary on 31 August 2026.

The production checkpoint catalog is empty, no import UI is exposed, no model is downloaded, and no imported model is activated.
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
The `Models/v1` descendants are opened or created only after the coordinator has consumed a valid confirmation.

The final model location is content-addressed by the pinned manifest digest:

```text
~/Library/Application Support/Steno/NativeGemma/Models/v1/<manifest-sha256>
```

The importer performs blocking filesystem work on a dedicated utility queue, creates a private `0700` sibling staging directory, copies only the manifest and its listed regular files in bounded chunks, verifies each chunk stream against the pinned size and SHA-256 digest, and checks an explicit cancellation signal throughout pre-publication copying and verification.
Each destination file is created exclusively as `0600`, synchronized, and changed to `0400` before close.
Directories are synchronized bottom-up, changed to `0500`, and synchronized again.

The complete staging tree is then verified through retained descriptors and bound to its device and inode.
The importer rechecks the store-parent identity and publishes with `renameatx_np` using `RENAME_EXCL`, `RENAME_NOFOLLOW_ANY`, and `RENAME_RESOLVE_BENEATH`.
It synchronizes the parent and performs a final full verification bound to the same root inode before returning path-free provenance.

An existing valid destination is idempotent and is never replaced.
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
The size limits bound the verified source bytes handed to the trusted consumer, not allocations that the consumer or MLX may derive from them.
The trusted runtime must publish only the value returned by a successful activation consume operation and must not publish callback side effects before final revalidation.
MLX materialization remains separate work and must not bypass this byte boundary.
A whole-shard `Data` bridge is deliberately not wired into production because available compact checkpoints still contain multi-gigabyte shards; production activation needs either smaller approved shards or a reviewed chunk-authenticated MLX reader with bounded scratch memory.

## Resource-bounded MLX activation contract

The next manifest format must authenticate every safetensors file with both its existing full-file SHA-256 digest and an exact ordered list of fixed-size chunk SHA-256 digests.
The chunk size is a Steno code constant rather than model-controlled input, and validation derives the exact chunk count and final-chunk length from the pinned file size.
The pinned manifest digest authenticates the complete chunk table.

The runtime reader must remain path-free and descriptor-backed.
Every random-access callback validates arithmetic and bounds, clears the entire requested destination first, reads complete chunks with `pread` and `EINTR` handling into bounded private scratch memory, authenticates each complete chunk before copying requested bytes, and records the first failure in a permanent thread-safe state.
After that first failure every callback continues to return only zero-filled output.
Scratch slots and concurrent reads must have explicit limits no greater than the pinned MLX I/O concurrency.

The pinned MLX implementation creates lazy arrays and its C callback cannot throw.
Steno must therefore synchronously materialize every returned array, inspect both MLX evaluation errors and the reader's permanent failure state, and publish no model container until those checks and the final descriptor-rooted activation revalidation succeed.
The reader owner and retained descriptors remain alive until materialization has finished and MLX has released its callback owner.
Asynchronous evaluation is not permitted across this trust boundary.

The pinned `mlx-swift` release has no public custom-reader product or eager reader API, while its public `Data` API requires a complete shard in memory.
The preferred integration is a narrow upstreamable API in the public `MLX` product, carried by an exact pinned fork until accepted upstream, together with an injected weight-loader seam in `mlx-swift-lm`.
That seam must accept the authenticated eager arrays for each exact pinned shard and must not enumerate or reopen weight paths.
Small configuration and tokenizer inputs come from the already copied activation data.
Availability must use an explicit verified-model predicate instead of a fabricated filesystem URL.

Steno must not redeclare or dynamically resolve private `Cmlx` symbols, depend on checkout-internal header paths, expose lazy custom-reader arrays, or use a temporary named clone as the integrity boundary.
No dependency fork or upstream change has been published, and the production helper remains model-free until this contract is implemented and independently reviewed.

## Activation boundary

The Xcode 27 app links the MLX-free store adapter, while the normal Xcode 26 application remains unchanged.
The adapter maps only a coordinator-approved pin and source identity into store requirements and maps only verified fields back into `NativeGemmaModelSnapshot`.
One app facade now acquires import admission from the same process-wide coordinator used by recording before it mints and consumes the coordinator confirmation or invokes the adapter.

Neither the coordinator, adapter, nor store can download a model, launch the helper, create an MLX runtime, select Ollama, select `SystemLanguageModel`, or fall back to another provider.
Model import now joins the app-wide recording coordination.
Publishing recording intent atomically excludes new imports, requests cancellation of the exact active import, and awaits that task's full quiescence, including uncancellable post-publication synchronization and verification, before the existing helper gate is acquired and before recording permission or capture is requested.
Ordinary import failure is intentionally ignored by recording admission after the task is quiescent, because a model-store failure must not endanger audio capture.
The safe availability trade-off is explicit: an operating-system I/O operation that never returns also prevents recording admission because proceeding without proof of import quiescence would violate the exclusion contract.
That condition lasts for the remaining app-process lifetime, keeps the recording start state occupied, and currently requires restarting Steno before recording can be attempted again.
A follow-up user-facing path must explain the blocked state and offer a safe restart, but it must never turn a timeout or cancellation request into permission to begin capture while import quiescence remains unproven.
The user-facing import path must use the app facade rather than making the internal adapter a general app service.
The sandboxed helper cannot reopen the user store by path.
The authenticated XPC bind now transfers a verified model-directory descriptor together with the execution-gate descriptor.
The helper revalidates the tree from that retained descriptor at bind time and preserves the pinned root identity and exact model pin for the session.
That acknowledgement does not claim continued child-file immutability after the scan.
The exact MLX dependency snapshot builds with Xcode 27 Beta 6 and its matching Metal Toolchain component without loading a model.
Provider activation remains unavailable until a reviewed production checkpoint, user-facing consent and import flow, explicit recovery for retained corrupt installs or crash-orphaned staging, production Hardened Runtime validation, resource-bounded MLX activation through an authenticated byte boundary, and a real offline model run are accepted.
