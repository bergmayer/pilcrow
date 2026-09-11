import XCTest

@MainActor
final class KeyboardLayoutUITests: XCTestCase {
    func test_keyboardShowHideAndRotationKeepsEditorAndStatusBarVisible() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-showStatusBar", "YES", "-showToolbar", "YES"]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let newTab = app.buttons["New Tab"]
        if newTab.waitForExistence(timeout: 3) { newTab.tap() }
        let blank = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Blank Document")).firstMatch
        if blank.waitForExistence(timeout: 2) { blank.tap() }
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        for (index, orientation) in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait].enumerated() {
            XCUIDevice.shared.orientation = orientation
            let keyboard = app.keyboards.firstMatch
            let visible = expectation(
                for: NSPredicate { _, _ in
                    MainActor.assumeIsolated { keyboard.exists && keyboard.frame.height > 100 }
                }, evaluatedWith: nil)
            visible.expectationDescription =
                "Software keyboard must be onscreen; disable Simulator's hardware keyboard connection"
            wait(for: [visible], timeout: 10)
            let info = app.buttons["Info"].firstMatch
            let accessoryDismiss = app.buttons["Hide Keyboard"].firstMatch
            let obstructionTop =
                accessoryDismiss.exists
                ? min(keyboard.frame.minY, accessoryDismiss.frame.minY) : keyboard.frame.minY
            XCTAssertTrue(app.buttons["Undo"].firstMatch.isHittable)
            XCTAssertTrue(info.isHittable)
            XCTAssertGreaterThan(editor.frame.height, 44)
            XCTAssertGreaterThanOrEqual(editor.frame.minY, 0)
            XCTAssertLessThanOrEqual(editor.frame.maxY, info.frame.midY)
            XCTAssertLessThanOrEqual(info.frame.midY, obstructionTop)
            // The keyboard's accessibility frame excludes its rounded cap;
            // allow that cap plus the compact status bar's half height.
            XCTAssertGreaterThanOrEqual(
                info.frame.midY, obstructionTop - 64,
                "The status bar must sit directly above the software keyboard")
            print(
                "KEYBOARD_LAYOUT orientation=\(orientation.rawValue) editor=\(editor.frame) info=\(info.frame) keyboard=\(keyboard.frame)"
            )
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "software-keyboard-\(orientation.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let shownInfoY = info.frame.midY
            let minimumRecoveredHeight = min(100, keyboard.frame.height / 2)
            let dismiss = accessoryDismiss.exists ? accessoryDismiss : keyboard.buttons["Hide keyboard"]
            if dismiss.exists {
                dismiss.tap()
            } else {
                // iPhone can omit the accessory while a hardware keyboard is
                // connected. Its touch tab switcher also ends text input.
                app.buttons["Show All Tabs"].tap()
                let done = app.buttons["Done"]
                XCTAssertTrue(done.waitForExistence(timeout: 5))
                done.tap()
            }
            let hidden = expectation(
                for: NSPredicate { _, _ in
                    MainActor.assumeIsolated { !keyboard.exists || keyboard.frame.height < 100 }
                }, evaluatedWith: nil)
            wait(for: [hidden], timeout: 5)
            XCTAssertGreaterThan(
                info.frame.midY, shownInfoY + minimumRecoveredHeight,
                "Dismissing the keyboard must restore the editor's full height")
            if index < 2 { editor.tap() }
        }
    }
}

@MainActor
final class DocumentCloseUITests: XCTestCase {
    private let bufferText = "text" + UUID().uuidString.lowercased().filter(\.isLetter).prefix(6)
    private var initiallyEmpty = false

    func test_touchSaveAsCancellationKeepsTextAndDiscardReturnsToStart() {
        let app = launchWithBuffer()
        defer { app.terminate() }
        closeTab(in: app)
        XCTAssertTrue(app.buttons["Save…"].exists)
        XCTAssertTrue(app.buttons["Don’t Save"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertFalse(app.buttons["Save as Draft"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.scrollViews["Text Editor"].value as? String, bufferText)

        closeTab(in: app)
        app.buttons["Save…"].tap()
        cancelPicker(in: app)
        XCTAssertTrue(app.scrollViews["Text Editor"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["Text Editor"].value as? String, bufferText)

        closeTab(in: app)
        app.buttons["Don’t Save"].tap()
        assertClosedBuffer(in: app)
        app.terminate()
        app.launch()
        assertClosedBuffer(in: app)
    }

    func test_processTerminationRestoresUnsavedTextAutomatically() {
        let app = launchWithBuffer()
        defer { app.terminate() }
        // A real touch interaction gives the periodic checkpoint time to
        // complete without sending the scene into the background first.
        closeTab(in: app)
        app.buttons["Cancel"].tap()
        app.terminate()
        app.launch()
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let restored = expectation(for: NSPredicate(format: "value == %@", bufferText), evaluatedWith: editor)
        wait(for: [restored], timeout: 5)
        closeTab(in: app)
        app.buttons["Don’t Save"].tap()
        assertClosedBuffer(in: app)
    }

    func test_touchSaveAsClosesTabAndReopenedFileContainsSavedText() {
        let app = launchWithBuffer()
        defer { app.terminate() }
        closeTab(in: app)
        app.buttons["Save…"].tap()
        let name = saveFromPicker(in: app)
        assertClosedBuffer(in: app)

        runCommand("Reopen Last Closed Tab", in: app)
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let restored = expectation(for: NSPredicate(format: "value == %@", bufferText), evaluatedWith: editor)
        wait(for: [restored], timeout: 5)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists)
        runCommand("Close Tab", in: app)
        assertClosedBuffer(in: app)
    }

    func test_multipleUnsavedTabsCanSaveOneAndDiscardTheOther() {
        let app = launchWithBuffer()
        defer { app.terminate() }
        runCommand("New Tab", in: app)
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        for key in "discardme" { keyboard.keys[String(key)].tap() }

        reviewCloseAll(in: app)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "discardme")

        reviewCloseAll(in: app)
        saveChoices(in: app).element(boundBy: saveChoices(in: app).count - 1).tap()
        XCTAssertTrue(app.staticTexts["1 to save · 1 to discard"].exists)
        XCTAssertEqual(saveChoices(in: app).element(boundBy: 1).value as? String, "Not selected")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "select-one-document-to-save"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Save Selected"].tap()
        cancelPicker(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        // Canceling Save As must retain the unchecked tab too. A fresh review
        // still contains both documents, with neither silently discarded.
        reviewCloseAll(in: app)
        saveChoices(in: app).element(boundBy: saveChoices(in: app).count - 1).tap()
        app.buttons["Save Selected"].tap()
        _ = saveFromPicker(in: app)
        assertClosedBuffer(in: app)
        XCTAssertEqual(app.scrollViews.matching(NSPredicate(format: "value == %@", "discardme")).count, 0)

        runCommand("Reopen Last Closed Tab", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let restored = expectation(for: NSPredicate(format: "value == %@", bufferText), evaluatedWith: editor)
        wait(for: [restored], timeout: 5)
        runCommand("Close Tab", in: app)
        assertClosedBuffer(in: app)
    }

    func test_touchWindowSaveClosesAndReopensOnlyTheSavedFile() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Window destruction is iPad-only")
        let app = launchWithBuffer()
        defer { app.terminate() }
        // Exercise only the isolated test window; never close unrelated work.
        try XCTSkipUnless(initiallyEmpty, "This test requires an empty starting window")
        runCommand("Close Window", in: app)
        assertCloseReview(in: app, count: 1)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.scrollViews["Text Editor"].value as? String, bufferText)
        runCommand("Close Window", in: app)
        assertCloseReview(in: app, count: 1)
        app.buttons["Save All"].tap()
        cancelPicker(in: app)
        XCTAssertEqual(app.scrollViews["Text Editor"].value as? String, bufferText)
        runCommand("Close Window", in: app)
        assertCloseReview(in: app, count: 1)
        app.buttons["Save All"].tap()
        _ = saveFromPicker(in: app)
        let closed = expectation(
            for: NSPredicate { _, _ in
                MainActor.assumeIsolated { !app.scrollViews["Text Editor"].exists }
            }, evaluatedWith: nil)
        wait(for: [closed], timeout: 10)
        app.terminate()
        app.launch()
        assertClosedBuffer(in: app)
        runCommand("Reopen Last Closed Tab", in: app)
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let restored = expectation(for: NSPredicate(format: "value == %@", bufferText), evaluatedWith: editor)
        wait(for: [restored], timeout: 5)
        runCommand("Close Tab", in: app)
        assertClosedBuffer(in: app)
    }

    func test_saveAllAndCloseSkipsReviewAndWaitsForEveryDocument() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Window destruction is iPad-only")
        let app = launchWithBuffer()
        defer { app.terminate() }
        try XCTSkipUnless(initiallyEmpty, "This test requires an isolated empty window")
        let editor = app.scrollViews["Text Editor"]
        let texts = [bufferText, "second", "third"]
        for text in texts.dropFirst() {
            runCommand("New Tab", in: app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            for key in text { keyboard.keys[String(key)].tap() }
            XCTAssertEqual(editor.value as? String, text)
        }

        func expectPicker(after previousName: String? = nil) {
            let filename = app.textFields["DOCPicker.filenameTextField"]
            let ready = expectation(
                for: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        filename.exists && filename.isHittable
                            && (previousName.map { !(filename.value as? String ?? "").hasPrefix($0) } ?? true)
                    }
                }, evaluatedWith: nil)
            wait(for: [ready], timeout: 10)
            XCTAssertFalse(app.descendants(matching: .any)["close-review-title"].firstMatch.exists)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }

        runCommand("Save All and Close Window", in: app)
        expectPicker()
        let firstName = saveFromPicker(in: app)
        expectPicker(after: firstName)
        cancelPicker(in: app)
        XCTAssertEqual(editor.value as? String, texts[1])

        // The first file stays saved; both remaining buffers survive cancellation.
        runCommand("Close Window", in: app)
        assertCloseReview(in: app, count: 2)
        app.buttons["Cancel"].tap()
        runCommand("Save All and Close Window", in: app)
        expectPicker()
        let secondName = saveFromPicker(in: app)
        expectPicker(after: secondName)
        _ = saveFromPicker(in: app)
        let closed = expectation(
            for: NSPredicate { _, _ in MainActor.assumeIsolated { !editor.exists } }, evaluatedWith: nil)
        wait(for: [closed], timeout: 10)

        app.terminate()
        app.launch()
        assertClosedBuffer(in: app)
        for text in texts.reversed() {
            runCommand("Reopen Last Closed Tab", in: app)
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            let restored = expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: editor)
            wait(for: [restored], timeout: 5)
        }
        runCommand("Close All Tabs", in: app)
        assertClosedBuffer(in: app)
    }

    func test_windowCloseShowsTheDocumentListFirstAndSaveCancellationKeepsBothTabs() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Window destruction is iPad-only")
        let app = launchWithBuffer()
        defer { app.terminate() }
        try XCTSkipUnless(initiallyEmpty, "This test requires an isolated empty window")
        runCommand("New Tab", in: app)
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        for key in "keepunchecked" { keyboard.keys[String(key)].tap() }

        func closeWindow() {
            runCommand("Close Window", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["close-review-title"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.alerts.firstMatch.exists, "The list must appear without a preliminary alert")
            XCTAssertTrue(app.staticTexts["2 to save · 0 to discard"].exists)
        }
        closeWindow()
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "keepunchecked")
        closeWindow()
        saveChoices(in: app).element(boundBy: 1).tap()
        app.buttons["Save Selected"].tap()
        cancelPicker(in: app)
        closeWindow()
        app.buttons["Don’t Save"].firstMatch.tap()
        let closed = expectation(
            for: NSPredicate { _, _ in
                MainActor.assumeIsolated { !app.scrollViews["Text Editor"].exists }
            }, evaluatedWith: nil)
        wait(for: [closed], timeout: 10)
        app.terminate()
        app.launch()
        assertClosedBuffer(in: app)
    }

    func test_oneUnsavedDocumentAmongSeveralTabsUsesSimpleConfirmation() {
        let app = launchWithBuffer()
        defer { app.terminate() }
        runCommand("New Tab", in: app)
        runCommand("Close All Tabs", in: app)
        assertSingleDocumentClose(in: app)
        app.buttons["Cancel"].tap()
        runCommand("Close All Tabs", in: app)
        assertSingleDocumentClose(in: app)
        app.buttons["Don’t Save"].tap()
        assertClosedBuffer(in: app)
    }

    func test_saveAllOffersDestinationForEachUntitledDocument() {
        let app = launchWithBuffer()
        defer { app.terminate() }
        runCommand("New Tab", in: app)
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        for key in "keepboth" { keyboard.keys[String(key)].tap() }
        reviewCloseAll(in: app)
        app.buttons["Save All"].tap()
        let firstName = saveFromPicker(in: app)
        let nextFilename = app.textFields["DOCPicker.filenameTextField"]
        let nextDestination = expectation(
            for: NSPredicate(format: "exists == true AND value != %@", firstName), evaluatedWith: nextFilename)
        wait(for: [nextDestination], timeout: 10)
        _ = saveFromPicker(in: app)
        assertClosedBuffer(in: app)
        runCommand("Reopen Last Closed Tab", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "keepboth")
        runCommand("Close Tab", in: app)
    }

    func test_sidebarSettingAndTouchTabNavigation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Document sidebar is an iPad layout")
        let app = launchWithBuffer()
        defer { app.terminate() }
        runCommand("Settings…", in: app)
        let appearance = app.buttons["document-tab-appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 8))
        appearance.tap()
        app.buttons["Sidebar"].tap()
        // Relaunch proves that the setting is persisted, while the scratch
        // document retains its identity and contents through restoration.
        app.terminate()
        app.launch()
        // UIKit can restore either the editor or the Settings window first.
        // Return from the utility window when it was restored in front.
        if appearance.waitForExistence(timeout: 2) {
            XCTAssertTrue(appearance.label.contains("Sidebar"))
            try tapNativeClose(in: app)
            app.activate()
        }
        let documents = app.buttons["show-documents"]
        if documents.waitForExistence(timeout: 2) { documents.tap() }
        let sidebar = app.descendants(matching: .any)["document-sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "● Untitled")).firstMatch
        XCTAssertTrue(first.exists)
        first.tap()
        XCTAssertEqual(app.scrollViews["Text Editor"].value as? String, bufferText)
        if documents.exists { documents.tap() }
        app.buttons["New Tab"].tap()
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "")
        if documents.exists { documents.tap() }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertEqual(editor.value as? String, bufferText)
        if documents.exists { documents.tap() }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "document-sidebar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        first.tap()  // Close the temporary list if this window was already narrow.
        // A narrow floating window uses the same list as a temporary overlay,
        // leaving enough width for the editor when the list is dismissed.
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let resize = system.otherElements.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "resize-grabber", "Resize \(app.label)")
        ).firstMatch
        XCTAssertTrue(resize.waitForExistence(timeout: 5))
        resize.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        XCTAssertTrue(documents.waitForExistence(timeout: 5))
        documents.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isHittable)
        XCTAssertGreaterThanOrEqual(
            app.staticTexts["Open Documents"].firstMatch.frame.minY, documents.frame.maxY,
            "The document drawer must stay below the toolbar and native window controls")
        let controls = system.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "window-controls:", "Window Controls, \(app.label)")
        ).firstMatch
        XCTAssertTrue(controls.exists)
        let title = app.buttons["window-document-title"]
        XCTAssertTrue(title.exists)
        XCTAssertGreaterThanOrEqual(
            title.frame.minX, controls.frame.maxX,
            "The document title must stay clear of native window controls at compact widths")
        let compact = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        compact.name = "compact-document-list"
        compact.lifetime = .keepAlways
        add(compact)
        first.tap()
        XCTAssertEqual(editor.value as? String, bufferText)
        documents.tap()
        // Closing a dirty sidebar row uses the same document review.
        let close = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close ● Untitled")).firstMatch
        close.tap()
        assertSingleDocumentClose(in: app)
        app.buttons["Cancel"].tap()
    }

    func test_newWindowAndTabDefaultsAreIndependentAndPersisted() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Separate window defaults require iPad")
        let app = launchWithBuffer()
        defer { app.terminate() }

        func setDefaults(window: String, tab: String) throws {
            runCommand("Settings…", in: app)
            let windowPicker = app.buttons["new-window-content"]
            XCTAssertTrue(windowPicker.waitForExistence(timeout: 5))
            if !windowPicker.isHittable { app.swipeUp() }
            windowPicker.tap()
            app.buttons[window].tap()
            let tabPicker = app.buttons["new-tab-content"]
            if !tabPicker.isHittable { app.swipeUp() }
            tabPicker.tap()
            app.buttons[tab].tap()
            try tapNativeClose(in: app)
            app.activate()
        }

        func checkNewWindowAndTab(windowStartsBlank: Bool) {
            runCommand("New Window", in: app)
            if windowStartsBlank {
                let editor = app.scrollViews["Text Editor"].firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 5))
                XCTAssertEqual(editor.value as? String, "")
            } else {
                XCTAssertTrue(blankButton(in: app).waitForExistence(timeout: 5))
            }
            app.buttons["New Tab"].firstMatch.tap()
            if windowStartsBlank {
                XCTAssertTrue(blankButton(in: app).waitForExistence(timeout: 5))
            } else {
                let editor = app.scrollViews["Text Editor"].firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 5))
                XCTAssertEqual(editor.value as? String, "")
            }
        }

        try setDefaults(window: "Blank Document", tab: "Start Page")
        checkNewWindowAndTab(windowStartsBlank: true)
        app.terminate()
        app.launch()
        checkNewWindowAndTab(windowStartsBlank: true)
        try setDefaults(window: "Start Page", tab: "Blank Document")
        checkNewWindowAndTab(windowStartsBlank: false)
    }

    func test_nativeCloseReviewKeepsTabsUntilSelectedSavesComplete() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Native window closure is iPad-only")
        let app = launchWithBuffer()
        defer { app.terminate() }
        try XCTSkipUnless(initiallyEmpty, "Native close testing requires an empty, isolated app container")

        // Window closes always use the document list after the system prompt.
        try reviewNativeWindow(in: app, unsavedDocuments: 1)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.scrollViews["Text Editor"].value as? String, bufferText)

        try reviewNativeWindow(in: app, unsavedDocuments: 1)
        app.buttons["Save All"].tap()
        cancelPicker(in: app)
        XCTAssertEqual(app.scrollViews["Text Editor"].value as? String, bufferText)

        runCommand("New Tab", in: app)
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        for key in "discardme" { keyboard.keys[String(key)].tap() }

        try reviewNativeWindow(in: app)
        XCTAssertTrue(app.staticTexts["2 to save · 0 to discard"].exists)
        saveChoices(in: app).element(boundBy: saveChoices(in: app).count - 1).tap()
        app.buttons["Save Selected"].tap()
        cancelPicker(in: app)

        // Both selected and unchecked buffers survive cancellation of Save As.
        try reviewNativeWindow(in: app)
        XCTAssertTrue(app.staticTexts["2 to save · 0 to discard"].exists)
        saveChoices(in: app).element(boundBy: saveChoices(in: app).count - 1).tap()
        app.buttons["Save Selected"].tap()
        _ = saveFromPicker(in: app)
        let closed = expectation(
            for: NSPredicate { _, _ in
                MainActor.assumeIsolated { !app.scrollViews["Text Editor"].exists }
            }, evaluatedWith: nil)
        wait(for: [closed], timeout: 10)
        app.terminate()
        app.launch()
        assertClosedBuffer(in: app)
        runCommand("Reopen Last Closed Tab", in: app)
        let restored = expectation(for: NSPredicate(format: "value == %@", bufferText), evaluatedWith: editor)
        wait(for: [restored], timeout: 5)
        runCommand("Close Tab", in: app)
        assertClosedBuffer(in: app)
    }

    private func tapNativeClose(in app: XCUIApplication, withKeyboard: Bool = false) throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let controls = system.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "window-controls:", "Window Controls, \(app.label)")
        ).firstMatch
        if !controls.exists {
            if app.keyboards.firstMatch.exists { app.keyboards.buttons["Hide keyboard"].tap() }
            let resize = system.otherElements.matching(
                NSPredicate(format: "identifier == %@ AND label == %@", "resize-grabber", "Resize \(app.label)")
            ).firstMatch
            _ = try XCTUnwrap(
                resize.waitForExistence(timeout: 5) ? resize : nil, "Native window resize control is unavailable")
            resize.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
                .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)))
        }
        _ = try XCTUnwrap(
            controls.waitForExistence(timeout: 5) ? controls : nil, "Native window controls are unavailable")
        // Reproduce the user's path with the software keyboard visible even
        // when the window had to be floated to expose the native close button.
        if withKeyboard {
            app.scrollViews["Text Editor"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        }
        if !controls.buttons["Close-button"].exists { controls.tap() }
        controls.buttons["Close-button"].tap()
    }

    private func reviewNativeWindow(in app: XCUIApplication, unsavedDocuments: Int = 2) throws {
        try tapNativeClose(in: app, withKeyboard: true)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let nativeReview = system.buttons["Review Changes…"]
        let appReview = app.alerts.buttons["Review Changes…"]
        if nativeReview.waitForExistence(timeout: 3) {
            nativeReview.tap()
        } else {
            _ = try XCTUnwrap(
                appReview.waitForExistence(timeout: 3) ? appReview : nil, "System close confirmation did not appear")
            appReview.tap()
        }
        assertCloseReview(in: app, count: unsavedDocuments)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "native-review-keeps-window-open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func saveChoices(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "save-"))
    }

    private func reviewCloseAll(in app: XCUIApplication) {
        runCommand("Close All Tabs", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["close-review-title"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "The document list must be the first close dialog")
        // The review must include inactive unsaved documents too.
        XCTAssertTrue(app.staticTexts["2 to save · 0 to discard"].exists)
    }

    private func cancelPicker(in app: XCUIApplication) {
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        let cancel = app.navigationBars.buttons["Cancel"].firstMatch
        // A compact iPad Files picker has no interactive sheet dismissal.
        // Return from its nested folder to the root Cancel button.
        if UIDevice.current.userInterfaceIdiom == .pad {
            for _ in 0..<3 where !cancel.exists {
                let back = app.navigationBars.buttons["BackButton"].firstMatch
                guard back.exists else {
                    print(
                        "Picker navigation buttons: \(app.navigationBars.buttons.allElementsBoundByIndex.map { ($0.label, $0.identifier) })"
                    )
                    break
                }
                back.tap()
            }
        }
        if cancel.exists {
            cancel.tap()
        } else {
            // In iPhone's nested destination view, Files shows Back instead
            // of Cancel. Dismiss its native sheet with a touch drag.
            let bar = app.navigationBars.containing(.button, identifier: "DOCPicker.actionButton").firstMatch
            XCTAssertTrue(bar.exists)
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let end = start.withOffset(CGVector(dx: 0, dy: app.frame.height / 2))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
        wait(for: [dismissed], timeout: 5)
    }

    @discardableResult
    private func saveFromPicker(in app: XCUIApplication) -> String {
        let name = "Pilcrow" + UUID().uuidString.filter(\.isLetter).prefix(6)
        let filename = app.textFields["DOCPicker.filenameTextField"]
        let pickerReady = filename.waitForExistence(timeout: 10)
        if !pickerReady {
            print(app.debugDescription)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "save-picker-not-presented"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(pickerReady)
        filename.tap()
        let oldName = filename.value as? String ?? ""
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
        for character in name { filename.typeText(String(character)) }
        let named = expectation(for: NSPredicate(format: "value == %@", name), evaluatedWith: filename)
        wait(for: [named], timeout: 5)
        app.buttons["DOCPicker.actionButton"].tap()
        return name
    }

    private func launchWithBuffer() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-showToolbar", "YES", "-showStatusBar", "YES"]
        app.launch()
        let blank = blankButton(in: app)
        initiallyEmpty = blank.waitForExistence(timeout: 3)
        if initiallyEmpty {
            blank.tap()
        } else {
            runCommand("New Tab", in: app)
            if blank.waitForExistence(timeout: 2) { blank.tap() }
        }
        let editor = app.scrollViews["Text Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // EditorEngine implements custom UITextInput. Tap the real software
        // keys: XCTest's typeText requires a native text-field AX role.
        for key in bufferText { keyboard.keys[String(key)].tap() }
        XCTAssertEqual(editor.value as? String, bufferText)
        return app
    }

    private func closeTab(in app: XCUIApplication) {
        runCommand("Close Tab", in: app)
        assertSingleDocumentClose(in: app)
    }

    private func assertSingleDocumentClose(in app: XCUIApplication) {
        let alert = app.alerts["Save Changes Before Closing?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Save…"].exists)
        XCTAssertTrue(alert.buttons["Don’t Save"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["close-review-title"].firstMatch.exists)
        // Dismissing the palette's keyboard can move the alert during presentation.
        let ready = expectation(
            for: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    !app.keyboards.firstMatch.exists && alert.buttons["Save…"].isHittable
                }
            }, evaluatedWith: nil)
        wait(for: [ready], timeout: 5)
    }

    private func assertCloseReview(in app: XCUIApplication, count: Int) {
        XCTAssertTrue(app.descendants(matching: .any)["close-review-title"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts.firstMatch.exists, "There must be no second single-document alert")
        XCTAssertEqual(saveChoices(in: app).count, count)
        XCTAssertTrue(app.staticTexts["\(count) to save · 0 to discard"].exists)
    }

    private func runCommand(_ title: String, in app: XCUIApplication) {
        let toolbarMenu = app.buttons["Toolbar Actions"].firstMatch
        if toolbarMenu.exists { toolbarMenu.tap() }
        let palette = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Command Palette")).firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(title)
        let close = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
    }

    private func blankButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Blank Document")).firstMatch
    }

    private func assertClosedBuffer(in app: XCUIApplication) {
        if initiallyEmpty { XCTAssertTrue(blankButton(in: app).waitForExistence(timeout: 10)) }
        let visibleBuffer = app.scrollViews.matching(NSPredicate(format: "value == %@", bufferText))
        let closed = expectation(
            for: NSPredicate { _, _ in
                MainActor.assumeIsolated { visibleBuffer.count == 0 }
            }, evaluatedWith: nil)
        wait(for: [closed], timeout: 10)
    }
}
