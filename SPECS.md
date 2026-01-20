# specification.md — “Paper → AI → Your Vault” (iOS)

## 0. Summary
Build a **super-simple iOS app** with two swipeable modes:

1) **Capture**: a “scanner camera” for notebook pages (fast, offline-friendly).
2) **Chat**: a plain LLM chat that can answer questions using your captured notes (“docs”).

Behind the scenes, the app:
- Stores scans locally, processes them with an LLM (Gemini) to **transcribe + structure + link**.
- Maintains a **Markdown vault** with opinionated organization (Johnny.Decimal-inspired).
- Optionally **syncs** the vault to an external destination (GitHub/Git remote/export folder). All sync complexity is hidden in **Settings**.

**Core promise:** “Write on paper. Snap pages. Everything becomes searchable, connected, and owned by you as plain Markdown.”

---

## 1. Goals / Non-goals

### Goals
- **Delightfully fast capture** (2–3 taps to scan a batch).
- **Automatic organization** with minimal user decisions.
- **Chat grounded in your notes** (with optional “where did that come from?”).
- **Data ownership**: plain Markdown + images, portable.
- **Sync as a setting**: user can ignore it and still get value locally.

### Non-goals (initially)
- Becoming a full notes editor (no rich editing UI).
- Complex graph visualizations.
- Real-time collaborative editing.
- Perfect handwriting OCR on-device (LLM does the heavy lifting).

---

## 2. Product principles (simplicity constraints)
1. **One obvious action per screen**
   - Capture screen: *Scan*
   - Chat screen: *Ask*
2. **Hide complexity**
   - No chips, no diffs, no commit logs in primary UI.
   - Advanced controls live in Settings.
3. **Safe automation**
   - Default: “auto-organize + auto-sync” (if enabled)
   - Provide “Undo last sync” and “Review mode” in Settings.
4. **Grounded by default**
   - Chat should prefer “I found X in your notes” over speculation.
   - If not found: say so and suggest what to scan/process.

---

## 3. Key concepts & terminology
- **Scan**: a single captured page image + metadata.
- **Batch**: a group of scans captured in one session.
- **Inbox**: unprocessed scans/batches waiting for transcription/organization.
- **Vault**: local folder containing Markdown notes + scan images.
- **System Rules**: a machine-readable + human-editable “philosophy” that teaches the LLM how to structure output.
- **Destination**: optional sync target (GitHub/Git remote/export folder).

---

## 4. UX: App structure

### Navigation
- The app is a **two-page horizontal swipe** container:
  - **Left:** Capture
  - **Right:** Chat
- Minimal header shows current mode (“Capture” / “Chat”) and a subtle sync status icon.

### 4.1 Capture mode (primary screen)
**Primary UI elements**
- Live camera view with scanner-style auto-detect.
- Big shutter button.
- Small “Batch mode” toggle (default ON).
- Small “Inbox count” indicator (e.g., “Inbox: 12”).

**Secondary actions** (hidden behind a single “⋯” button)
- Review Inbox
- Choose Notebook (optional)
- Processing options (Wi‑Fi only, charging only)
- Settings

**Key behaviors**
- Auto crop/de-skew/enhance on capture (scanner feel).
- Offline capture always works.
- After finishing a batch, show one lightweight prompt:
  - “Processing in background” (if enabled)
  - Button: “Ask about this” → jumps to Chat with last batch implicitly prioritized.

#### Capture flow (happy path)
1. Open app → Capture screen.
2. User scans 1+ pages (batch).
3. Tap “Done”.
4. App shows a small confirmation: “Saved. Processing when ready.”
5. User swipes to Chat to ask questions.

### 4.2 Chat mode (primary screen)
**Plain chat UI**
- Conversation list is optional (MVP can be single thread).
- Standard message bubbles, input field, send button.
- No visible context chips by default.

**“Smartly hidden” grounding**
- Each assistant response ends with a collapsed disclosure:
  - “Used sources ▸” (tap to expand)
  - When expanded: list of note titles + dates + “Open” actions.
- If answer is not grounded, show “Not found in notes” explicitly.

**Quick actions (minimal)**
- A small “📎” icon to attach the latest batch (optional; in MVP this can be implicit).
- A “Search notes” action inside the “Used sources” panel rather than cluttering the header.

#### Chat flow (happy path)
1. User asks: “What are my open tasks this week?”
2. App retrieves relevant notes (local index + LLM guidance).
3. Assistant answers + (collapsed) “Used sources”.
4. If assistant proposes an update (e.g., consolidate tasks), show a single CTA:
   - “Apply to vault” (not “Commit changes”)
5. On tap: apply changes locally; sync happens automatically if enabled.

---

## 5. Organization model (opinionated, minimal user input)

### 5.1 Vault structure (default)
The vault is **app-owned locally** and exportable.

vault/
00_inbox/                 # raw captures + initial transcripts
01_daily/                 # daily notes derived from pages
10_projects/              # project pages and related notes
11_meetings/              # meeting notes
13_tasks/                 # consolidated task lists (optional)
20_learning/              # optional category
_topics/                  # MOCs / topic pages (optional)
_system/
SYSTEM.md               # rules/instructions for LLM
INDEX.json              # machine index (titles, summaries, tags, links)
STRUCTURE.txt           # shallow tree snapshot for orientation
scans/
YYYY-MM-DD/
batch-/
page-001.jpg
page-001.json       # per-scan metadata

> Notes:
- We keep folder names simple and meaningful.
- Johnny.Decimal influence is in **category semantics**, not necessarily strict numbering (can be offered as a Settings toggle).

### 5.2 “System Rules” file (SYSTEM.md)
A short, evolving instruction file used by the LLM to stay consistent.
- Stored at: `vault/_system/SYSTEM.md`
- Editable in Settings as plain text (advanced users) plus high-level toggles (simple users).

**Default rule themes**
- “Depth over breadth; prioritize clean, composable notes.”
- “Prefer claim-style headings when confident.”
- “Weave wiki-links inline when referencing concepts/projects.”
- “Don’t invent facts; mark uncertain items as TODO.”
- “Keep a raw transcription section for traceability.”

### 5.3 Note style (output contract)
All notes are Markdown. Optional YAML frontmatter.

**Daily note example**
- `01_daily/2026-01-20.md`
  - Top: metadata (captured_at, source batch IDs)
  - Sections:
    - “Summary”
    - “Notes”
    - “Tasks” (checkboxes if detected)
    - “Links” (only if needed)
  - Raw transcription appended at the end for traceability.

**Linking**
- Use wiki-link style: `[[Project Atlas]]`
- Create project/entity pages lazily when first referenced.

---

## 6. Mechanisms (how the system works)

### 6.1 Processing pipeline (Inbox → Vault)
Processing should run:
- automatically in the background (default),
- respecting user constraints (Wi‑Fi only / charging only), configurable in Settings.

**Stages**
1. **Preprocess image** (on-device)
   - crop, deskew, contrast, glare reduction
2. **Transcribe** (LLM)
   - produce text + layout hints
3. **Structure** (LLM)
   - convert into clean Markdown with sections
4. **Classify & link** (LLM + local index)
   - choose folder/category
   - detect entities/projects
   - add wiki-links to existing notes
   - propose creating new entity notes if needed
5. **Update system indices**
   - update `INDEX.json`
   - update `STRUCTURE.txt` (periodically or on sync)
6. **(Optional) Consolidations**
   - tasks aggregation into `13_tasks/`
   - update topic pages in `_topics/` if enabled

**Important:** Always preserve traceability:
- Raw scan image is stored.
- Raw transcript is appended to the note under a "Raw transcription" section, with full JSON stored in per-scan metadata.

### 6.2 Chat retrieval (vault-aware, but hidden)
Chat uses a layered approach (fast + cheap):
1. Read `INDEX.json` (titles, summaries, tags, links).
2. Retrieve candidate notes via local search:
   - SQLite FTS on Markdown text + metadata
   - optional lightweight embeddings later
3. Expand via wiki-links (1 hop) for context.
4. Provide selected note texts to LLM with strict instructions:
   - answer grounded
   - cite sources internally
   - return “used sources” list for UI

**UI simplification**
- User does not manage context manually in the main UI.
- A “Used sources” disclosure makes grounding transparent without clutter.

### 6.3 “Apply to vault” changes (no diffs in main UI)
When chat proposes edits:
- Show a single card with:
  - “Apply to vault” (primary)
  - “Not now” (secondary)
  - “Preview” (hidden behind a small chevron, optional)

**Default behavior**
- Apply changes locally in a single transaction.
- Sync later if enabled.

**Advanced option (Settings)**
- “Review changes before applying”:
  - shows file list + basic preview
  - optional diff view (deep advanced)

### 6.4 Sync / Git abstraction (Destination)
Sync is modeled as a **Destination** with a simple user mental model:
- “Keep my notes backed up to: Off / iCloud Drive / GitHub / Other”

**Destinations (MVP)**
- Off (local only)
- Folder export (Files app / iCloud Drive)
- GitHub (OAuth) — optional if feasible in MVP, otherwise V1

**Git is not mentioned in primary UI**
- The UI says “Sync destination”.
- Commit/push is internal terminology only.

**Sync behavior**
- Background sync after processing and after “Apply to vault”.
- Automatic retries; clear user-facing error banner only when action is required (e.g., auth expired).

---

## 7. Settings (where complexity lives)
Settings are grouped as:
1. **Sync**
   - Destination: Off / Folder / GitHub / Custom Git Remote
   - Account / auth
   - Sync conditions: Wi‑Fi only, charging only
2. **Organization**
   - Style: “Simple folders” vs “Johnny.Decimal”
   - Linking: On/Off
   - Task extraction: On/Off
   - Topic pages (MOCs): On/Off
   - “Edit System Rules” (advanced)
3. **Processing**
   - Auto-process inbox: On/Off
   - Quality mode: Fast / Balanced / Best (controls LLM passes)
4. **Privacy**
   - “Send images to LLM” toggle + explanation
   - Redaction options (optional later)
   - Local encryption toggle (if supported)
5. **Advanced**
   - Review changes before applying
   - Export vault as ZIP
   - Reset indices / reprocess all

---

## 8. Data model (suggested)
Use Core Data or SQLite + filesystem.

### Entities
- `Notebook` (optional)
  - id, name, default destination, rules overrides
  - MVP uses a single default notebook; multi-notebook selection lands in V1.
- `Batch`
  - id, created_at, notebook_id, status, scan_ids[]
- `Scan`
  - id, batch_id, image_path, processed_image_path, status, ocr_text, confidence, page_number
- `Note`
  - path, title, summary, tags, links[], updated_at
- `SyncState`
  - destination type, auth tokens (Keychain), last_sync_at, error state
- `Index`
  - materialized view of notes for retrieval (`INDEX.json` + local FTS)

### Status enums
- Scan: `captured | preprocessing | transcribing | structured | filed | error`
- Batch: `open | queued | processing | done | error`
- Sync: `off | idle | syncing | error`

---

## 9. Architecture (high level)

### iOS components
- **UI Layer**
  - CaptureViewController (camera + batch)
  - ChatViewController (chat + sources disclosure)
  - SettingsViewController (grouped)
- **Processing Engine**
  - Queue (serial per notebook; concurrency controlled)
  - Background tasks (BGTaskScheduler)
  - Image preprocessing module
  - LLM client (Gemini)
  - Vault writer (atomic file writes)
  - Indexer (updates FTS + INDEX.json)
- **Vault Storage**
  - Filesystem folder for vault
  - SQLite/FTS for quick retrieval
- **Sync Engine**
  - Destination interface:
    - FolderDestination
    - GitHubDestination (later: GenericGitDestination)
  - Retry + backoff, token refresh, minimal UI error surface

### Suggested internal interfaces
- `ProcessingQueue.enqueue(batchId)`
- `Transcriber.transcribe(scanImage) -> Transcript`
- `Organizer.organize(transcript, indexSnapshot, systemRules) -> FileOps[]`
- `Vault.apply(fileOps)`
- `Indexer.rebuildIncremental(changedPaths)`
- `Retriever.retrieve(query) -> ContextBundle`
- `ChatAgent.respond(query, contextBundle, systemRules) -> ChatResponse`
- `Destination.sync(vaultDelta)`

---

## 10. LLM interaction design (Gemini)

### Prompting strategy (robust + debuggable)
Prefer multiple small calls over one huge one (configurable by “Quality mode”).

**Fast mode**
- 1 call: transcribe + structure + classify

**Balanced mode (default)**
- Call A: transcription (return text + confidence + uncertain regions)
- Call B: structure + classify + link (using index snapshot)

**Best mode**
- A transcription
- B structure
- C linking pass with additional context (topic pages, recent notes)

### Strict output schemas
LLM should output JSON for operations, plus Markdown content:
- `fileOps`: create/modify files
- `noteMeta`: title, summary, tags, links
- `sourcesUsed`: list of paths (for “Used sources” UI)
- `warnings`: uncertain text, low confidence, TODO suggestions

This prevents “LLM wrote something but we can’t apply it safely”.

---

## 11. UX flows (detailed)

### Flow A: First launch (≤ 60 seconds)
1. Welcome screen (1 page)
   - “Snap notebook pages. Search and chat with them.”
2. Permissions
   - Camera
   - Photos (optional, for import)
3. Default setup (no choices)
   - Local vault created
   - Sync OFF by default; enable backup later in Settings

### Flow B: Capture batch
1. User scans pages
2. Tap Done
3. App shows: “Saved to Inbox”
4. Background processing starts (if enabled)
5. User can swipe to Chat and ask immediately; chat can answer with whatever is already processed, and can say “Some pages are still processing.”

### Flow C: Ask a question in Chat
1. User asks
2. Retriever selects notes (hidden)
3. LLM answers grounded
4. UI shows collapsed “Used sources ▸”
5. Optional: “Apply to vault” card if changes suggested

### Flow D: Enable Sync (Settings)
1. Settings → Sync → Destination
2. Choose “Folder” (MVP) or “GitHub” (V1)
3. Authenticate / pick folder/repo
4. Confirm: “Sync runs in background”

### Flow E: Error handling (minimal)
- If processing fails:
  - Inbox item shows a small warning icon
  - Tap → “Retry”
- If sync fails:
  - Small banner in Settings and a subtle icon in header
  - Don’t interrupt capture/chat unless necessary

---

## 12. Privacy, security, and ownership
- Store auth tokens in **Keychain**.
- Provide clear disclosure: “Images are sent to the LLM provider for transcription if enabled.”
- Keep vault **portable**:
  - export as ZIP
  - export to Files folder
- Optional (later): local encryption for vault contents.

---

## 13. Performance targets (practical)
- Capture shutter latency: < 300ms perceived (post-processing async).
- Batch of 10 pages:
  - preprocessing on-device: < 10s total
  - transcription/structuring: async; user can continue
- Chat response:
  - retrieval: < 300ms local
  - model response: dependent on network; show typing indicator

---

## 14. MVP scope (recommendation)
### MVP (ship)
- Two-mode swipe UI (Capture + Chat)
- Batch capture + Inbox
- Background processing to Markdown daily notes
- Local vault + local search (FTS)
- Chat grounded in processed notes
- Folder export destination (Files/iCloud)
- Basic Settings (Processing + Export)

### V1 (next)
- GitHub destination (OAuth) + background sync
- Linking + entity pages
- “Apply to vault” updates from chat

### V2
- Johnny.Decimal strict mode
- Topic pages (MOCs) + breadcrumbs
- Advanced review/diff mode

---

## 15. Acceptance criteria (definition of done)
- A non-technical user can:
  1) Scan 5 pages in under a minute
  2) Ask “What did I write yesterday?” and get a grounded answer
  3) Export their vault folder and open Markdown files elsewhere
- The main UI never mentions Git, commits, diffs, or indices.
- When the assistant is uncertain, it marks TODO rather than fabricating.
- All generated files remain valid Markdown; no proprietary lock-in.

---

## 16. Open questions / decisions (for team)
- Decision: Default sync is OFF; users opt in from Settings when ready.
- Decision: Raw transcripts live inline under "Raw transcription" and in per-scan metadata JSON (no separate transcript files yet).
- Open: Handwriting variability - offer a "pen type" calibration step?
- Decision: Multi-notebook support is V1; MVP uses a single default notebook.

---
End of specification.md
