# Reliability records and transition rules

Implementation design, 2026-10-26. Existing Markdown and scan paths remain readable. No destructive store reset or real-vault migration is authorized.

## Vault operations

`VaultRepository` uses one recursive in-process lock for all repositories and thread-local staging for synchronous mutation preparation. No network request or async suspension occurs inside a transaction. `VaultFileStore` participates in the boundary; nested writes join the enclosing transaction. Reads during preparation see that transaction's staged contents. Other coordinated readers first recover pending intents under the same lock.

Hidden `.marginshot/` within the app-owned vault holds versioned operation records, protected staging, receipts, revision state, index progress, and destination acknowledgments. It is excluded from backup and portable vault enumeration. Staged afterimages use the same encrypted bytes as the final file; beforeimages retain the stored bytes, wrapped in encryption when encryption is enabled. No plaintext transcript is added to the journal. Operation result receipts use encryption-aware encoding too. Enabling encryption recovers prepared intents first, then encrypts older receipts and unprepared staging as well as live content.

Transitions:

1. Preparation: validate normalized paths and expected content revisions; stage afterimages and beforeimages. No live file is modified. Incomplete preparation without an intent cannot be replayed and is left available for diagnosis.
2. Prepared intent: atomically write paths, expected old hashes, intended new hashes/deletion states, stage references, and encoded result. This is the durable decision to roll forward. Never roll back only part of this accepted operation.
3. Applying: for each file, accept its old hash or intended new hash only. Apply/redo immutable afterimages; deletions are idempotent. A third hash indicates an external edit and stops recovery, preserving live content plus staging. A failed write retains the complete intent and beforeimages. Readers fail closed until recovery succeeds.
4. Revisions: atomically persist exact new byte hashes (or tombstones), producing operation IDs, and dirty index work. Destination pending work is the difference between revisions and destination acknowledgments, so a crash cannot erase pending work.
5. Committed receipt: persist the encrypted result indexed by stable operation ID. Replay returns this result without invoking the preparation closure. Then remove the intent/staging. Crash during cleanup is harmless; recovery detects the receipt and repeats cleanup.

There is deliberately no rollback state or best-effort restoration path. Recovery failures retain beforeimages and afterimages; tests cover failed recovery instead of discarding a failed rollback's only copy. External tools bypass in-process coordination and are detected through content hashes. Multi-file visibility is logical for app readers using this boundary, not an atomic filesystem rename guarantee for external tools.

Content revisions are SHA-256 of the immutable stored bytes, including encryption envelopes. Re-encryption creates a new revision. Path validation rejects traversal, absolute paths, reserved internal paths, and symlink escapes. Derived search SQLite files are disposable and excluded from backup; index JSON and structure can be reconstructed. Bootstrap uses coordinated writes without overwriting existing user rules.

## Capture and jobs

Keep the v1 Core Data entities and identities. Add optional job state, checkpoint, attempts, retry date, and failure category on Scan; keep existing structured/transcript JSON as durable output. No transcript duplication is required. A versioned additive model migrates existing stores with explicit reconciliation: filed remains complete, journal-backed structured work resumes filing, legacy structured work without a receipt requires review, transcribing resumes model work, preprocessing requires durable processed input, and blocked/error retains needs-attention evidence. Stale running batches become eligible; open batches from a previous session close only during startup recovery, before a live session starts.

Capture intent carries stable scan/batch IDs, timestamps, page number, notebook ID, and final raw image path. Place the original and intent durably before saving Core Data metadata. Report Saved only after metadata/job save. Recovery inserts missing records by stable identity and preserves unrecognized originals. A committed scan operation ID derives from the stable scan UUID, making filing replay idempotent.

Job transitions: pending -> running -> complete; paused and retryScheduled retain the last completed checkpoint. needsAttention requires explicit retry/review. Cancellation and privacy revocation pause; network failures schedule retry. Persist structured output before filing. Mark complete only after a committed vault receipt exists. Recovery may repeat unfinished networking, never a committed note contribution.

## Backup acknowledgments

Destination identity includes canonical selected folder or GitHub owner/repository/branch. Snapshots contain immutable stored bytes and their hashes. Acknowledgments record only successful exact hashes, including deletion tombstones; newer revisions remain pending. Keep existing destination manifests for conservative deletion scope and first-run reconciliation. External destination edits retain the existing documented one-way local-vault-authoritative behavior; never delete unrelated destination paths.

Claim coordinator busy state before eligibility awaits; coalesce wakeups during a run. Constraint failures leave durable pending differences unchanged. Retry on foreground, settings/network/power wakeups, and eligible background execution. Background scheduling remains opportunistic.

## Delayed proposals and indexes

Capture proposal expected revisions alongside retrieved content, before model work. Apply compares those revisions under the mutation lock. Missing expected revision for an existing target requires refresh/review. Deletions and creates also participate in conflict checks. Index progress is acknowledged only after indexing committed content; rebuild enumerates durable Markdown and metadata, including encrypted notes without plaintext SQLite artifacts.


## Implemented compatibility and startup ordering

App-written note metadata lives in additive `_system/note-metadata/<path-hash>.json` sidecars committed with the note. Rebuild uses these sidecars, legacy scan metadata, and Markdown headings, never an incomplete index as the sole source of truth. Indexed progress hashes content and metadata; encrypted retrieval searches decrypted content in memory without SQLite.

Before destination I/O, a persisted path intent records ownership. Acknowledgments still require successful exact-revision delivery. This allows a later deletion to reach a destination when an earlier upload succeeded but the process died before acknowledgment. Destination identity changes retain separate acknowledgment sets.

Startup is shared by foreground and background entry points: load/migrate Core Data, validate an existing encryption key, bootstrap/recover the vault, reconcile capture and jobs, complete encryption migration, then expose workers and the capture UI. Missing or invalid encryption keys stop recovery without replacing user data. Backup refuses plaintext snapshots while encryption is enabled, including during a Settings-triggered migration.

Exports exclude `.marginshot` journals and receipts and retain the existing stored-byte format. Encrypted exports contain ciphertext; the device-only Keychain key is not exported. This is not a cross-device decryption or key-recovery feature.
