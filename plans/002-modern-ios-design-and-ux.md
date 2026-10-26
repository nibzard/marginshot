# Plan 002: Redesign MarginShot around pages, clear actions, and native iOS navigation

## Status and executor instructions

- Status: IMPLEMENTED — automated and simulator acceptance passed; physical-device, spoken VoiceOver, visible software-keyboard, and live-provider/backup acceptance remain pending.
- Priority: P1. Effort: L. Risk: MED overall, HIGH where import touches capture durability.
- Category: product design, usability, accessibility, and focused correctness fixes.
- Planned at: `cbe5fea`, 2026-10-26, **plus the substantial uncommitted working tree** containing the reliability implementation and earlier UI changes.
- Depends on: the implemented recovery, capture, proposal, index, and backup guarantees from plan 001. Its last full run passed 51 tests; physical-device/provider QA remains pending. This plan does not require pretending those manual checks passed.

Read this entire plan before editing. Execute phases in order and pass each gate. Preserve existing changes; HEAD alone is not the implementation baseline. This plan authorizes no publishing, real-account tests, destructive migration, or replacement of user data. Update this file and `plans/README.md` with actual results, not intended results.

First run:

```sh
git status --short
git diff --stat cbe5fea -- MarginShot MarginShotTests MarginShotUITests MarginShot.xcodeproj QA.md SPECS.md
```

Compare the current-state excerpts below against live symbols, including untracked files. Preserve the starting tracked/untracked change inventory so later scope checks distinguish the executor's changes from existing work.

## Outcome and product decisions

The user found the entire interface dated and requested a redesign plan after hands-on testing and research into current Apple guidance. Deliver a quiet, modern notebook utility with strong typography, meaningful page previews, obvious navigation, and readable recovery states. The current nested translucent pills, gradient backdrop, tiny mode controls, and empty decorative panels must be replaced at the screen-composition level.

Preserve these product principles from `SPECS.md`: fast offline-friendly capture; one obvious primary action; hidden technical complexity; grounded chat; original images and raw transcription retained; optional backup; Markdown ownership. Preserve the non-goals of rich note editing, graph visualization, and collaboration.

**Explicit revisions to the original specification:**

1. Replace the two-page horizontal mode switch with three stable native destinations: **Capture, Library, Chat**, in that order. Capture remains the launch destination. These are destinations, not buttons that immediately execute actions. Each retains its navigation state; visiting another tab must not silently finish an active batch or discard chat drafts.
2. Add a deliberately small **read-only Library** for browsing existing notes and their original pages. It is not a new note editor, organization engine, or database. The old spec's lack of a browsing destination leaves ownership and successful processing hard to see.
3. Implement **Import Photos** as a real alternate capture route using a system picker; remove broad Photos permission requests during onboarding. This fulfills an existing promise and makes camera-unavailable situations useful.
4. Let people enter the app without granting camera permission or configuring Gemini. Ask for camera access when starting capture. Keep cloud processing consent independent of backup, and never change an existing user's privacy settings during the redesign.
5. Expose export directly and move developer diagnostics out of ordinary Settings. Retain all existing user preferences and backup destinations.

Update only the affected navigation/onboarding/import/settings sections of `SPECS.md` during implementation. Do not silently reinterpret storage, model behavior, or synchronization policy.

## Research basis, checked 2026-10-26

Official Apple sources distinguish iOS 27.0.1 for regular iPhones from iOS 27.1 for iPhone Duo only; 27.2 is currently a release candidate. Do not choose the foldable simulator merely because its version number is higher. Recheck release status before implementation if time has passed.

- [Apple release status](https://support.apple.com/en-ph/100100)
- [Developer release list](https://developer.apple.com/news/releases/)
- [iOS 27 design refinements](https://apps.apple.com/us/iphone/story/id1896606813): readability, contrast, consistent refraction, and adjustable glass appearance.
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials): reserve Liquid Glass primarily for navigation/controls above content; use it sparingly; avoid glass throughout the content layer.
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass): prefer system components, remove conflicting custom bar backgrounds, respect scroll-edge effects, standard spacing, concentric shapes, and accessibility preferences.
- [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars): labeled stable destinations, preserved navigation, no action-only tabs.
- [Design-system presentation](https://developer.apple.com/videos/play/wwdc2025/356/): stronger left-aligned typography and hierarchy expressed through layout and grouping.
- [Writing](https://developer.apple.com/design/human-interface-guidelines/writing): plain language, actionable empty/error states, direct links to settings, labeled fields.
- [Reduce Motion](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria): meaningful alternatives to potentially uncomfortable animation.

The three-tab structure, read-only Library, and restrained teal identity are recommendations for this product, not Apple mandates. Retain the iOS 17 deployment target; availability-gate newer APIs and provide native older-OS fallbacks. Do not hard-code pixel approximations of current system glass.

## Evidence and current code

Hands-on review used iPhone 17 / iOS 27.0 (`1D8053E0-AB4F-44CC-9FC2-C0A46083950B`) in Device Hub. Reviewed welcome/permissions, camera failure, empty inbox, notebook creation, chat submission, and Settings. Navigation, notebook creation, and chat retention across tab switches worked. No crash was observed. Full notes are in `QA.md`; this plan includes the actionable findings so it stands alone.

| Finding | Evidence | Impact / confidence | Effort / change risk |
|---|---|---|---|
| Privacy promise conflates local storage with cloud processing | `Views/OnboardingView.swift`, welcome subtitle; Settings image-upload preference | Misleads before setup; high | S / low |
| Camera error stays green; shutter remains enabled and error truncates | `Views/CaptureView.swift:186`, `:627`, `:642`; reproduced by tapping shutter while unavailable | No useful recovery, false readiness; high | M / medium |
| Chat error directs to Settings without a route from Chat | `Views/ChatView.swift:345`; reproduced Keychain error | Recovery requires discovering another tab; high | S / low |
| Unnamed shutter, Send named “Up,” unlabeled notebook rules editor | `Views/CaptureView.swift:260`, `Views/ChatView.swift:140`, `Views/NotebookPickerView.swift:108`; accessibility tree | Critical controls unclear to assistive technology; high | S / low |
| Promised photo import has no entry point or photo picker | `Views/OnboardingView.swift:101`; UI walk and source search | Permission without usable feature; high | M / high |
| Dense nested pills truncate modest notebook names/status | `Views/CaptureView.swift`, `Views/HeaderView.swift`; “UX Test Notebook” truncates | Weak hierarchy and readability; high observation, subjective aesthetic severity | M / medium |
| Diagnostics and export toggle obscure basic settings | `Views/SettingsView.swift:440–480` | Internal terminology and unnecessary steps; high | M / low |
| No obvious place to browse completed notes | `ContentView.swift:5–48`, `VaultIndexStore.swift` | Hard to inspect results outside chat; high | L / medium |

Navigation currently uses:

```swift
// MarginShot/ContentView.swift — AppMode and ContentView
case capture
case chat
// ...
.tabViewStyle(.page(indexDisplayMode: .never))
```

Capture readiness currently ignores session health:

```swift
// MarginShot/Views/CaptureView.swift — CaptureViewModel
var canCapture: Bool {
    permissionState == .authorized && !isProcessing
}
// statusTint returns .green for authorized regardless of session error.
```

`CameraController` is defined **inside `Views/CaptureView.swift`**, around line 1072, not in a separate file. It has private `isConfigured`, a serial `sessionQueue`, and `onSessionError`, but no published session-readiness contract. `handlePhotoCapture` around line 795 places the original through `CaptureStore`, persists metadata, then preprocesses and saves the processed image.

```swift
// MarginShot/Views/AppTheme.swift — AppTypography
static let body = Font.custom("AvenirNext-Regular", size: 16, relativeTo: .body)
// ChatView inputBar also wraps a rounded text field in another material panel.
// MarginShot/Views/NotebookPickerView.swift
TextEditor(text: $rulesDraft)
    .font(.system(.body, design: .monospaced))
    .frame(minHeight: 180)
```

Other relevant ownership:

- `MarginShotApp.swift`: app launch, test launch flags, persistence injection, recovery entry point. Existing `-ui-testing-reset` only sets onboarding completion false; it is not an isolated data fixture.
- `CaptureStore.swift`: journaled originals and recoverable sidecars, stable scan/batch IDs; filenames currently end `-raw.jpg`.
- `Views/CaptureView.swift`: also contains InboxSheet, scan rows, camera preview, preprocessing, and processed-file helpers. Extract UI components only when needed; avoid unrelated rewrites.
- `VaultIndexStore.swift`: `IndexNoteEntry`, rebuildable index, retrieval; current `loadIndexSnapshot` is private. A bounded read API for Library will need to be introduced, not assumed to exist.
- `VaultNoteMetadataStore.swift`: committed note sidecars and IndexWorker. `VaultRepository`/`VaultFileStore`: coordinated, encryption-aware content access.
- `ChatAgent.swift` / `Views/ChatView.swift`: grounded retrieval, proposals, revision-aware apply, conversation state.
- `Views/ApplyReviewView.swift`: existing review sheet; preserve the review-before-apply setting and stale-proposal rejection.
- `SyncStatusStore.swift` / `Views/HeaderView.swift`: distinguish off, waiting, syncing, backed up, and error. Successful capture never implies backup success.

SwiftUI/Swift conventions: four spaces, UpperCamelCase files/types, lowerCamelCase members, focused services outside views. Reuse the existing `NavigationStack` + `.toolbar` pattern from `ApplyReviewSheet`, and injected roots/defaults from `ReliabilityVaultFixture` in `VaultIndexRecoveryTests.swift`. Explicitly add new app/test files to `MarginShot.xcodeproj/project.pbxproj`.

## Design contract

### Shared visual system

- Use system text styles and system font for UI. Large, leading-aligned screen titles; clear body text; secondary metadata that remains readable. Avoid shrinking status text to make a crowded row fit.
- Use semantic system backgrounds and text colors with one restrained teal accent. Define accessible light/dark/high-contrast accent variants. Page thumbnails and note content provide visual interest; remove the global cream-to-blue wash and decorative gradients behind empty content.
- Native navigation bars, tab bar, toolbars, sheets, menus, and scroll-edge behavior. Apply custom glass only to a functional control that genuinely needs it, never as a second wrapper around system glass.
- Use 16–20 pt content margins as a starting rhythm, consistent spacing tokens, and at least 44 × 44 pt interactive targets. Allow vertical reflow at accessibility text sizes; do not force every toolbar item onto one row.
- Reserve filled accent treatment for the primary action/selection. Errors use text plus an icon, not color alone. Saved, processing, paused, and backed up are separate states.
- No custom bouncy idle animations. Use system transitions, brief state feedback, and meaningful capture confirmation; honor reduced motion/transparency and increased contrast.

### Capture

Edge-to-edge camera preview with a minimal top toolbar: notebook selector and Settings. One prominent shutter, an Import Photos action, and a small recent-page preview/count. After the first durable save, expose **Finish** clearly. Remove “Batch: On” and the always-present multi-chip dashboard. A readable status line is separate from controls.

States: requesting permission, configuring, ready, capturing/saving, saved, unavailable, interrupted, and failed. Only a running/configured/active camera can enable the shutter. Permission denial shows **Open Settings** and **Import Photos**; simulator/no-camera shows **Import Photos** without an impossible permission remedy. Configuration/interruption recovery exposes **Try Again** only when useful. Never display a green ready marker for a failed session.

Changing tabs pauses the camera, retains the active batch, and restores it when returning. Changing notebook applies to the next batch; show the current batch's notebook until Finish. Saving an original and metadata must succeed before any “Saved” confirmation. Failed preprocessing retains the original and a retryable scan.

### Library

Title **Library**, native search, Settings access, and a single **Pending scans (N)** row when needed. Show completed notes as a lightweight list: title, useful excerpt, date, and a page thumbnail only when an actual source association exists. Avoid dashboards, charts, tag clouds, and a card around every row.

Read-only note detail: title/date, rendered Markdown, collapsed raw transcription when it can be separated without altering content, and **Original pages** when durable metadata proves their association. Otherwise show complete text faithfully. Provide readable raw-text fallback for unsupported Markdown. Source links from Chat open this same detail view. Never infer that all scans in a day belong to one note.

Search is local. Empty Library offers **Scan a page** and **Import Photos**. No search results retains the query and offers **Clear search**. Index/recovery/key errors show a retry/recovery state, never an empty Library. Pending scans retain the existing job states, batch grouping, and retry actions. No new note creation/editing/deletion UI in this plan.

### Chat

Title **Chat**, persistent Settings access, one stable conversation, a simple keyboard-safe composer with a named **Send message** action. Preserve draft, scroll position, sources expansion, preferred batch, and in-flight operation state across navigation. Avoid auto-scrolling a person reading earlier messages unless they send a message or are already at the bottom.

Distinguish no captures, processing pending, no usable API key, Keychain failure, index unavailable, ready, and response failure. Offer the appropriate action: **Scan a page**, **View pending scans**, **Set up Gemini**, **Open Settings**, or **Try Again**. Keep an entered draft when setup blocks submission. Do not promise ready answers for unfinished processing.

Sources appear only on answers with sources. Keep apply success, applying, and stale-conflict states, stable operation IDs, and existing optional review. Label a conflict with **Refresh and review**; do not automatically apply a regenerated proposal. No fake content or provider response in production.

### Settings and notebooks

Use native grouped forms and focused detail screens:

1. **Processing**: Gemini setup/status, explicit image-upload permission, quality, Wi-Fi/charging constraints.
2. **Backup**: destination, actual pending/success/error state, **Back up now**, constraints. Keep existing folder and GitHub settings, manifests, and authorization flows.
3. **Privacy & Data**: encryption with nearby explanation, direct **Export notes** action and progress/error feedback. Explain encrypted ZIPs contain ciphertext and exclude the device-only key; turning encryption off does not decrypt older files.
4. **Organization**: notebook management and existing organization preferences. Rules are behind a clearly labeled editor with helper text and a visible save state.
5. **Advanced**: existing review preference and system rules. Diagnostics move to a Debug-only or explicit support screen; no “SPECS” references in product copy.

Keep existing UserDefaults keys and values when moving controls. Removing the export-enable switch only removes a visibility gate; do not alter encryption/export semantics. Never auto-enable upload/backup or weaken Keychain handling to make the simulator demo work.

### Onboarding and language

A concise welcome explains: originals are saved locally; Gemini receives selected content when processing/chat is used; backup is separately optional. Let the person **Start scanning**, **Import Photos**, or enter without granting permissions. For a new installation, require an explicit processing choice before any first image upload; declining keeps captures local and pending. Preserve an existing installation’s recorded choice and do not re-enable uploads through onboarding replay. Ask for camera permission at the camera action; do not require broad photo-library access for a system selection picker.

Use consistent words: **page** for a captured image, **note** for processed content, **pending scans** for the queue, **backup** for the one-way destination copy. Keep “vault” for advanced/storage explanations. Example labels: **Process scans with Gemini**, **Instructions for this notebook**, **No scans waiting**, **Camera unavailable**. State what is sent for chat as well as image processing; do not imply the image toggle blocks text requests.

## Scope and protected boundaries

In scope: `ContentView.swift`, `Views/AppTheme.swift`, `Views/HeaderView.swift`, `Views/CaptureView.swift`, `Views/ChatView.swift`, `Views/SettingsView.swift`, `Views/OnboardingView.swift`, `Views/NotebookPickerView.swift`, `Views/SystemRulesEditorView.swift`, `Views/ApplyReviewView.swift`; new focused view/support files for navigation, Library, note detail, import, capture presentation state, and deterministic UI fixtures; `MarginShotApp.swift` for dependency/fixture wiring; `CaptureStore.swift` only for compatible import format support; `VaultIndexStore.swift` for bounded Library/readiness reads; `GeminiClient.swift`/`ChatAgent.swift` only for side-effect-free configuration/readiness/error adapters; `SyncStatusStore.swift` only for presentation; relevant assets, test files, project membership, `Info.plist` permission copy, `SPECS.md`, `QA.md`, and `plans/`.

Out of scope: journal/revision formats, Core Data schema/migrations, sync engine/adapters/auth redesign, processing/model/prompt redesign, new providers, rich text editing, graph features, billing, cross-device encryption recovery, app-icon replacement, deployments, dependency/framework swaps. Do not remove original files, rewrite existing vaults, or migrate notebook identities. Reuse existing durable services rather than moving storage logic into Library/import views.

Import is the only intentional capture extension: preserve exact bytes returned by the picker with a validated matching JPEG/PNG/HEIC extension. Extend `placeOriginal` with a defaulted format argument so existing camera callers and old `-raw.jpg` paths remain valid. Derive format from decoded data/type metadata, never an arbitrary user path. Retain `CaptureRecord.rawPath` and existing schema. Preprocessed images may be JPEG. If preserving the picker representation cannot be guaranteed, document that originals mean the selected representation; do not claim a hash match to an inaccessible Photos master.

## Commands and environments

Use the known regular iPhone simulator, or discover/recreate an equivalent if missing. The previous suite used Duo; record which runtime each new result actually uses. No package installation is required.

```sh
xcrun simctl list devices available
xcodebuild -showdestinations -project MarginShot.xcodeproj -scheme MarginShot
xcodebuild build-for-testing -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination 'platform=iOS Simulator,id=1D8053E0-AB4F-44CC-9FC2-C0A46083950B' -parallel-testing-enabled NO -derivedDataPath ./DerivedData -only-testing:MarginShotTests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination 'platform=iOS Simulator,id=1D8053E0-AB4F-44CC-9FC2-C0A46083950B' -parallel-testing-enabled NO -derivedDataPath ./DerivedData -only-testing:MarginShotUITests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination 'platform=iOS Simulator,id=1D8053E0-AB4F-44CC-9FC2-C0A46083950B' -parallel-testing-enabled NO -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO
xcodebuild build -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS' -derivedDataPath /tmp/marginshot-design-device-build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: exit 0, BUILD/TEST SUCCEEDED, no failed tests, no whitespace errors. Serialize builds sharing DerivedData. Do not hard-code new test counts before they run. Generic device compilation proves compilation only, not camera/Keychain/background behavior.

Git: work in the preserved tree or explicitly transfer the complete working state to `~/dev/.worktrees/marginshot/modern-ios-design`. Never start from bare HEAD and lose plan 001. Conventional Commits if commits are requested, e.g. `feat(ui): introduce native navigation and library`. Do not push. Remove a worktree only after needed tracked, untracked, and ignored artifacts are preserved.

## Phases and gates

### 0. Establish the baseline and deterministic screen fixtures

Run baseline build and unit suite. Introduce Debug-only, explicitly opted-in fixtures with isolated vault roots, defaults, and Core Data stores. Fixtures must never overwrite the current simulator's normal data or use a real Gemini key. Existing test launch flags alone do not supply this isolation. Disable network/background work for fixture mode and inject a fake camera, chat responses, and configuration states. Production follows normal AppRecovery.

Prepare empty, populated, processing, paused, failed, encrypted, and stale-proposal fixtures using synthetic content. Include a long notebook name, a long note title, multiple pages, and a realistic multi-paragraph answer. Use these fixtures for all subsequent screenshots and UI tests. Capture the current screens for comparison and add a state checklist under `plans/002-design-evidence/`.

**Gate:** build-for-testing and unit commands pass; a fixture launch reads/writes only its scoped root; normal launch retains existing data. No external requests occur. This phase introduces no visual overhaul.

### 1. Build the design system and navigation shell

Replace Avenir-based UI tokens with system styles and semantic surfaces. Introduce shared spacing/appearance tokens and native toolbar patterns. Implement labeled Capture/Library/Chat tabs, per-tab navigation state, and Settings presentation reachable from every destination. Update the original spec's navigation contract explicitly. Keep the Library destination as an honest empty/loading view until phase 3; do not ship a fake populated screen.

Retire HeaderView's custom mode switch and duplicated brand capsule after callers migrate. Preserve sync status as a secondary, actionable backup indicator rather than an always-dominant chip. New APIs must be availability-gated; no deployment-target increase.

**Gate:** build-for-testing and focused UI tests pass for all three tabs, Settings from each tab, chat draft retention, and Capture as initial destination. Render light/dark empty/populated shell screenshots at default and accessibility text sizes. Resolve clipped controls before phase 2; record visual review, not merely test success.

### 2. Make Capture, onboarding, and import coherent

Expose a typed camera session state from CameraController on the main actor, driven by its serial session work and runtime interruption/error notifications. Derive shutter readiness and status from permission plus session plus saving state. Add labels, readable errors, useful retry/import actions, and permission-on-demand onboarding. Remove the misleading local-only promise and upfront Photos permission request.

Factor the existing post-capture ingestion path so camera and Photos selection share original placement, metadata persistence, preprocessing, retry state, and stable batching. Do not duplicate this pipeline inside the picker callback. Support cancellation, corrupt/unsupported images, picker load failure, and partial multi-selection failure. Process selections sequentially or with an explicitly bounded concurrency; retain every already-saved original. Never silently drop pages or finish a live batch while switching tabs.

Implement the uncluttered preview/shutter/recent-page layout and explicit Finish feedback reflecting actual processing eligibility. Select a synthetic picker image on the simulator for an end-to-end local path; stop before real provider use.

**Gate:** build and unit suite pass, including new capture-state/import tests. UI tests assert unavailable camera disables shutter, import remains accessible, permission denial does not block Library/Chat, two imported pages share a batch, and Finish queues once. Existing capture/recovery/privacy tests remain green. Inspect ready/unavailable/saving/paused states visually.

### 3. Make completed work visible in Library

Add an immutable Library snapshot service using existing repository/index boundaries. Rebuild/retry derived metadata through IndexWorker; expose failures distinctly. Perform file decoding, thumbnail loading, and index work off the main actor; bound/cancel obsolete searches and thumbnail tasks. Do not rebuild synchronously for every keystroke or use chat's truncated retrieval bundle as full note content.

Implement list/search, read-only detail, verified original-page associations, pending scan navigation, and source deep links. Preserve encryption: decrypted display data stays in memory where possible; do not add a plaintext search database or persistent thumbnail cache for encrypted vaults. Any existing temporary preview mechanism must retain cleanup behavior. Disallow path traversal/external file access in note links; unsupported links remain inert or require explicit external navigation.

Reuse pending-scan/retry logic from InboxSheet through shared UI/service adapters; do not require a running camera view model to browse notes. Avoid new Core Data entities. Preserve notebook selection across routes.

**Gate:** unit tests cover missing/corrupt index, encrypted content, bounded search, correct source association, and recovery errors that do not render as empty. UI tests cover list → detail → original pages → back, no-results, pending retry, and Chat source → detail. Run full unit suite and inspect populated layouts with long titles and mixed content.

### 4. Complete Chat and simplify Settings

Introduce explicit readiness/error presentation without invoking network or attempting Keychain migration during view rendering. Keep credentials in existing secure storage; classify missing configuration and secure-storage failure separately. Provide Settings deep links to the relevant section, preserve drafts, and restore focus appropriately after returning.

Use a native keyboard-safe composer, readable message layout, actual source disclosure, and clear apply states. Preserve stable chat operation IDs and expected revisions. Implement Settings grouping and direct export, label notebook/system-rule editors, and provide local save feedback. Do not modify existing users’ preference values while renaming labels. Any fresh-install processing-consent initialization must be explicit, tested, and leave existing preferences intact. Keep cloud processing, cloud chat, backup, and local encryption explanations separate and accurate.

**Gate:** focused UI tests pass for setup-blocked drafts, Settings navigation, simulated request failure/retry, source disclosure, apply success, stale-proposal rejection, keyboard show/hide, and export progress/error. Existing proposal/privacy/export tests pass. Inspect multi-line composer, long response, settings, and notebook editor in light/dark modes.

### 5. Verify the complete experience and retire old presentation

Run the full suite and generic device build, then the visual/device matrix below. Remove unused old header/pill wrappers only after all callers use the new shell. Verify storage/index/sync tests remain intact and original data is unchanged by browsing. Update QA, spec, this plan, and index with exact commands, environments, counts, screenshots, and unresolved limitations.

**Gate:** full automated suite passes, `git diff --check` passes, and all relevant visual states are reviewed. Mark automated completion separately from physical-device/provider coverage. No design-complete claim if major clipping, inaccessible actions, misleading privacy copy, or unusable empty/error flows remain.

## Test and visual acceptance matrix

Use existing `MarginShotUITests.swift` for XCTest style and screenshot attachments, `CapturePersistenceTests`/`ProcessingRecoveryTests` for durable capture, `GeminiPrivacyTests` for fake transport, and `VaultIndexRecoveryTests`/`VaultProposalTests`/`VaultExportTests` for storage guarantees. Add focused files for camera presentation state, imported capture, Library reads, and deterministic UI flows; avoid brittle tests asserting exact decorative pixel positions.

Required automated assertions:

- Shutter enabled only for ready session and disabled while saving; unavailable/interrupted states have accessible actions and labels.
- Import cancellation creates no records; two valid images create one batch; a bad selection leaves valid originals recoverable; restart preserves hashes/identity; existing JPEG records remain readable.
- Tab changes retain active batch, draft, conversation, and selected note navigation; Settings is reachable from every tab.
- Onboarding can complete without camera/Photos access; no upload/backup preference silently changes.
- Library empty, no-results, and unavailable are distinct; browsing never changes note hashes; encrypted reads create no persistent plaintext artifacts.
- Configuration errors preserve drafts; stale apply leaves newer bytes untouched; repeated apply does not duplicate edits.
- Every primary icon-only action has a task-oriented accessibility name; required error/action text is not truncated.

Capture screenshot evidence for onboarding, Capture ready/unavailable/batch, empty/populated/search Library, note detail, empty/setup/error/populated Chat, composer with software keyboard, Settings, notebook editor, and stale apply. For the core Capture/Library/Chat screens check light/dark at default, XXXL, and an accessibility text size on the regular iPhone. Check one smaller supported phone width and landscape where supported. Verify contrast/reduced transparency/reduced motion; record pass/fail notes, not only images.

Run VoiceOver through tabs, capture/import, pending scans, note detail, chat send, and Settings. Check focus order, selected-state announcements, and actionable errors. The hardware-keyboard-only walkthrough from the prior review is insufficient for composer acceptance.

On an authorized signed physical device: multi-page camera capture, permission denial/recovery, interruption and background/foreground, local save/relaunch, real Photos picker selection, Keychain save/read, and camera framing. Live Gemini/folder/GitHub tests require authorized disposable data/accounts and are reported separately. Do not treat simulator camera absence or unsigned Keychain limitations as production failures, or bypass those protections to obtain green screenshots.

## Done checklist

- [x] Native labeled destinations and shared Settings routes replace the old mode switch.
- [x] Design contract is visible in real empty/populated/error screens, including dark and large text.
- [x] Camera readiness, import, and durable batch regressions pass.
- [x] Read-only Library/search/detail use existing durable content and preserve encryption.
- [x] Chat setup/recovery, sources, and stale-apply flows are usable and tested.
- [x] Onboarding/privacy text matches actual data flows; photo import is real; export is directly discoverable.
- [x] Existing reliability suite plus new meaningful tests pass; exact test count recorded.
- [x] Generic device build and diff check pass; no deployment-target or data-schema change.
- [x] Visual screenshots and accessibility/device limitations recorded in QA evidence.
- [x] Executor changes stay within scope relative to the preserved starting inventory.
- [x] `SPECS.md`, `QA.md`, this plan, and `plans/README.md` reflect delivered behavior.

## Stop conditions and maintenance

Stop the affected phase if live storage behavior differs materially from plan 001, fixture isolation cannot be demonstrated, import would discard/replace originals, encryption requires a new key/export format, Library requires a new schema, a durable test regresses twice after a reasonable correction, or scope would require a new provider/auth flow. Report evidence and preserve user data; do not reset stores, waive privacy tests, or invent model responses to finish a demo.

If a new system API is unavailable on supported targets, use native fallback UI; do not raise the minimum OS silently. If a physical device/provider is unavailable, record the exact unverified scenarios and complete the independent simulator work.

Future reviews should examine meaningful content/error states and accessibility settings alongside visual polish. Keep brand decisions in a small shared token layer, keep durable operations in services, and recheck native navigation/material behavior with new SDKs. Defer app-icon artwork, richer note editing, advanced filtering, new sync destinations, and cross-device restore to separate plans.


## Execution record — 2026-10-26

Work remained in the preserved working tree. Starting tracked/untracked inventory: `002-design-evidence/starting-status.txt`; no commit, push, deployment, schema change, or vault migration was performed.

- Baseline generic simulator build-for-testing passed; baseline regular-iPhone unit suite passed **49 tests**, 0 failures. The earlier recorded 51 comprised 49 unit + 2 UI tests.
- Phase 0 introduced explicit `-design-fixture <state>` Debug launches with UUID-scoped vault roots/defaults and in-memory Core Data. Production retains AppRecovery. Fixture launch bypasses workers, real credentials, and provider traffic. An initial UI run exposed missing `DEBUG` compilation conditions in the project; those runs used normal startup and are not counted as fixture-isolation evidence. Debug conditions were fixed and the isolated UI gate rerun successfully. No real-account/provider request was intentionally initiated; no stores were reset.
- Phase 1 native Capture / Library / Chat tabs, independent navigation, shared Settings routes, semantic surfaces, and system text styles implemented. Navigation/draft test passed after resolving XCTest's multiline-field type ambiguity via accessibility identifiers.
- Phase 2 typed camera readiness, runtime/interruption handling, permission-on-demand onboarding, explicit consent initialization, and sequential system picker import implemented. PNG/JPEG exact bytes, shared batch/notebook identity, invalid data, recovery, and Finish-once tests passed. The system picker imported **two synthetic screenshots** end-to-end locally. An initial picker test queried collection cells; this runtime exposes images. The query was corrected to seeded screenshot images and passed. Photo-library master equality is not claimed.
- Phase 3 strict bounded Library reads, cancelable/debounced searches, read-only full note detail, verified sidecar associations, in-memory thumbnails, raw fallback, pending scans, and Chat source links implemented. **57 unit tests** passed at this gate. List/detail/original-pages/back/search/no-results UI passed after making the native search drawer consistently visible.
- Phase 4 side-effect-free configuration inspection, setup recovery routes, simple keyboard-safe composer, request retry, stale refresh with mandatory review, focused Settings, direct export, and labeled notebook/system-rule editors implemented. **60 unit tests** passed. Targeted draft/setup deep link, failure/retry/source detail, export error, batch retention, picker cancellation, and stale-review flows passed. The Processing deep-link test exposed a split-state sheet route; switching to an item-based route fixed it.
- Phase 5: full regular-phone run `Test-MarginShot-2026.10.26_18-45-41-+0100.xcresult` passed: **60 unit tests + 17 UI tests executed**, with the **two disposable-small-simulator-only UI tests skipped**, 0 failures. Both skipped cases passed separately on the 375-point SE simulator in `Test-MarginShot-2026.10.26_18-43-52-+0100.xcresult`.
- Final focused run `Test-MarginShot-2026.10.26_18-55-12-+0100.xcresult` passed **61 unit tests and 5 UI tests**, including the revised full core visual matrix, Chat recovery, durable batch retention, and labeled notebook instructions/save. A final full unit rerun after strengthening bounded-search assertions also passed **61 tests**, 0 failures. The notebook feedback check was repeated after keeping its save status visible in a bottom inset; it passed.
- Debug and Release unsigned generic iOS builds passed after final source changes. Release excludes fixture data and fake provider implementations. `git diff --check` passed; all deployment-target entries remain **17.0**.
- Final fixture audit compared **13 normal vault/Application Support files** against a pre-fixture hash inventory: unchanged. Early invalid UI-launch attempts are documented separately and are not counted as isolation evidence. No normal data was reset.
- Reviewed evidence: 73 durable PNG screenshots plus contact sheets under `002-design-evidence/screenshots/`. Capture large-text crowding was fixed; whole-screen landscape evidence replaced cropped app-only artifacts. Light/dark, default/XXXL/accessibility 3, empty/populated, small width, landscape, real system increased contrast/reduced motion/reduced transparency, recovery, note/source, and editor states were reviewed. Content exceeding a viewport remains natively scrollable.
- Scope audit: executor changes are confined to the plan's presentation/navigation/import/Library/readiness seams, project membership, focused tests, permission copy, specifications, QA and plan evidence. Existing reliability edits and tracked/untracked work were preserved. No journal/revision format, Core Data entity/schema, sync/auth policy, dependency, or deployment-target change was introduced.


### Manual acceptance still pending

Implementation and independent simulator work are delivered; this is not a claim that all device/design acceptance has passed. No physical device was connected. Real camera/Photos/Keychain/background behavior, spoken VoiceOver focus/announcements, older runtime behavior, and authorized live Gemini/folder/GitHub checks remain pending. Composer action/draft tests pass, but the simulator keyboard accessibility frame is below the viewport; visible software-keyboard and multiline-keyboard acceptance is explicitly unverified. See QA.md for the exact frame and evidence. No privacy or Keychain protection was bypassed.
