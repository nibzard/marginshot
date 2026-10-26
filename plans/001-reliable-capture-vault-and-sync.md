# Make capture, processing, and backup recoverable

## Status and intent

- Status: IMPLEMENTED — phases 0–6 automated gates passed; physical-device and live-provider QA remain unverified (recorded in QA.md).
- Priority: P1.
- Effort: L; implement as independently verified phases.
- Risk: HIGH overall because this touches existing user data and recovery.
- Planned against: `cbe5fea`, 2026-10-26, **plus the uncommitted working tree reviewed that day**.
- Dependency: restore the test baseline before structural changes.

This plan preserves MarginShot's simple capture-and-chat experience while redesigning the ownership of durable work. The objective is reliable capture, resumable processing, safe AI edits, reconstructible search, and backups that acknowledge actual file revisions. A full rewrite, new backend, or replacement of SwiftUI/Core Data is not proposed.

Read the whole plan before implementation. Each phase must pass its gate before the next phase starts. Do not interpret this document as authorization to deploy, publish, discard local changes, or migrate a real user's vault during development.

## Product contract

The existing specification describes an offline-friendly scanner, Gemini transcription and organization, a portable Markdown vault, grounded chat, and optional backup. Sync defaults to off. Original images and raw transcription must remain traceable. Main screens should retain simple user-facing language; advanced controls belong in Settings.

The implementation must enforce these invariants:

1. Once capture reports **Saved**, the original image, stable identity, and recoverable metadata exist durably.
2. Process termination at any checkpoint leaves work that can resume without duplicating or losing note content.
3. Backup never moves, consumes, or deletes a local source file.
4. A backup acknowledges a particular revision; edits made during upload remain pending.
5. Disabling image uploads prevents subsequent image-bearing requests, including retries.
6. All app-owned vault mutations use the same coordination and recovery boundary.
7. AI-generated updates are validated and checked against the revision used to generate them.
8. Search/index failure cannot turn successful capture into data loss; indexes can be rebuilt.

## Current state and evidence

| File | Responsibility today / relevant issue |
|---|---|
| `MarginShot/Views/CaptureView.swift` | Camera UI, capture persistence, preprocessing, batch lifecycle; stores a temporary Core Data batch ID. |
| `MarginShot/PersistenceController.swift` | Programmatic Core Data model and store lifecycle. |
| `MarginShot/ProcessingQueue.swift` | Approximately 2,600 lines combining queue execution, vault writing, chat mutations, folder backup, and GitHub backup. |
| `MarginShot/ProcessingPipeline.swift` | Transcription/structure orchestration and response models. |
| `MarginShot/GeminiClient.swift` | Network requests and retries; must enforce image-upload permission at request time. |
| `MarginShot/VaultFileStore.swift` | Encryption-aware reads/writes and encryption migration. |
| `MarginShot/VaultIndexStore.swift` | JSON index, SQLite FTS, retrieval, and index rebuilding. |
| `MarginShot/ChatAgent.swift` | Retrieval and AI proposals. |
| `MarginShot/Views/ChatView.swift` | Applying proposed file operations and triggering backup. |
| `MarginShotTests/VaultSyncIntegrationTests.swift` | Happy-path create/apply/first-copy coverage; currently does not compile. |

Reviewed excerpts (line numbers are navigation hints, not stable identifiers):

```swift
// Views/CaptureView.swift:1091, before context.save() at line 872
currentBatchObjectID = batch.objectID

// ProcessingQueue.swift:1182; interrupted .processing batches are omitted
request.predicate = NSPredicate(format: "status == %@", BatchStatus.queued.rawValue)

// ProcessingQueue.swift:1866; consumes the live source during replacement
_ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)

// ProcessingQueue.swift:2082,2094; completion timestamp follows earlier enumeration
let snapshot = try vaultSnapshot(in: vaultURL, since: lastSyncAt)
defaults.set(Date(), forKey: lastSyncKey)

// MarginShotTests/VaultSyncIntegrationTests.swift:24
try VaultBootstrapper.bootstrapIfNeeded(userDefaults: testDefaults)

// MarginShot/ContentView.swift:106; incompatible with the test above
static func bootstrapIfNeeded() throws {
```

Additional confirmed behavior: the upload toggle is checked once at queue entry; new pages continue after it is disabled. Normal cancellation can mark a scan as an error. Sync requests arriving during an active run are discarded; the busy guard also precedes an asynchronous constraint check.

Verification already performed: simulator `build-for-testing` failed on the bootstrap signature mismatch. Isolated Foundation and Core Data experiments confirmed source consumption by file replacement and invalidation of retained temporary object IDs. No live provider integration or physical-device background tests were performed.

## Target responsibilities

```text
Capture UI -> CaptureStore -> original image + capture record + pending job
                                  |
                           ProcessingCoordinator
                                  |
                         validated output + checkpoint
                                  |
Chat proposal ----------------> VaultRepository
                               /       |       \
                       Markdown    revisions    durable change records
                                      |                 |
                                  IndexWorker       SyncCoordinator
                                                        |
                                                 destination adapters
```

Proposed names may be adjusted to existing conventions. Responsibilities and invariants are mandatory.

- **CaptureStore:** owns stable batch/scan IDs and capture durability. The UI invokes it and renders state.
- **ProcessingCoordinator:** owns persistent job transitions, eligibility, retries, cancellation, and startup recovery. Networking runs outside long storage critical sections.
- **VaultRepository:** serializes mutation preparation, revision checks, file commits, and recovery. Existing `VaultFileStore` remains the low-level encryption-aware I/O helper.
- **IndexWorker:** consumes committed changes and can reconstruct search from durable vault content.
- **SyncCoordinator:** consumes persisted pending revisions independently of processing completion; coalesces wakeups and acknowledges only completed work.
- **Destination adapters:** perform folder/GitHub I/O against immutable snapshots, without modifying source files.

An actor provides in-process serialization only. Recovery across termination requires persisted intent and checkpoints. Core Data and filesystem writes do not form one atomic transaction; design explicitly for either side completing first.

## Data and recovery design

Before schema changes, document the concrete model and transition rules under `plans/`. Keep the current Core Data schema readable until migration tests prove the transition.

Recommended minimal records:

- Processing job: stable ID, scan ID, stage/checkpoint, eligibility state, attempt count, next retry time, last failure category, and durable output reference.
- Vault operation: stable operation ID, affected paths, expected revisions, intended content hashes, staged-file references, and commit/recovery state.
- Vault revision: path, revision identifier/content hash, deletion state, and producing operation ID.
- Destination acknowledgment: destination identity and acknowledged revision per path. A destination's identity includes repository/branch or selected folder identity.

Avoid duplicating full transcripts unnecessarily. Keep filesystem output and metadata sufficient to reconstruct search; Core Data owns operational state, while original scans and Markdown carry user content.

Capture sequence: stage the original in app-owned storage; atomically place it at a stable final path; save its metadata and pending job; report success only after both are durable. On startup, reconcile interrupted capture intent and orphaned files without deleting potentially recoverable originals.

Processing lifecycle: `pending -> running -> complete`, with explicit `paused`, `retryScheduled`, and `needsAttention` outcomes. Persist the last completed stage separately. On relaunch, stale `running` work resumes from its checkpoint. Cancellation and disabled privacy permission are pauses, not transcription errors.

Vault sequence: validate paths and expected revisions; persist intent and recoverable staging; apply writes; persist revisions and pending destination work; mark committed; then clean staging. Recovery must finish or restore a partially applied operation before readers/workers use it. Multi-file atomic rename is unavailable; define logical transaction visibility and test every intermediate crash point.

Use a stable scan/operation ID to make note contributions idempotent, especially when several scans append to one daily note. A completed operation replay must return its existing result rather than append again.

## Scope and conventions

In scope: the Swift files above, `ContentView.swift`, `MarginShotApp.swift`, `SyncStatusStore.swift`, `TopicPageStore.swift`, `SystemRulesStore.swift`, relevant settings/review UI, new focused services under `MarginShot/`, tests under `MarginShotTests/` and lightweight UI tests, project file membership, `QA.md`, and `plans/`.

Out of scope: new backend services, framework/database replacement, visual redesign, new sync destinations, new AI providers, embeddings, broader organization features, pricing/auth redesign, and changing external vault format without an explicit compatibility decision. Do not silently remove existing encryption or organization settings.

Use four-space indentation, UpperCamelCase types/files, lowerCamelCase members, and existing XCTest conventions. Match focused Foundation helpers such as `VaultFileStore.writeData(_:to:userDefaults:)`; keep durable orchestration out of SwiftUI views. Prefer dependency injection for vault roots, defaults, clocks, network transports, and stores.

## Git and verification workflow

The reviewed working tree already contains user changes. Run `git status --short` and `git diff --stat cbe5fea -- MarginShot MarginShotTests MarginShotUITests MarginShot.xcodeproj` first. Compare live symbols with the excerpts above. A fresh worktree from HEAD alone will omit reviewed changes: preserve and transfer the intended working state explicitly before implementation, without resetting or overwriting the original tree.

If using a worktree, place it under `~/dev/.worktrees/marginshot/reliability`. Use Conventional Commits, for example `fix(capture): retain permanent batch identity`. Do not push without authorization. Remove completed worktrees only after preserving needed tracked, untracked, and ignored artifacts; never force removal to discard work.

Commands (run from repository root):

```sh
# Build test bundles; baseline currently fails as described above.
xcodebuild build-for-testing -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO

# Discover available simulator destinations before running tests.
xcodebuild -showdestinations -project MarginShot.xcodeproj -scheme MarginShot

# Use an available iOS simulator UUID from the preceding command.
SIMULATOR_ID='<available simulator UUID>'
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath ./DerivedData -only-testing:MarginShotTests CODE_SIGNING_ALLOWED=NO

# Final unit/integration and UI suite.
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO

git diff --check
```

Expected: build/test commands exit 0 with successful build/test results; diff check exits 0 with no whitespace errors. Do not claim simulator execution proves real-device background behavior. Tests must use isolated temporary vaults and test stores, never a developer's actual Documents/vault or real provider credentials.

## Implementation phases

### 0. Restore an isolated verification baseline

Reconcile the `VaultBootstrapper` signature with integration tests. Preserve injectable defaults rather than weakening test isolation. Inject a temporary vault root and isolated persistence where tests currently assume global Documents storage. Inspect app-launch side effects in hosted tests so background processing cannot interfere with fixtures.

Use `PipelineLogicTests.swift` and `VaultSyncIntegrationTests.swift` as XCTest style examples. Avoid adding abstractions unrelated to testable durability boundaries.

**Gate:** run the build-for-testing and unit/integration commands above; both pass. Confirm fixtures cannot remove or rewrite real user vault files.

### 1. Contain confirmed failures with narrow regressions

Fix temporary batch identity retention. Fix folder replacement by copying to a unique staging file on the destination volume before replacement. Retain the local source on every success and failure path. Recheck privacy before each image-bearing request and retry. Handle cancellation separately from permanent errors.

Add `CapturePersistenceTests` for multi-page capture and Done; extend `VaultSyncIntegrationTests` to copy, update, sync, verify both copies, sync again, and verify neither disappears. Add a controlled transport test where permission is disabled while page one is in flight and page two never uploads.

These fixes are prerequisites to safe migration; do not leave known loss paths enabled while restructuring the rest of the app.

**Gate:** run unit/integration tests; new regression cases fail against the original behavior and pass with the fixes. No live network calls.

### 2. Specify and introduce the shared mutation boundary

Extract `VaultRepository` and small supporting revision/journal types from existing writer/apply responsibilities. Preserve existing public entry points initially as adapters. Define recovery outcomes for each journal state before changing callers. Route chat application, processed notes, topic/system writes, and encryption migration through the appropriate coordinated path; generated index files must be clearly classified as derived writes.

Stage recoverable data inside protected app-owned storage. Respect encryption settings for staged content and backups; do not introduce persistent plaintext staging for encrypted notes. Never delete the only recovery copy after a failed rollback.

Add `VaultRepositoryTests` covering stale expected revisions, duplicate operation IDs, failure between files, restoration failure, and restart recovery. Ensure coordinated readers cannot observe partially committed multi-file state.

**Gate:** run build-for-testing and unit/integration tests. Every supported journal checkpoint has a recovery test with exact resulting contents and revisions asserted.

### 3. Move capture and processing onto durable jobs

Extract capture persistence from `CaptureViewModel`. Introduce additive job state and an explicit migration for existing queued/open/processing/blocked batches. Preserve filed scan results. Do not automatically process a still-active capture batch; startup recovery must distinguish interrupted sessions from live sessions.

Use committed operation IDs when filing scans. Persist structured output before filing so restarting does not require repeating completed model work. Recover stale running jobs on launch, respect current privacy/network/power settings, and leave paused work eligible for later wakeups.

Keep camera preprocessing distinct from LLM processing so a scan cannot be treated as ready before its required input is durable. Avoid retaining managed objects across queue/context boundaries; use stable identifiers and context-local fetches.

Add `ProcessingRecoveryTests`: interruption after capture placement, after metadata save, during transcription, after structured output persistence, after note commit but before job completion, and cancellation on the last scan. Replay must leave one note contribution per scan.

**Gate:** run unit/integration tests against fresh and pre-migration fixture stores. Assert preserved image hashes, stable scan counts, correct queued/paused states, and no duplicate contributions after repeated recovery.

### 4. Replace timestamp backup tracking with revision acknowledgments

Extract destination adapters from `ProcessingQueue.swift`. Make folder and GitHub adapters read immutable revision snapshots. Persist pending work with vault commits and acknowledgments only after a destination succeeds. Include deletions as revisioned tombstones so offline deletes propagate later without deleting unrelated destination files.

Claim the sync busy state before any suspending eligibility work. Coalesce requests arriving during a run. Persist pending work when constraints fail and retry on foreground activation, relevant network/power changes, and eligible background opportunities. Expose manual sync even without an error banner; do not promise immediate background execution.

For migration, retain destination identity and existing manifests, schedule conservative reconciliation, and retire timestamp watermarks only after revision tracking is established. Define external destination-edit conflict behavior before overwriting remote content; preserve existing documented behavior unless explicitly revised.

Add `SyncCoordinatorTests` with fake adapters: edit after enumeration, edit after upload, concurrent triggers, termination before acknowledgment, offline/charging deferral, failed deletion, destination switch, and retry after partial success. Assert exact acknowledged revisions and retained pending work.

**Gate:** run unit/integration tests. A change made during upload is either uploaded by that run or remains pending afterward; no failure path consumes source files or acknowledges an unuploaded revision.

### 5. Rebuild derived data and protect delayed AI proposals

Have index updates consume committed revisions with retryable progress. Make rebuild enumerate durable Markdown and reconstruct metadata rather than relying exclusively on a potentially incomplete `INDEX.json`. Preserve encrypted-vault behavior and avoid creating plaintext search databases while encryption is enabled.

Attach expected revisions to chat proposals based on the content supplied to the model. Capture revisions consistently with retrieval content. At Apply, reject conflicting updates with a clear refresh/review action. Source IDs alone do not prove a proposal is current.

Add `VaultIndexRecoveryTests` for missing/corrupt index and mid-update interruption, and `VaultProposalTests` for edits/deletions between retrieval and Apply. Separate empty retrieval results from recoverable index failures in internal status.

**Gate:** run unit/integration tests. Rebuilding from the same vault returns equivalent indexed paths/content; stale proposals leave newer note bytes unchanged; encrypted mode leaves no plaintext search artifact.

### 6. Validate the complete user journey and retire adapters

Remove old mutation/sync paths only after all callers use the new ownership boundaries. Keep capture/chat UI focused on saved, processing, paused, needs attention, and backed-up outcomes. Show Saved only after the durable capture contract succeeds.

Update `QA.md` with recovery and privacy cases. Run the full test command and `git diff --check`. On a physical device, capture a multi-page batch offline, relaunch during processing, toggle upload permission, defer backup on constraints, and verify restored eligibility. Export the vault and verify Markdown plus original images remain usable; explicitly document existing encrypted-export semantics.

**Gate:** full automated suite passes; device QA results and any remaining limitations are recorded. No real provider integration is claimed without an actual authorized test.

## Completion checklist

- [x] Build-for-testing, unit/integration, and UI test commands exit 0.
- [x] Capture persistence tests prove one batch across multiple pages and successful queueing on Done.
- [x] Repeated folder sync preserves source and destination contents.
- [x] Recovery tests cover every persisted operation/job checkpoint.
- [x] Replaying a completed scan operation does not duplicate note content.
- [x] Disabling image uploads prevents the next image request and its retries.
- [x] Concurrent edits remain pending until their exact revision is acknowledged.
- [x] Pending backups survive termination and constraint deferral.
- [x] Stale AI proposals cannot overwrite newer revisions.
- [x] Missing indexes can be rebuilt without altering original user content.
- [x] Migration fixtures preserve existing scan/image/note identities and content.
- [x] Physical-device QA is recorded separately from automated results.
- [x] Changed files stay within scope and `git diff --check` succeeds.
- [x] This plan's status and `plans/README.md` are updated with actual completion evidence.

## Stop conditions

Stop the affected phase and report evidence if live code materially differs from the reviewed behavior, schema migration cannot preserve existing stores, encrypted data cannot be recovered with existing keys, or the proposed journal cannot distinguish committed from uncommitted writes. Do not guess, reset a store, discard a vault, or silently regenerate user content.

Also stop if a phase requires an out-of-scope product/storage change, would overwrite unpreserved working-tree edits, or its verification fails twice after a reasonable correction. Resolve the design issue before continuing dependent work.

## Maintenance and deferred decisions

Future vault writers must use the shared mutation boundary; new destinations must implement revision acknowledgments and failure tests. Changes to encryption, path normalization, daily-note aggregation, and backup identity require migration/replay tests. Reviewers should inspect crash points and durable ordering alongside happy-path code.

Defer new features and broad visual redesign until these guarantees hold. Full rewrite, backend orchestration, and database replacement are not supported by current evidence. Keep remote conflict policy, encrypted export portability, and background scheduling guarantees explicit rather than allowing incidental implementation behavior to become the product contract.

## Implementation evidence (2026-10-26)

### Phase 0 — passed

- Preserved the pre-existing working tree in place; no reset, checkout, store deletion, or real-vault migration.
- Reproduced the bootstrap signature compile failure in `/tmp/marginshot-baseline-build.log`.
- Added root/defaults injection to bootstrap, writer, apply service, folder backup, and index store. Integration fixtures create UUID-scoped temporary roots and defaults, load a private in-memory store, and never remove Documents/vault or override standard defaults.
- Hosted unit tests display an inert root instead of starting persistence, bootstrap, encryption, and processing. UI test app launches retain the normal startup path.
- Build-for-testing now exits 0 (`/tmp/marginshot-phase0-build.log`). Unit/integration tests exit 0: 8 tests passed (`/tmp/marginshot-phase0-tests.log`).
- Installed the missing iOS 27.1 runtime and created simulator `B120CF6D-629C-4851-A66C-79C28976CB69` (iPhone Duo, the runtime's supported device type).
- At this gate, phases 2–6 had not started. Physical-device and provider QA had not been performed.

### Phase 1 — passed

- Regression run `/tmp/marginshot-phase1-red.log` exits 65 with the expected capture, folder replacement, next-page privacy, and retry privacy failures against the old behavior.
- Permanent batch IDs are obtained before the UI retains them. Folder replacement uses a disposable copy on the destination volume. Gemini checks upload permission for each image-bearing attempt. Privacy revocation and cancellation retain resumable scan state, including cancellation during the last scan.
- Corrected unit/integration suite exits 0: 11 tests passed (`/tmp/marginshot-phase1-tests.log`). No live network requests: privacy tests use a controlled URLProtocol transport.

### Phase 2 — passed

- Concrete record and transition design: [001-recovery-model.md](001-recovery-model.md). No schema changes yet.

- Build-for-testing exits 0 (`/tmp/marginshot-phase2-build.log`). Corrected unit/integration suite exits 0: 20 tests passed (`/tmp/marginshot-phase2-tests-corrected.log`). The first run identified a Keychain entitlement dependency in unsigned tests and a nonexistent-leaf symlink escape; scoped encryption-key injection and component validation corrected both.
- The journal uses a durable roll-forward decision, with no rollback state. Failed recovery retains before/after copies and blocks coordinated readers; corresponding tests assert exact contents and revisions at every persisted checkpoint.

### Phase 3 — passed

- Additive Core Data migration and capture/job extraction follow the model documented before schema changes in `001-recovery-model.md`.

- Build-for-testing exits 0 (`/tmp/marginshot-phase3-build.log`). Unit/integration execution exits 0: 27 tests passed (`/tmp/marginshot-phase3-checkpoint-tests.log`). This includes additive v1 migration with a retained SQLite backup, original hashes/IDs preserved, capture placement/metadata restart recovery, note-commit replay before job completion, last-scan cancellation, and transcription/organization resume through a fake transport with image permission revoked.
- Legacy structured work without a journal receipt is retained for explicit filing review; non-daily legacy notes did not include stable scan markers, so automatic replay cannot safely infer whether they were already appended. Existing metadata is recognized on explicit retry; filed records remain complete.
- Startup recovery runs before the capture UI is exposed. Original filenames include the scan UUID to preserve originals even when a failed metadata save causes a page-number retry.

### Phase 4 — passed

- Replace timestamp tracking with exact stored-byte revisions and per-destination acknowledgments. Snapshots materialize one file at a time under coordination, then release the lock before destination I/O.

- Build-for-testing exits 0 (`/tmp/marginshot-phase4-build.log`); unit/integration tests exit 0: 38 passed (`/tmp/marginshot-phase4-tests.log`). Fake adapters cover enumeration/upload races, partial success, failed deletion, destination switches, constraint deferral, concurrent triggers during eligibility, and termination before acknowledgment.
- Destination write intents persist before I/O to retain deletion ownership if an upload succeeds but the process dies before acknowledging it. Deletions never target paths absent from that destination's manifests, intents, and acknowledgments.
- Independent backup background requests, foreground/network/power/settings/commit wakeups, and manual backup are wired. Background behavior is unverified on hardware.

### Phase 5 — passed

- Compatibility decision: add `_system/note-metadata/<path-hash>.json` sidecars for app-written note metadata. Markdown/image paths and bytes retain their existing format; older clients can ignore these additive JSON files. Sidecars use the same encryption and journal as notes and allow rebuilding titles/tags/links after losing derived indexes. Existing notes without sidecars fall back to scan metadata and Markdown headings; metadata already lost from older indexes cannot be invented.

- Build-for-testing exits 0 (`/tmp/marginshot-phase5-build.log`); unit/integration tests exit 0: 47 passed (`/tmp/marginshot-phase5-tests.log`). Missing/corrupt/empty indexes, interrupted index progress, encrypted search, stale edits/deletions/creates, and untrusted model revisions are covered.

### Phase 6 — automated gate passed; device limitations recorded

- Removed obsolete index mutation and processing helpers after routing callers through recovery, revision sync, and rebuildable indexing. Capture and backup status distinguish saved, paused, needs attention, and pending backup. Startup errors retain data and show recovery failure instead of terminating the app.
- Startup validates existing encryption keys before bootstrap and completes encryption migration before workers start. Backup defers plaintext revisions while encryption is enabled. Encryption migration also protects old receipts and unprepared recovery staging.
- Final full suite exits 0: **51 tests passed, 0 failed, 0 skipped** (49 unit/integration plus 2 UI), including encryption-transition, export, and startup recovery coverage. Log: `/tmp/marginshot-final-verified-tests.log`; result: `DerivedData/Logs/Test/Test-MarginShot-2026.10.26_14-22-49-+0100.xcresult`. `xcresulttool get test-results summary` independently confirms the counts.
- Generic iOS device Release build exits 0 (`/tmp/marginshot-final-device-build.log`), including background scheduler code excluded from simulator builds. Final simulator test execution rebuilt the app and both test bundles. `git diff --check` exits 0.
- A verification rerun could not launch the simulator UI runner (`/tmp/marginshot-verified-tests.log`) and was interrupted. Rerunning with `-parallel-testing-enabled NO` passed the complete suite. The earlier full suite also passed (`/tmp/marginshot-final-tests.log`). No product test failure was hidden by this retry.
- Existing Swift 5 concurrency warnings introduced by mutable network callback guards were removed using a locked one-shot completion, and retry callbacks now capture self explicitly. Device build retains the project orientation warning; no signing or physical-device execution was performed.
- Physical device unavailable: `xcrun devicectl list devices` showed only simulated devices. No camera, real-device background scheduling, security-scoped provider, or live GitHub/Gemini test is claimed. See `QA.md` for the remaining device journey and encrypted-export limitations.
