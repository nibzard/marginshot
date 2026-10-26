# Implementation plans

Created 2026-10-26 from a read-only review of commit `cbe5fea` plus the current uncommitted working tree. Implementation started 2026-10-26; see phase evidence in the plan.

| Plan | Priority | Effort | Dependency | Status |
|---|---|---|---|---|
| [001 — Reliable capture, vault mutations, and backup](001-reliable-capture-vault-and-sync.md) | P1 | L | Restore test baseline in phase 0 | IMPLEMENTED — 51 tests passed; device/provider QA pending |
| [002 — Modern iOS design and UX](002-modern-ios-design-and-ux.md) | P1 | L | Preserve 001 reliability guarantees; establish isolated UI fixtures | IMPLEMENTED — 61 unit tests, full/focused UI checks and device builds passed; manual acceptance pending |

Execute the plan's phases in order. Each phase has a verification gate; later phases depend on the durability and recovery guarantees introduced earlier. Preserve existing working-tree edits before creating an implementation checkout.

## Alternatives considered

- Full rewrite: deferred; current evidence supports focused changes to data ownership and recovery while retaining SwiftUI and Core Data.
- File splitting alone: insufficient; moving functions without changing transaction/recovery behavior preserves the defects.
- Broad visual redesign was deferred during plan 001. The user has now requested it; plan 002 covers the new navigation, restrained visual system, read-only Library, import, and observed UX defects while preserving 001 guarantees. Unrelated feature expansion remains deferred.

Update status only with actual verification evidence. This plan does not authorize publishing or deploying changes.

## Plan 002 dependency and review notes

Written 2026-10-26 from the iPhone 17 hands-on review, current source, and official Apple iOS design guidance. Execute phases sequentially: baseline/fixtures → native shell → Capture/onboarding/import → Library → Chat/Settings → complete visual/accessibility/reliability verification. Physical-device/provider limits from 001 remain explicit and do not block independent simulator design work.

Considered and rejected for this scope:

- Adding more glass or changing only colors/corner radii: does not address screen hierarchy or broken recovery routes.
- Treating simulator camera absence and unsigned Keychain failure as confirmed production defects: unsupported; fix the observed error UX and verify hardware separately.
- Replacing persistence/sync or increasing the minimum OS to modernize the UI: unnecessary risk.
- Rich editing, app-icon redesign, and cross-device encryption recovery: separate work; not needed for this redesign.

This planning pass was scoped to the already observed design/UX findings and their direct code paths. It was not a fresh whole-repository security, performance, or dependency audit.
