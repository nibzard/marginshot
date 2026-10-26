# QA Plan

## Automated verification — 2026-10-26

Tests run against isolated temporary vaults, defaults, and Core Data stores. Privacy and processing requests use controlled transports; backup race cases use fake destinations. No real user vault or provider credentials are used.

- Capture: multiple pages share one stable batch; Done queues that batch; interrupted placement/metadata saves recover one original and scan; page retries preserve earlier originals.
- Migration and processing: additive v1 migration preserves identities and image hashes and retains a SQLite backup; stale jobs recover; cancellation and privacy revocation pause; saved transcription/organization resume without uploading images again; committed filing replays without duplicate contributions.
- Vault transactions: every journal checkpoint rolls forward to exact contents/revisions; stale expectations fail; failed recovery retains staging and live edits and blocks readers; encrypted staging and receipts remain protected; path traversal and symlinks are rejected.
- Backup: repeated folder replacement preserves source bytes; upload races retain newer pending revisions; partial success, termination before acknowledgment, failed deletion, ownership, destination changes, constraint deferral, and coalesced wakeups are covered.
- Search and chat: missing, corrupt, or valid-but-empty indexes rebuild from Markdown and metadata; interrupted indexing retries without losing notes; encrypted retrieval leaves no plaintext SQLite; delayed proposals cannot overwrite newer content or invent trusted revisions.
- Export: ZIP contains exact stored Markdown/image bytes, excludes recovery internals, and preserves encrypted bytes when enabled.
- UI smoke: fresh onboarding and Settings after completed onboarding/startup recovery, with screenshot attachment.

Phase-by-phase logs and final counts are recorded in [the implementation plan](plans/001-reliable-capture-vault-and-sync.md). Final full suite passed: **51 tests (49 unit/integration, 2 UI), zero failures and zero skips**, on iOS 27.1 simulator `B120CF6D-629C-4851-A66C-79C28976CB69`. Generic iOS device Release compilation and `git diff --check` also passed. A simulator UI-runner launch failure was resolved by disabling test parallelism for the final run.

## Physical-device and provider QA — not run

No physical device was available (`xcrun devicectl list devices` listed only simulated devices). Simulator tests and generic device compilation do not verify camera capture, Keychain entitlements on signed devices, provider bookmarks, or iOS background scheduling. No live Gemini, GitHub, or Files-provider integration was exercised.

Run this journey on a signed device using a disposable test vault and authorized provider accounts:

1. Complete onboarding, deny camera permission, open Settings, then grant permission and capture multiple pages offline. Confirm one batch, durable Saved status, originals, and successful Done.
2. Terminate after capture, during preprocessing/transcription, after structured output, and during filing. Relaunch and verify retained originals, resumed jobs, and exactly one note contribution per scan. Legacy structured work without a receipt should request review.
3. Disable image uploads while a request is in flight. Confirm subsequent pages and retries do not upload, jobs show paused, and restoring permission resumes eligible work. Cancel on the last scan and verify the batch remains resumable.
4. Select a folder backup, back up, edit a note, and back up repeatedly. Verify both local and destination bytes. Change a note during upload and confirm its newer revision remains pending. Delete a previously backed-up file offline, then verify deletion propagates without removing unrelated destination files.
5. Set Wi-Fi/charging constraints, make pending edits, and confirm Backup pending. Restore eligibility and verify foreground/manual backup. Background opportunities should be recorded separately; iOS does not guarantee immediate execution.
6. Exercise the same revision/partial-failure behavior against an authorized GitHub test repository. Remote conflict behavior remains one-way local-vault-authoritative; do not use a repository containing unrelated valuable files for QA.
7. Generate a chat proposal, edit/delete its target before Apply, then confirm Apply rejects it with a refresh/review action and preserves the newer content. Remove disposable derived indexes and confirm retrieval reconstructs the same notes.
8. Enable local encryption on a populated vault, relaunch during migration, and confirm recovery, encrypted stored files, no plaintext search database, and successful retrieval. Test signed-device key availability after lock/restart. Never discard the only encrypted vault copy if a key is unavailable.
9. Export both unencrypted and encrypted test vaults. Verify unencrypted Markdown opens normally and original image hashes match. Verify encrypted exports retain ciphertext and exclude internal recovery staging.

## Export and recovery limitations

Encrypted ZIP export preserves existing stored-byte semantics. Markdown and originals remain encrypted; the encryption key is stored in device-only Keychain and is not included in the ZIP. An encrypted export alone is not a portable cross-device restore or key-recovery mechanism. Disabling encryption does not automatically decrypt previously stored files.

Journal recovery rolls forward after durable intent. If an external edit conflicts with both the old and intended hash, recovery stops and preserves live data plus before/after copies. Do not reset the store or delete staging to bypass this error. Migration retains a v1 SQLite backup; unknown store versions fail without a destructive reset.

## Test commands

```sh
xcodebuild build-for-testing -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO
xcodebuild -showdestinations -project MarginShot.xcodeproj -scheme MarginShot
# Substitute an available simulator UUID.
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' -parallel-testing-enabled NO -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO
xcodebuild build -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS' -derivedDataPath /tmp/marginshot-device-build CODE_SIGNING_ALLOWED=NO
git diff --check
```

## Hands-on UI/UX review — iPhone 17, iOS 27.0, 2026-10-26

Reviewed the running Debug build on `MarginShot-iPhone` (`1D8053E0-AB4F-44CC-9FC2-C0A46083950B`) through Device Hub. Inspected rendered screens and accessibility trees; exercised onboarding, Capture/Chat navigation, shutter failure, empty inbox, notebook creation/selection, chat submission, and Settings scrolling. Replayed onboarding using its existing test launch flag, which changes only onboarding completion; completed it again afterward.

Working: onboarding transitions and modal Done actions; notebook creation and selection; chat composer/send state; chat conversation retention across tab switches; readable chat bubbles; consistent teal accent, rounded surfaces, and spacing. No crash was observed in these interactions. Returned to Capture with Default selected. The simulator retains a synthetic `UX Test Notebook` created for this review.

| Priority | Observed finding | Recommended correction |
|---|---|---|
| P1 | Welcome says “Notes stay local until you enable sync,” but Settings independently enables image processing. This suggests a stronger privacy guarantee than the app provides. | Explain local storage, Gemini processing, and optional backup separately before asking for permissions. |
| P1 | With the camera unavailable, Capture still has a green status dot and enabled shutter. Tapping it changes the message to “Capture failed: Camera session not configured.” Both messages truncate to a few words in the chip. | Base readiness on camera session state, disable capture when unavailable, and show a readable error with a useful next action. Camera unavailability itself is expected in this simulator. |
| P1 | Chat submission returns “Chat couldn't store your API key securely. Open Settings and re-save your key.” Chat has no Settings entry or error action; reaching it requires switching to Capture. | Provide an Open Settings action on the error and persistent access from Chat. Validate configuration before inviting a first question. The unsigned simulator Keychain failure is not evidence of a signed-device failure. |
| P1 | Main shutter appears as an unnamed button in the accessibility tree; chat Send is named “Up.” | Add task-oriented names such as “Capture page” and “Send message,” plus appropriate disabled-state guidance. Full VoiceOver interaction was not run. |
| P2 | Onboarding requests Photos access and promises importing, but no photo import action was found on Capture, in Settings, or in a source search for photo pickers. | Implement an obvious import entry point or remove the unsupported permission/promise until available. |
| P2 | Notebook Details contains a large blank rules editor without a visible label/placeholder; its accessibility node is also unlabeled. | Label it “Instructions for this notebook,” show an example, and place the explanation beside it. Consider a separate advanced editor. |
| P2 | Capture toolbar truncates both error status and the modest-length “UX Test Notebook” name. Tiny labels sit in several nested translucent pills despite ample unused screen area. | Put status/error on its own readable row and simplify notebook/inbox/settings controls. Preserve space for longer names and larger text. |
| P2 | Empty Chat invites a question before setup/readiness, with the unhelpful sentence “Used sources stay hidden until expanded.” Empty Inbox only says “Inbox is clear.” | Explain the next action: capture/import a first page, configure processing, or view ready notes. Introduce source disclosure when there are actual sources. |
| P2 | Settings exposes “Targets align with the performance budgets in SPECS,” raw latency/throughput targets, and a switch to reveal ZIP export. Encryption has no nearby explanation of key/export limitations; the section footer instead explains image uploads. | Move diagnostics behind developer/support controls, expose Export directly, and explain encryption and cloud processing next to their own controls. |

Scope limits: this was light appearance at default text size on one iPhone size. Dark mode, Dynamic Type, landscape, the software keyboard, full VoiceOver navigation, real camera scanning, populated scan review, successful model answers, proposal application, export sharing, and live destination backup still need hands-on coverage. Hardware-keyboard input was used for the composer. No credentials were entered or privacy settings changed. Source inspection supported specific findings; no implementation changes were made during this review.

## Plan 002 — modern iOS design implementation (2026-10-26)

Environment: Xcode 27.1 (27A9275); regular iPhone 17 simulator `1D8053E0-AB4F-44CC-9FC2-C0A46083950B`, iOS 27.0 / 24A434. Additional width/landscape/accessibility checks used a newly created iPhone SE (3rd generation), `86DBE198-8A1A-461A-940F-5F98D57566AE`, on the same runtime. The iPhone Duo runtime was not used for these results. Deployment target remains iOS 17.

Delivered native Capture / Library / Chat destinations with retained navigation, batch, draft, and conversation state; shared Settings routes; system type and semantic surfaces; typed camera health; sequential photo import through durable ingestion; explicit processing consent; read-only local Library/search/detail/original pages; Chat recovery/source links/stale review; focused Settings and direct export. Existing reliability/storage/sync formats and preferences remain intact.

Automated evidence:

- Baseline build-for-testing passed; 49 unit tests passed before redesign work.
- Full regular-phone run at `DerivedData/Logs/Test/Test-MarginShot-2026.10.26_18-31-20-+0100.xcresult`: 60 unit + 14 UI tests passed, 0 failures.
- Full regular-phone run at `DerivedData/Logs/Test/Test-MarginShot-2026.10.26_18-45-41-+0100.xcresult`: 60 unit + 17 UI tests executed; the two disposable-small-simulator-only tests were skipped, all remaining tests passed. This includes native tab/draft retention, permission-free onboarding, unavailable shutter/import, two real system-picker selections, batch retention/Finish, Library detail/originals/search, pending retry, setup-blocked drafts, request retry/sources, export failure, and stale refresh/review.
- Small-phone run at `DerivedData/Logs/Test/Test-MarginShot-2026.10.26_18-43-52-+0100.xcresult`: both focused tests passed. Portrait and landscape were captured at 375-point portrait width with Increase Contrast enabled. Reduce Motion and Reduce Transparency were enabled through the simulator's actual Settings interface, then Capture/Library/Chat were checked. These settings affect only the newly created disposable simulator.
- Subsequent focused acceptance reruns include the new undecodable-camera-original regression, full unit suite, revised Capture/Library visual matrix, notebook instructions save feedback, and Chat recovery. Final focused run `Test-MarginShot-2026.10.26_18-55-12-+0100.xcresult` passed 61 unit + 5 UI tests, 0 failures. The final complete unit rerun passed 61 tests after strengthening pagination assertions. A final notebook feedback UI rerun passed after making its status persist visibly.
- Unsigned generic iOS device builds passed in both Debug and Release. Release excludes synthetic fixture content and fake provider implementations. Compilation does not establish hardware behavior.
- `git diff --check` passed. No publishing, commits, pushes, real-provider calls, or real-account tests were performed.

Reproduction commands (serialize calls sharing DerivedData):

```sh
xcodebuild build-for-testing -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO
xcrun simctl addmedia 1D8053E0-AB4F-44CC-9FC2-C0A46083950B plans/002-design-evidence/capture-unavailable.png plans/002-design-evidence/library-populated.png
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination 'platform=iOS Simulator,id=1D8053E0-AB4F-44CC-9FC2-C0A46083950B' -parallel-testing-enabled NO -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO
xcrun simctl ui 86DBE198-8A1A-461A-940F-5F98D57566AE increase_contrast enabled
xcodebuild test -project MarginShot.xcodeproj -scheme MarginShot -destination 'platform=iOS Simulator,id=86DBE198-8A1A-461A-940F-5F98D57566AE' -parallel-testing-enabled NO -derivedDataPath ./DerivedData -only-testing:MarginShotUITests/MarginShotUITests/testReducedEffectsSettings -only-testing:MarginShotUITests/MarginShotUITests/testSmallWidthLandscapeAndIncreasedContrast CODE_SIGNING_ALLOWED=NO
xcodebuild build -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS' -derivedDataPath /tmp/marginshot-design-device-build CODE_SIGNING_ALLOWED=NO
xcodebuild build -configuration Release -project MarginShot.xcodeproj -scheme MarginShot -destination 'generic/platform=iOS' -derivedDataPath /tmp/marginshot-design-release-build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Visual evidence and findings are in [the evidence index](plans/002-design-evidence/README.md). The matrix covers empty/populated Capture/Library/Chat in light/dark at default, XXXL, and accessibility 3 text sizes, plus onboarding, synthetic ready/saving, camera denial/unavailability, pending processing/paused/failed, encrypted detail, stale proposal/review, notebook editing, Settings, search/no-results and original pages. Large-text Capture initially crowded its error with the notebook name; moving notebook text into scrollable content and reflowing controls resolved that composition problem. Landscape app-only screenshot capture cropped the actual surface; whole-screen captures replaced those artifacts.

Fixture safety: `-design-fixture <state>` is Debug-only and uses a UUID-scoped temporary vault, a separate defaults suite, and in-memory Core Data. Real startup recovery, background work, credentials, and networking are bypassed. Early UI attempts exposed missing DEBUG compilation conditions and are excluded from fixture-isolation evidence. The corrected fixture launch was verified with onboarding/state assertions and a final hash comparison of 13 normal vault/Application Support files: unchanged. No normal store was reset. Original picker bytes are the selected representation returned by Photos; equality with an inaccessible Photos master is not claimed.

Remaining manual acceptance (not passed):

- No physical device was connected. Real multi-page camera capture, denial/recovery, interruption/background/foreground, framing, relaunch, Photos master/HEIC behavior, signed-device Keychain, and actual background execution remain unverified.
- XCTest validates task-oriented accessible labels and recovery actions. A spoken VoiceOver walkthrough and focus-order/selected-state announcements remain pending.
- Composer drafts, focus actions, sending/retry and Settings return are tested. The simulator reports a keyboard accessibility element with frame `(0, 918, 402, 226)`, below the 874-point viewport, and screenshots do not show a software keyboard. Visible software-keyboard/multiline composer acceptance is therefore **not claimed**. Headless simulator behavior is not treated as a confirmed production defect.
- Live Gemini, folder, and GitHub checks require authorized disposable accounts/data. No provider or backup protection was bypassed for screenshots.
- Older-OS runtime behavior was not exercised because only iOS 27.0/27.1 runtimes are installed; iOS 17 availability was checked by compilation.

### Follow-up: shutter centering (2026-10-26)

Unequal-width Import Photos and pending/Finish controls pushed the shutter off center in the horizontal row. The capture layout now pins the shutter to the row midpoint and reserves equal space on both sides, falling back to a centered vertical layout when needed. Two focused UI tests passed on the regular iPhone 17 / iOS 27.0 simulator, asserting screen-center alignment at default/accessibility text sizes and before/after Finish appears. Result: `Test-MarginShot-2026.10.26_20-02-24-+0100.xcresult`. Screenshots: `plans/002-design-evidence/screenshots/capture-centered-default.png` and `capture-centered-accessibility.png`. `git diff --check` passed.
