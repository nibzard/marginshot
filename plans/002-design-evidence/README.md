# Design verification evidence

Baseline: 2026-10-26, regular MarginShot-iPhone simulator `1D8053E0-AB4F-44CC-9FC2-C0A46083950B`, iOS 27.0. Starting inventory is in `starting-status.txt`.

- Baseline generic simulator build-for-testing: passed.
- Baseline unit suite: 49 tests, 0 failures (the prior plan's 51 included UI tests).
- Fixture isolation unit suite: 50 tests, 0 failures. Fixture roots are UUID-scoped under temporary storage; defaults have a separate suite; Core Data is in memory. Normal recovery and workers are bypassed only with Debug `-design-fixture <state>`. No real key is used.
- Intermediate shell screenshot before Capture composition overhaul: `shell-capture.png`. The attempted pre-shell capture caught a launch transition and was discarded. The prior hands-on baseline remains documented in QA.md.

State checklist for subsequent review: onboarding; empty; populated with long titles; camera unavailable/ready/saving; processing; paused; failed; encrypted; stale proposal; search/no results; original pages; composer/keyboard; Settings; notebook editor. Review core screens in light/dark, default/XXXL/accessibility text; small width/landscape; reduced motion/transparency/contrast. Hardware camera, VoiceOver and live providers require separate recorded verification.

## Review gallery

All evidence is synthetic. PNGs are in `screenshots/`; contact sheets aid comparison, while the original PNGs preserve readable detail.

| Content | Default | XXXL | Accessibility 3 |
|---|---|---|---|
| Empty | [Review](screenshots/contact-empty-default.jpg) | [Review](screenshots/contact-empty-xxxl.jpg) | [Review](screenshots/contact-empty-accessibility.jpg) |
| Populated | [Review](screenshots/contact-populated-default.jpg) | [Review](screenshots/contact-populated-xxxl.jpg) | [Review](screenshots/contact-populated-accessibility.jpg) |

Each sheet includes Capture, Library, and Chat in light and dark modes. Error/recovery/editor PNGs use descriptive `state-*`, `chat-*`, `stale-*`, `notebook-*`, and `settings-*` names. Small-phone whole-screen captures use `small-contrast-*` and `reduced-effects-*`.

Observed review results:

- System surfaces and text adapt to light/dark. Long titles and notebook names wrap; Capture controls reflow vertically when needed. Large-text Capture's initial crowded composition was corrected and rerun.
- Library note rows use verified page thumbnails, text excerpts, and dates. Detail faithfully retains complete raw text; unsupported Markdown remains available through the raw-text switch. Original-page associations are tested against unrelated same-day notes.
- Native scrolling handles content beyond the viewport at large text and landscape widths. Import remains hittable; camera failure never enables the shutter. Error and paused states have recovery actions.
- Filled custom Chat controls use a dark foreground on the bright dark-mode accent. Native toolbars respect system contrast/transparency preferences; actual increased contrast, reduced motion and reduced transparency were checked on the disposable small simulator.
- App-only landscape screenshots were initially cropped. Reviewed landscape evidence now uses whole-screen capture.
- The composer keyboard accessibility element is below the viewport in this simulator. `composer-draft-keyboard-offscreen.png` documents the limitation; no software-keyboard visual pass is claimed.

VoiceOver spoken navigation, physical camera/Keychain/background behavior, live providers/backup, and older runtime behavior remain explicitly unverified in QA.md. Screenshots of ready/saving/error/provider states are Debug fixtures, not real provider responses or proof of physical hardware behavior.


Final results: 61 unit tests passed. The full regular-phone UI run executed 17 tests, skipping the 2 small-simulator-only cases; both passed separately on the small simulator. The final focused run passed 61 unit + 5 UI tests, followed by a final 61-test unit run and a passing notebook-feedback UI check. Debug/Release device compilation and whitespace checks passed. Normal-data hashes were unchanged for all 13 inventoried files. See the plan and QA.md for exact result bundles and manual gaps.

`capture-unavailable.png`, `library-populated.png`, and `shell-capture.png` are earlier gate/seed screenshots retained to reproduce picker testing and compare composition. Use `screenshots/matrix-*` for the final core layouts. The apparent title-only/partial content in some landscape or accessibility captures is a scroll viewport; required actions remain reachable through native scrolling, and Capture's full failure status remains visible with its controls.
