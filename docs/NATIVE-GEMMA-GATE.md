# Native Gemma cross-process gate

Status: implemented and covered by gate-only and signed XPC integration tests.

The global crash-releasing gate is the implemented exclusion boundary.
The signed XPC binding, session-scoped client lifecycle, and helper self-exit path are implemented.
The native provider remains inactive until model import, MLX activation, and a real model run are complete.

This contract defines the macOS 27 exclusion boundary between audio capture and native Gemma work.
It is intentionally independent of the model checkpoint, MLX, the meeting library, and the configured model directory.

## Safety property

No gate-bound Gemma helper may accept or execute model work while any Steno process owns a recording lease.
Several Steno processes may record concurrently.
At most one native Gemma helper session may own model execution at a time.

The operating-system lock is the source of truth.
An app actor, an XPC reply, a process identifier, and a notification are not sufficient proof on their own.

A launchd process can exist briefly before gate binding or while exiting.
Such a process must reject every model and lifecycle frame, must never construct the MLX runtime, and must exit on authentication timeout, binding failure, or peer disconnect.
The achievable guarantee is therefore no gate-bound helper work during recording, rather than the literal absence of every transient helper PID.

## Stable gate file

Production uses one stable file for the current macOS user:

`~/Library/Application Support/Steno/NativeGemma/gate-v1.lock`

The path must not depend on `STENO_LIBRARY_DIR`, `STENO_MODEL_DIR`, a selected meeting library, or the app bundle identifier.
Development and installed builds for the same user must coordinate through the same file.
Tests must inject an isolated directory and must never touch the production gate.

The app opens the containing directory and leaf with `openat`, `O_NOFOLLOW`, and `O_CLOEXEC`.
The leaf is opened with `O_RDWR | O_CREAT`, mode `0600`, and without `O_EXCL` so concurrent creators converge on one inode.
The opened directory and leaf must be owned by the effective user, and the directory must not be group- or world-writable.
The leaf must be a regular file with one hard link and no group or world permissions.
After opening, `fstat` on the descriptor and `fstatat` with `AT_SYMLINK_NOFOLLOW` on the directory and leaf must identify the same device and inode.
Unexpected file type, ownership, link count, permissions, path replacement, or unsupported locking fails closed.

The gate file is never deleted, renamed, replaced, or treated as stale during normal operation.
All gate users use OFD record locks only.
Classic POSIX record locks, `flock`, and unrelated `FileHandle` access are forbidden on this file.

## Lock ranges

The same fresh open file description contains two one-byte ranges.

| Byte | Purpose | Model session | Recording transition or lease |
|---|---|---|---|
| 0 | Admission turnstile | Shared while admitting, then unlocked | Exclusive while excluding new models and draining helpers, then unlocked |
| 1 | Execution boundary | Exclusive for the complete bound-helper session | Shared for the complete recording lifetime |

The inverted execution lock is deliberate.
It permits multiple recordings while serializing memory-heavy native Gemma sessions across all Steno processes.

A fresh file description is required for every model session and every recording lease.
Recording and model locks must never share one open file description because OFD operations on the same description convert its existing locks.
Leases end only by closing their owned descriptors.
Code must not explicitly unlock byte 1 because duplicated descriptors in the helper refer to the same open file description.

## Model admission and helper binding

A model session performs these steps without creating or activating a transport first:

1. Reserve one exact session, model pin, and transport-construction identity in the client actor.
2. Resolve and fully verify a fresh model-directory capability asynchronously without a process-gate lease or helper.
3. Revalidate the session, pin, and construction identity in the client actor after verification returns.
4. Open and validate a fresh gate file description.
5. Acquire a shared nonblocking OFD lock on byte 0.
6. Acquire an exclusive nonblocking OFD lock on byte 1.
7. Unlock byte 0.
8. Create and immediately register the XPC transport in the same non-suspending actor turn.
9. Send one strict session-binding control frame carrying both descriptors as the first XPC control frame.
10. Wait for the authenticated acknowledgement of the exact model pin and root identity before sending any model frame.

Concurrent first requests in the same session share one construction reservation.
Recording preemption cancels a pending verifier and invalidates any late model capability without activating it.
Because expensive verification occurs before gate acquisition, it cannot strand an unregistered execution lease or block the client actor.

Failure to acquire byte 0 means a recording transition is in progress.
Failure to acquire byte 1 means either a recording is active or another native Gemma session owns execution.
Both outcomes reject model admission without starting a replacement helper.

The session-binding frame carries the execution-gate and model-directory descriptors with `xpc_fd_create` and never serializes numeric descriptor values.
The helper adopts both descriptors with `xpc_fd_dup`.
It validates the gate structure with `fstat`, performs an acquire-or-confirm exclusive OFD lock operation on byte 1, and fully revalidates the model from the retained root descriptor against the expected device, inode, manifest, hashes, and five-field model pin.
The helper cannot prove the gate descriptor path, so gate correctness also relies on mutual code-signature authentication of the app and helper.
The helper retains both adopted capabilities until process exit.
The client closes its own references on every terminal path, including resolver failure, cancellation, infrastructure failure, retirement failure, and recording preemption.
The session-scoped client retires automatically after the final high-level request reaches a terminal state.

The XPC fileport or helper duplicate retains the same open file description if the app exits after sending the binding frame.
The helper exits on peer disconnect, which releases its final reference and therefore the execution lock.

## Recording acquisition

Recording acquisition is permitted even when native Gemma is disabled or faulted.
The kernel gate, not the health of the model controller, decides whether recording can proceed safely.

The recording transition performs these steps:

1. Close same-process native Gemma admission in one actor turn.
2. Open and validate a fresh gate file description.
3. Acquire an exclusive OFD lock on byte 0 with a bounded monotonic deadline.
4. Cancel and retire the local helper, closing the client copy of its model lease on every terminal path.
5. Wait for a shared OFD lock on byte 1 within the same deadline.
6. Unlock byte 0.
7. Return the recording lease.

The byte 0 wait and byte 1 wait use nonblocking `F_OFD_SETLK` attempts with a cancellable, capped backoff against `ContinuousClock`.
`F_OFD_SETLKW` is not used because Swift task cancellation cannot reliably interrupt it.
`EAGAIN` and `EACCES` mean contention.
Other errors are infrastructure failures.

Failure of cooperative retirement in step 4 faults the model side but does not abort recording acquisition.
Local retirement is best effort because the kernel execution lock remains the authoritative boundary.
The recording transition continues to step 5, where the kernel execution lock remains the fail-closed authority.
Cancellation or deadline failure while acquiring either range closes the fresh description and leaves no controller stranded in `drainingForRecording`.

The recording lease holds byte 1 shared before the first recording-permission await and through capture stop or abort cleanup.
Release closes its descriptor and does not create or reconnect a helper.
App termination and `SIGKILL` release the lease through normal kernel descriptor cleanup.

## Cross-process preemption

Closing admission in one app does not directly stop a helper owned by another app process.
Every gate-bound helper therefore monitors byte 0 from its transferred open file description on a separate lightweight dispatch context.
It uses `F_OFD_GETLK` for a shared byte 0 query and does not acquire a polling lock.

An exclusive byte 0 holder is an authoritative recording intent.
On detection the helper closes request admission, cancels active work, and exits promptly even if model work ignores cooperative Swift cancellation.
Process exit releases the exclusive byte 1 model lock.
The recorder continues to wait for its shared byte 1 lock and cannot report success until the kernel confirms that every conflicting helper reference is gone.

A Darwin notification may be used only as a wake-up hint.
It must never replace the file-lock query and must never be trusted as proof of recording state.
If a broken or suspended helper cannot exit within the deadline, recording acquisition fails closed instead of overlapping model work.
The helper's self-exit on a byte 0 recording-intent observation is an expected fail-closed safeguard.

## Controller states

| State | Model request | Recording request |
|---|---|---|
| `idle` | Acquire model gate, bind helper, then become `active` | Begin `drainingForRecording` |
| `active` | Admit within the request limit | Close admission and begin `drainingForRecording` |
| `retiring(id)` | Reject as busy | Register one waiter, open its fresh recording description, and acquire byte 0 exclusive immediately; after matching retirement, become the next `drainingForRecording` owner and proceed to byte 1 |
| `drainingForRecording` | Reject as transition in progress | Reject duplicate acquisition |
| `recording(lease)` | Reject as recording active | Reject duplicate acquisition |
| `faulted` | Reject model work | Permit a new `drainingForRecording` attempt |

The transition from the final in-flight request to `retiring(id)` occurs before the actor suspends.
Retirement completion changes state only if the same retirement identifier is still current.
A pending recording waiter transitions directly from matching retirement to `drainingForRecording` so no new model request can slip between them.
Caller cancellation never removes the last tracked operation without triggering retirement.
The model-session and recording descriptors use different lease types so the client cannot bind a recording description to the helper by mistake.

Automatic retirement after the final high-level model session prevents an idle helper from blocking another process indefinitely.
The future native provider must wrap handshake, token counting, and generation in one explicit session so this policy does not reload the model between low-level frames.

## XPC protocol version 4

Version 4 atomically binds the execution-gate descriptor and verified model-directory descriptor in one strict `bindSession` control frame.
The frame carries both descriptors out of band as `executionGateFD` and `modelDirectoryFD`; descriptor numbers are never serialized.
The helper adopts both descriptors, verifies the model root from the retained descriptor against the expected device, inode, and pinned manifest, checks recording intent, and acknowledges only the exact bound model pin and root identity together with its helper identity.
Every subsequent handshake, token-counting, or generation request must carry the same model pin as the bound session.
Only the bind request may carry the two descriptor keys.
All other requests and every reply retain their exact existing key set.
Missing, duplicated, late, malformed, or second binding frames are rejected and terminate the helper.
The helper starts its byte 0 monitor before acknowledging the binding, and the monitor poll interval is a documented bound on preemption latency.
The acknowledgement proves the descriptor-rooted scan at bind time, but a root directory descriptor alone does not make its child files immutable for the rest of the session.
The helper therefore remains model-free until activation can open and retain the exact manifest-listed child files, materialize MLX from those capabilities, and verify them again before publishing the in-memory model.

Before binding succeeds, the helper rejects model work, cancellation, shutdown, prepare, and arm operations.
The MLX actor and runtime cannot be created before binding succeeds.
The existing registry remains the authority for request cancellation, quiescence, and graceful exit after binding.
Peer disconnect also closes the client model lease immediately, even when no request is currently in flight.

## Verification matrix

The gate-only test harness is a signed, UI-less executable controlled by pipes rather than timing sleeps.
It uses an injected gate directory.

The gate suite proves:

- one model lease excludes a recording lease until the model descriptor closes;
- one recording lease rejects model admission;
- two independent recording processes hold compatible shared execution locks;
- an exclusive turnstile blocks new model admission while an existing helper drains;
- a helper observes recording intent and releases its lock by exiting;
- `SIGKILL` of a recording owner releases its lease after `waitpid`;
- a descriptor transferred to another process keeps the model lock after the sender dies and releases it only after the receiver exits;
- the deadline loop is bounded and cancellable;
- concurrent creation converges on one inode; and
- symlinks, wrong ownership, extra hard links, unsafe permissions, and non-regular files fail closed.

The signed XPC integration suite additionally proves:

- the signed, sandboxed, networkless helper accepts and acknowledges the transferred descriptor;
- the bound model-free helper answers the handshake and rejects token counting and generation as unavailable;
- handshake, token counting, and generation share one high-level session;
- automatic retirement completes before the following recording lease is granted;
- recording release returns the controller to idle; and
- a later explicit request can establish a fresh signed session.

Signed negative tests for pre-bind frames, malformed or repeated binding, descriptor retention after the client closes its copy, peer disconnect, recording-intent preemption, model-only fault recovery, and protocol version skew remain open.
Multiprocess XPC coverage also remains open.

## Future sandbox constraint

The current macOS app is not sandboxed, while the XPC helper is sandboxed, hardened, and networkless.
Passing the already opened descriptor to the helper requires no new file entitlement.

If the main app becomes sandboxed, the stable shared path must move to an explicitly provisioned app-group container used by every supported Steno bundle identity.
That migration requires signing and two-process verification before release.
