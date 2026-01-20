# QA Plan

## Automated coverage
- Unit: Processing quality mode defaults and JSON parsing for pipeline responses.
- Integration: Vault writer output, apply-to-vault operations, and folder sync copy.
- UI smoke: onboarding launch flow.

## Manual QA checklist
- Onboarding: welcome screen, permissions step, blocked camera handling, Settings deep link.
- Capture: scan a batch, inbox count updates, retry flow for failed scans.
- Processing: background processing respects Wi-Fi/charging toggles.
- Chat: grounded response, sources disclosure, apply-to-vault action.
- Vault: note creation, raw transcription appended, entity page creation.
- Sync: folder destination selection, sync status states, error banner on failure.
- Settings: system rules editor persistence, privacy toggles, export ZIP.

## Regression checks
- Launch without onboarding regression.
- No crashes when vault folder is missing or empty.
- Index and structure files updated after apply-to-vault.

## Test commands
- `xcodebuild test -scheme MarginShot -destination 'platform=iOS Simulator,name=iPhone 15'`
