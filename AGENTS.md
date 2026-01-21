# Repository Guidelines

## Project Structure and Module Organization
- `MarginShot/`: SwiftUI app code plus core services such as `ProcessingQueue.swift`, `VaultFileStore.swift`, and `PersistenceController.swift`.
- `MarginShot/Views/`: SwiftUI screens (Capture, Chat, Settings, Onboarding) and UI components.
- `MarginShotTests/`: XCTest unit and integration coverage.
- `MarginShotUITests/`: UI smoke tests.
- `MarginShot/Assets.xcassets/`: app icons and asset catalog.
- `MarginShot.xcodeproj/`: Xcode project settings and build configs.
- `to-do.json` and `to-do.schema.json`: structured backlog tracking.
- `SPECS.md`, `QA.md`, `BUILD_CONFIG.md`: product specs, QA checklist, and build config notes.

## Build, Test, and Development Commands
- `open MarginShot.xcodeproj` to run and debug in Xcode.
- `xcodebuild -scheme MarginShot -configuration Debug` to build from the CLI with local config or env overrides.
- `xcodebuild test -scheme MarginShot -destination 'platform=iOS Simulator,name=iPhone 15'` to run unit and UI tests.

## Coding Style and Naming Conventions
- Swift/SwiftUI with 4-space indentation and braces on the same line.
- Types and files use UpperCamelCase; functions and variables use lowerCamelCase.
- Keep view files focused on UI and move shared logic into stores or helpers (see `SyncStatusStore.swift` and `ProcessingQueue.swift`).

## Testing Guidelines
- Framework: XCTest. Unit/integration tests live in `MarginShotTests`, UI tests in `MarginShotUITests`.
- Name test files `*Tests.swift` and test methods `test...`.
- Update tests for pipeline, vault, or sync changes; keep UI tests lightweight and deterministic.

## Commit and Pull Request Guidelines
- Commit messages follow Conventional Commits: `type(scope): summary` (examples: `fix(sync): ...`, `chore(todo): ...`).
- PRs should include a concise summary, tests run, and screenshots for UI changes. Link related tasks or issues when available.

## Configuration and Security Notes
- Do not commit secrets. Use `MarginShot.xcodeproj/Configuration.xcconfig` (gitignored) or env vars.
- Start from `MarginShot.xcodeproj/Configuration.xcconfig.template` and follow `BUILD_CONFIG.md` for GitHub OAuth and Gemini API setup.
