# Report Registry FileStore and Cold Failure Design

Date: 2026-08-19

Status: approved by the direct implementation request

## Goal

The production endpoint registry must report storage failures and remain reconstructible after a process or power loss at every durable file and Keychain boundary.

A legacy external report job that already failed the pin guard must be surfaced once when the reports view first encounters it, even when that view never observed the job while it was pending.

## Atomic registry file

`StenoIntelligence` provides one shared `AtomicTextModelEndpointRegistryStore` for macOS and iOS.

Its production path is `Application Support/Steno/TextModelEndpoints/registry-state.json` on both platforms.

The directory is private to the user, excluded from backup, and uses platform data protection where available.

The registry file and temporary siblings use owner-only permissions.

Each write creates a uniquely named temporary file in the destination directory, writes all bytes, synchronizes the file, closes it, atomically renames it over the destination, and synchronizes the parent directory.

A failure before rename leaves the prior destination authoritative and removes the temporary file.

A failure after rename is ambiguous to the caller, so callers reload the destination and run normal idempotent registry recovery instead of assuming either the old or new state.

## Migration

The existing canonical UserDefaults state and the older endpoint-array value remain migration inputs only.

When the file is absent, the store decodes the canonical state first or the old endpoint array second, writes it durably, reloads and verifies the file, and only then removes both migration values.

If a prior launch wrote the file but stopped before UserDefaults cleanup, the next load verifies the file and completes cleanup idempotently.

A corrupt or unreadable file fails closed and never falls back to stale UserDefaults.

The file contains only the public endpoint registry and the secret-free mutation journal.

API keys remain exclusively in revision-bound Keychain slots.

## Coordinator error handling

Both app coordinators use the shared file store in production and in their provider resolvers.

Every thrown registry persist is treated as potentially post-rename.

The coordinator immediately reloads actual file state, runs `TextModelEndpointRegistryRecovery`, updates in-memory endpoints only from that recovered state, and still returns a visible error to the initiating UI.

Prepared recovery retains the old endpoint and slot, while committed recovery retains the new endpoint and slot.

Delete recovery never leaves a visible required-key endpoint without its slot.

## Cold legacy-pin failure

The relevant cold failure is the newest template-render job only when that newest job is failed with `templateRenderPinsRequired`.

A later queued, running, finished, cancelled, or differently failed template job supersedes it.

A process-local claim ledger keyed by job ID prevents polling and view remounts in the same app process from resurfacing the same historical failure.

When claimed, the view displays the job's actionable error and requests exactly one current preflight refresh.

A manual Generate clears the banner and follows the ordinary explicit generation path.

## Tests

Shared real-filesystem tests inject failures before write, after file sync, and after rename before directory sync and reopen a new store instance for every outcome.

macOS and iOS mutation tests cover prepared and committed Upsert and Delete persistence at all three file checkpoints with cold settings instances, exact Keychain slots, idempotent recovery, and no provider or network use.

Migration tests cover canonical and endpoint-array UserDefaults values, post-write cleanup interruption, corrupt files, file permissions, backup policy, and secret-free bytes.

Presentation tests cover a cold relevant failed job, exactly one refresh, suppression by a later job, remount claim behavior, and a subsequent normal manual generation.
