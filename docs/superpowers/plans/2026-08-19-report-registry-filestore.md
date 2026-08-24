# Report Registry FileStore Implementation Plan

> **For agentic workers:** This task is explicitly executed inline without subagents. Use test-driven development and verification-before-completion for every behavior change.

**Goal:** Replace production UserDefaults endpoint persistence with a shared durable atomic file store and surface the newest cold legacy-pin failure exactly once.

**Architecture:** `StenoIntelligence` owns the atomic file, migration, path policy, and process claim ledger. Both app settings coordinators recover actual file state after every persist error, while their report presentations consume the same cold-failure selection contract.

**Tech Stack:** Swift 6.3, Foundation, Darwin POSIX file APIs, UserDefaults migration, Security Keychain, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-19-report-registry-filestore-design.md`

## Global Constraints

- No subagents, push, external endpoint, physical device, or new dependency.
- No secret in the registry file, UserDefaults, jobs, journals, logs, or committed fixtures.
- Preserve recording, recovery, transcript, diarization, report RunID, and legacy Apple-job invariants.
- Use `/private/tmp/steno-report-endpoint-fix5-build` for all sequential build and test work.
- Run StenoKit targetwise and do not invoke the known hanging global runner.

---

### Task 1: Shared atomic file store and migration

**Files:**
- Modify: `StenoKit/Sources/StenoIntelligence/TextModelEndpointRegistryState.swift`
- Modify: `StenoKit/Tests/StenoIntelligenceTests/TextModelEndpointRegistryStateTests.swift`

**Interfaces:**
- Produces: `AtomicTextModelEndpointRegistryStore` and `TextModelEndpointRegistryWriteCheckpoint`.
- Preserves: `TextModelEndpointRegistryStoring` and the UserDefaults migration helper.

- [x] **Step 1: Write real-filesystem failure and migration tests**

Add literal expected states for old destination, prepared state, committed state, and migrated state.

Inject `.beforeWrite`, `.afterFileSync`, and `.afterRenameBeforeDirectorySync`, then instantiate a new store at the same temporary URL and assert the actual durable state.

- [x] **Step 2: Run RED**

Run: `swift test --package-path StenoKit --scratch-path /private/tmp/steno-report-endpoint-fix5-build/swiftpm --filter TextModelEndpointRegistryStateTests`

Expected: the atomic store types and behavior do not exist.

- [x] **Step 3: Implement the minimal atomic file store**

Use owner-only POSIX descriptors, same-directory temporary files, complete writes, file fsync, atomic rename, directory fsync, backup exclusion, and iOS file protection.

Decode and verify the destination after migration before removing either UserDefaults migration key.

- [x] **Step 4: Run GREEN**

Run the same focused suite and require zero failures.

### Task 2: Recover ambiguous persist errors in both settings coordinators

**Files:**
- Modify: `App/Sources/TextModelSettings.swift`
- Modify: `App/Tests/TextModelSettingsTests.swift`
- Modify: `iOS/App/Sources/TextModelSettings.swift`
- Modify: `iOS/App/Tests/TextModelSettingsTests.swift`

**Interfaces:**
- Consumes: `AtomicTextModelEndpointRegistryStore`.
- Produces: coordinator helpers that reload and recover the actual durable state after any persist error.

- [x] **Step 1: Write macOS and iOS failure matrices**

For prepared and committed Upsert and Delete, inject every file checkpoint, open a cold store and settings instance, and assert one consistent endpoint-secret generation.

Assert that opposite snapshots fail and provider/network counters remain zero.

- [x] **Step 2: Run RED**

Run the focused `TextModelSettingsTests` in both app projects with the task buildroot.

Expected: production still selects UserDefaults and post-rename errors use the wrong rollback assumption.

- [x] **Step 3: Switch production and implement ambiguity recovery**

Construct the shared atomic store from the shared Application Support path policy in both settings initializers and resolver factories.

On persist errors, reload, recover, update endpoints from recovered state, and throw the visible initiating error.

- [x] **Step 4: Run GREEN**

Run both focused settings suites and the shared registry suite.

### Task 3: Surface a relevant cold pin failure once

**Files:**
- Create: `StenoKit/Sources/StenoIntelligence/ReportFailureObservationLedger.swift`
- Test: `StenoKit/Tests/StenoIntelligenceTests/ReportFailureObservationLedgerTests.swift`
- Modify: `App/Sources/ReportsSection.swift`
- Modify: `App/Tests/ReportsDisclosureTests.swift`
- Modify: `iOS/App/Sources/MeetingReportsPresentation.swift`
- Modify: `iOS/App/Tests/MeetingReportsPresentationTests.swift`

**Interfaces:**
- Produces: a process-local thread-safe `ReportFailureObservationLedger.claim(_:)`.
- Produces: latest-job selection that surfaces only a newest `templateRenderPinsRequired` failure.

- [x] **Step 1: Write cold-failure presentation tests**

Assert actionable message, one refresh, no repeat on the next reconcile or a remount sharing the ledger, suppression by any later template job, and successful manual Generate afterward.

- [x] **Step 2: Run RED**

Run the focused macOS and iOS report presentation suites.

Expected: a failed job that was never pending remains historical and produces neither banner nor refresh.

- [x] **Step 3: Implement the ledger and cold reconcile path**

Select the newest template-render job by `createdAt` and stable job ID tie-break.

Claim only a newest failed `templateRenderPinsRequired` job and reuse the existing typed actionable message.

- [x] **Step 4: Run GREEN**

Run shared ledger tests and both report presentation suites.

### Task 4: Full verification, documentation, cleanup, and local commit

**Files:**
- Modify: `.superpowers/sdd/2026-08-11-ios-protokolle-und-openai-endpunkte/final-fix-report.md`
- Modify: `.superpowers/sdd/2026-08-11-ios-protokolle-und-openai-endpunkte/progress.md`
- Modify: applicable report compatibility and privacy documentation.

- [x] **Step 1: Run complete affected verification**

Run all ten StenoKit targets separately, both full app suites, StenoiOSKit, and both generic app builds with the one reusable task buildroot.

- [x] **Step 2: Audit durable bytes and compatibility**

Run diff, conflict-marker, secret-pattern, Codable, migration, and backup-policy audits.

- [x] **Step 3: Update reports truthfully**

Correct the earlier fixture wording so it claims only the note mutation unless the endpoint fixture is actually mutated.

Record RED/GREEN evidence, exact test counts, builds, migration, compatibility, warnings, and remaining manual gates.

- [x] **Step 4: Commit locally and clean**

Stage only task files, create one local commit without co-author, verify the final worktree, and remove the exact task buildroot after confirming no owned process uses it.
