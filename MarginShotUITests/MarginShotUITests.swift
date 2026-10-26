import XCTest

final class MarginShotUITests: XCTestCase {
    func testOnboardingAppearsOnFreshLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to MarginShot"].waitForExistence(timeout: 5))
        app.buttons["Explore the app"].tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
    }

    func testCompletedOnboardingOpensSettingsAfterRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "empty"]
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings after startup recovery"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNativeTabsRetainDraftAndExposeSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "empty"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Capture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Capture"].isSelected)
        for tab in ["Capture", "Library", "Chat"] {
            app.tabBars.buttons[tab].tap()
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
            app.buttons["Done"].tap()
        }
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        composer.tap()
        composer.typeText("Keep this draft")
        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Chat"].tap()
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native Chat with retained draft"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testUnavailableCameraHasDisabledNamedShutterAndImport() {
        for size in ["default", "accessibility"] {
            let app = XCUIApplication()
            app.launchArguments = ["-design-fixture", "empty"]
            app.launchEnvironment["DESIGN_TEXT_SIZE"] = size
            app.launch()
            let shutter = app.buttons["Scan a page"]
            XCTAssertTrue(shutter.waitForExistence(timeout: 10))
            XCTAssertFalse(shutter.isEnabled)
            XCTAssertEqual(shutter.frame.midX, app.frame.midX, accuracy: 1)
            XCTAssertTrue(app.buttons["Import Photos"].isEnabled)
            XCTAssertTrue(app.staticTexts["Camera unavailable"].firstMatch.exists)
            captureEvidence("capture-centered-\(size)", app: app)
            app.terminate()
        }
    }

    func testLibraryDetailOriginalPagesAndSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "populated"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let note = app.buttons["libraryNote-daily/field-notes.md"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        XCTAssertTrue(app.navigationBars["Note"].waitForExistence(timeout: 3))
        captureEvidence("note-detail", app: app)
        let original = app.buttons["Original pages (2)"]
        for _ in 0..<5 where !original.isHittable { app.swipeUp() }
        XCTAssertTrue(original.exists)
        original.tap()
        XCTAssertTrue(app.navigationBars["Original pages"].waitForExistence(timeout: 3))
        captureEvidence("original-pages", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("unfindabletext")
        XCTAssertTrue(app.buttons["Clear search"].waitForExistence(timeout: 5))
        captureEvidence("library-no-results", app: app)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Populated Library"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
    }

    func testChatSetupPreservesDraftAndOpensProcessing() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "setup"]
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        composer.tap()
        composer.typeText("Please keep this question")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        print("KEYBOARD-FRAME \(app.keyboards.firstMatch.frame)")
        let keyboardAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        keyboardAttachment.name = app.keyboards.firstMatch.frame.intersects(app.frame) ? "composer-software-keyboard" : "composer-draft-keyboard-offscreen"
        keyboardAttachment.lifetime = .keepAlways
        add(keyboardAttachment)
        app.buttons["Send message"].tap()
        app.swipeDown()
        let setup = app.buttons["Set up Gemini"]
        reveal(setup, in: app)
        setup.tap()
        XCTAssertTrue(app.navigationBars["Processing"].waitForExistence(timeout: 5))
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        else { app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["Done"].tap() }
        XCTAssertEqual(composer.value as? String, "Please keep this question")
    }

    func testChatFailureRetryAndSourceDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "chat-error"]
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        composer.tap()
        composer.typeText("What should I follow up on?")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))
        captureEvidence("chat-request-error", app: app)
        app.buttons["Try Again"].tap()
        let sources = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Used sources'")).firstMatch
        reveal(sources, in: app)
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.tap()
        captureEvidence("chat-sources-expanded", app: app)
        let open = app.buttons["Open"]
        reveal(open, in: app)
        open.tap()
        XCTAssertTrue(app.navigationBars["Note"].waitForExistence(timeout: 5))
    }

    func testExportIsDirectAndReportsFailure() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "export-error"]
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["Privacy & Data"].tap()
        XCTAssertTrue(app.buttons["Export notes"].waitForExistence(timeout: 5))
        app.buttons["Export notes"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'unavailable'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testPhotoPickerCanBeCancelledWithoutSaving() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "empty"]
        app.launch()
        app.buttons["Import Photos"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "System photo picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.staticTexts["0 pages"].exists)
        XCTAssertFalse(app.buttons["Finish"].exists)
    }

    func testBatchRetainedAcrossTabsAndFinish() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "camera-ready"]
        app.launch()
        let shutter = app.buttons["Scan a page"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertEqual(shutter.frame.midX, app.frame.midX, accuracy: 1)
        shutter.tap()
        XCTAssertTrue(app.staticTexts["Saved page 1"].waitForExistence(timeout: 10))
        XCTAssertEqual(shutter.frame.midX, app.frame.midX, accuracy: 1)
        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Chat"].tap()
        app.tabBars.buttons["Capture"].tap()
        XCTAssertTrue(app.staticTexts["1 pages"].exists)
        shutter.tap()
        XCTAssertTrue(app.staticTexts["Saved page 2"].waitForExistence(timeout: 10))
        captureEvidence("capture-batch", app: app)
        app.buttons["Finish"].tap()
        XCTAssertTrue(app.staticTexts["Pages saved"].waitForExistence(timeout: 5))
    }

    func testStaleProposalRequiresFreshReview() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "stale"]
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        let apply = app.buttons["Apply to vault"]
        reveal(apply, in: app)
        apply.tap()
        let refresh = app.buttons["Refresh and review"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        captureEvidence("stale-apply-conflict", app: app)
        reveal(refresh, in: app)
        refresh.tap()
        let review = app.buttons["Review changes"]
        reveal(review, in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 5))
        captureEvidence("stale-refreshed-review", app: app)
    }

    func testSystemPickerImportsTwoPages() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "empty"]
        app.launch()
        app.buttons["Import Photos"].tap()
        // Seed the simulator with the two synthetic screenshots in the evidence directory.
        let images = app.images.matching(NSPredicate(format: "identifier == 'PXGGridLayout-Info' AND label BEGINSWITH 'Screenshot'"))
        XCTAssertTrue(images.element(boundBy: 1).waitForExistence(timeout: 20))
        images.element(boundBy: 0).tap()
        images.element(boundBy: 1).tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.staticTexts["Saved page 2"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["2 pages"].exists)
        app.buttons["Finish"].tap()
        XCTAssertTrue(app.staticTexts["Pages saved"].waitForExistence(timeout: 5))
    }

    private func captureEvidence(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVisualCoreMatrix() {
        for state in ["empty", "populated"] {
            for appearance in ["light", "dark"] {
                for size in ["default", "xxxl", "accessibility"] {
                    let app = XCUIApplication()
                    app.launchArguments = ["-design-fixture", state]
                    app.launchEnvironment["DESIGN_APPEARANCE"] = appearance
                    app.launchEnvironment["DESIGN_TEXT_SIZE"] = size
                    app.launch()
                    XCTAssertTrue(app.tabBars.buttons["Capture"].waitForExistence(timeout: 10))
                    for tab in ["Capture", "Library", "Chat"] {
                        app.tabBars.buttons[tab].tap()
                        if tab == "Capture" { XCTAssertTrue(app.buttons["Import Photos"].isHittable) }
                        if tab == "Library" && state == "populated" { XCTAssertTrue(app.buttons["libraryNote-daily/field-notes.md"].waitForExistence(timeout: 5)) }
                        captureEvidence("matrix-\(state)-\(appearance)-\(size)-\(tab)", app: app)
                    }
                    app.terminate()
                }
            }
        }
    }

    func testVisualRecoveryAndEditors() {
        for state in ["onboarding", "camera-ready", "saving", "camera-denied", "processing", "paused", "failed", "encrypted", "stale", "setup"] {
            let app = XCUIApplication()
            app.launchArguments = ["-design-fixture", state]
            app.launch()
            if ["processing", "paused", "failed", "encrypted"].contains(state) {
                app.tabBars.buttons["Library"].tap()
                if state != "encrypted" {
                    let pending = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pending scans'")).firstMatch
                    XCTAssertTrue(pending.waitForExistence(timeout: 5))
                    pending.tap()
                } else {
                    app.buttons["libraryNote-daily/field-notes.md"].tap()
                }
            } else if ["stale", "setup"].contains(state) { app.tabBars.buttons["Chat"].tap() }
            else if state == "onboarding" { XCTAssertTrue(app.staticTexts["Welcome to MarginShot"].waitForExistence(timeout: 5)) }
            captureEvidence("state-\(state)", app: app)
            app.terminate()
        }
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "populated"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose notebook'")).firstMatch.tap()
        app.buttons["Instructions for this notebook"].tap()
        captureEvidence("notebook-editor", app: app)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        captureEvidence("settings-overview", app: app)
        app.buttons["Processing"].tap()
        captureEvidence("settings-processing", app: app)
    }

    func testSmallWidthLandscapeAndIncreasedContrast() throws {
        guard UIScreen.main.bounds.width == 375 else { throw XCTSkip("Run on the disposable 375-point MarginShot-Small simulator.") }
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "populated"]
        app.launchEnvironment["DESIGN_APPEARANCE"] = "dark"
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for tab in ["Capture", "Library", "Chat"] {
                app.tabBars.buttons[tab].tap()
                if tab == "Capture" { XCTAssertTrue(app.buttons["Import Photos"].isHittable) }
                captureEvidence("small-contrast-\(orientation.rawValue)-\(tab)", app: app)
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testReducedEffectsSettings() throws {
        guard UIScreen.main.bounds.width == 375 else { throw XCTSkip("System accessibility setup is limited to the disposable small simulator.") }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        for _ in 0..<5 { settings.swipeDown() }
        let accessibility = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Accessibility'")).firstMatch
        for _ in 0..<10 where !accessibility.isHittable { settings.swipeUp() }
        XCTAssertTrue(accessibility.exists)
        accessibility.tap()
        let motion = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Motion'")).firstMatch
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
        motion.tap()
        let reduceMotion = settings.switches["Reduce Motion"]
        XCTAssertTrue(reduceMotion.waitForExistence(timeout: 5))
        if reduceMotion.value as? String != "1" { reduceMotion.tap() }
        settings.navigationBars.buttons.element(boundBy: 0).tap()
        let display = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Display & Text Size'")).firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.tap()
        let transparency = settings.switches["Reduce Transparency"]
        for _ in 0..<6 where !transparency.isHittable { settings.swipeUp() }
        XCTAssertTrue(transparency.exists)
        if transparency.value as? String != "1" { transparency.tap() }
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "populated"]
        app.launchEnvironment["DESIGN_APPEARANCE"] = "dark"
        app.launch()
        for tab in ["Capture", "Library", "Chat"] {
            app.tabBars.buttons[tab].tap()
            captureEvidence("reduced-effects-\(tab)", app: app)
        }
    }

    func testPendingScanRetryKeepsBothPages() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "failed"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["Pending scans (2)"].tap()
        let retry = app.buttons["Retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Page 1"].exists)
        XCTAssertTrue(app.staticTexts["Page 2"].exists)
    }

    func testNotebookInstructionsAreLabeledAndSaved() {
        let app = XCUIApplication()
        app.launchArguments = ["-design-fixture", "populated"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose notebook'")).firstMatch.tap()
        app.buttons["Instructions for this notebook"].tap()
        let instructions = app.textViews["Instructions for this notebook"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        reveal(instructions, in: app)
        instructions.tap()
        instructions.typeText("Keep quotations exactly.")
        app.swipeUp()
        let save = app.buttons["Save Notebook"]
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["Notebook saved."].waitForExistence(timeout: 5))
        captureEvidence("notebook-instructions-saved", app: app)
    }

}
