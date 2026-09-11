import EditorEngine
import FileEncoding
import SwiftUI
import UIKit
import XCTest

@testable import Pilcrow

@MainActor
final class EngineeringRegressionTests: XCTestCase {
    func test_continuousTypingCheckpointsWithoutWaitingForAPause() async throws {
        let document = PlainTextDocument()
        let pane = Pane(document: document)
        let directory = try XCTUnwrap(ScratchStore.directory)
        let filename = try XCTUnwrap(document.liveRecoveryFilenames.first)
        let scratch = directory.appendingPathComponent(filename)
        defer {
            pane.state.autoSaveTask?.cancel()
            document.deleteScratchFile()
        }

        var checkpoints = Set<String>()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        // Keep typing until repeated writes are observed. A fixed number of
        // sleeps measured simulator scheduling pressure as well as recovery.
        while checkpoints.count < 2, clock.now < deadline {
            pane.editor.insertText("😀x")
            pane.state.scheduleAutoSave(for: document)
            try await Task.sleep(for: .milliseconds(100))
            if let text = try? String(contentsOf: scratch, encoding: .utf8) {
                XCTAssertTrue(pane.editor.text.hasPrefix(text))
                checkpoints.insert(text)
            }
        }
        XCTAssertGreaterThanOrEqual(
            checkpoints.count, 2,
            "Continuous typing must reach disk repeatedly before the user pauses")
        XCTAssertTrue(document.isDirty, "Recovery must not pretend the source was saved")
    }

    func test_newTabLeavesOnlyItsOwnWindowOverview() {
        let first = EditorSession()
        let second = EditorSession()
        first.tabSwitcherActive = true
        second.tabSwitcherActive = true
        let original = first.activeTab
        original.document.text = "keep this buffer"
        let added = first.newTab()
        XCTAssertFalse(first.tabSwitcherActive)
        XCTAssertTrue(second.tabSwitcherActive)
        XCTAssertEqual(first.tabs.map(\.id), [original.id, added.id])
        XCTAssertEqual(first.selectedTabID, added.id)
        XCTAssertEqual(second.tabs.count, 1)
        XCTAssertEqual(original.document.text, "keep this buffer")
    }

    func test_tabDropReordersAndTransfersTheExistingBuffer() {
        let first = EditorSession()
        let second = EditorSession()
        let router = AppStateBus.shared.scenes
        router.registerSession(first)
        router.registerSession(second)
        defer {
            router.deregisterSession(first)
            router.deregisterSession(second)
        }
        let original = first.activeTab
        let moving = first.newTab()
        moving.document.text = "unsaved cross-window work"
        let pane = Pane(document: moving.document, state: moving.state)
        let history = pane.editor.undoManager
        XCTAssertTrue(first.acceptTabDrop([moving.id.uuidString], onto: original.id))
        XCTAssertEqual(first.tabs.first?.id, moving.id)
        XCTAssertTrue(second.acceptTabDrop([moving.id.uuidString], onto: second.activeTab.id))
        XCTAssertTrue(second.tabs.first === moving)
        XCTAssertTrue(moving.state.textView?.undoManager === history)
        XCTAssertEqual(moving.document.text, "unsaved cross-window work")
        XCTAssertEqual(first.tabs.map(\.id), [original.id])
        XCTAssertFalse(second.acceptTabDrop(["not a tab"]))
        XCTAssertFalse(second.acceptTabDrop([UUID().uuidString]))
    }

    func test_tabDropPreservesPinnedPartition() {
        let session = EditorSession()
        let pinned = session.activeTab
        session.togglePinned(pinned.id)
        let first = session.newTab()
        let last = session.newTab()
        XCTAssertTrue(session.acceptTabDrop([last.id.uuidString], onto: pinned.id))
        XCTAssertEqual(session.tabs.map(\.id), [pinned.id, last.id, first.id])
        XCTAssertTrue(session.acceptTabDrop([pinned.id.uuidString], onto: first.id))
        XCTAssertEqual(session.tabs.first?.id, pinned.id)
    }

    func test_windowCloseIncludesInactiveAndPinnedUnsavedTabs() {
        let session = EditorSession()
        let otherWindow = EditorSession()
        let originalTab = session.activeTab
        originalTab.document.text = "Unfiled work"
        originalTab.isPinned = true
        let savedTab = session.newTab()
        savedTab.document.fileURL = URL(fileURLWithPath: "/tmp/close-confirmation-fixture.txt")
        savedTab.document.isDirty = true
        session.newTab()

        XCTAssertEqual(session.unsavedDocumentCount, 2)
        XCTAssertEqual(otherWindow.unsavedDocumentCount, 0)
        savedTab.document.isDirty = false
        XCTAssertEqual(session.unsavedDocumentCount, 1)
        originalTab.document.text = ""
        XCTAssertEqual(session.unsavedDocumentCount, 0)
    }

    func test_windowCloseReadsLiveUntitledBufferBeforeDebouncedSnapshot() {
        let session = EditorSession()
        let tab = session.activeTab
        let pane = Pane(document: tab.document, state: tab.state)
        XCTAssertEqual(session.unsavedDocumentCount, 0)
        pane.editor.insertText("😀")
        XCTAssertEqual(tab.document.text, "")
        XCTAssertEqual(session.unsavedDocumentCount, 1)
        pane.editor.selectedRange = NSRange(location: 0, length: 2)
        pane.editor.insertText("")
        XCTAssertEqual(session.unsavedDocumentCount, 0)

        // Deleting all text from an existing file still needs a warning.
        tab.document.fileURL = URL(fileURLWithPath: "/tmp/close-confirmation-fixture.txt")
        XCTAssertEqual(session.unsavedDocumentCount, 1)
    }

    func test_nativeClosureConfirmationTracksAttachmentAndUnsavedWork() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.closureConfirmation
        let window = UIWindow(windowScene: scene)
        let view = SceneRegistrationView()
        defer {
            view.removeFromSuperview()
            scene.closureConfirmation = previous
        }

        view.unsavedDocumentCount = 2
        window.addSubview(view)
        let confirmation = try XCTUnwrap(scene.closureConfirmation)
        view.unsavedDocumentCount = 2
        XCTAssertTrue(scene.closureConfirmation === confirmation, "Unchanged state must not replace a displayed dialog")
        view.unsavedDocumentCount = 0
        XCTAssertNil(scene.closureConfirmation)
        view.unsavedDocumentCount = 1
        XCTAssertNotNil(scene.closureConfirmation)
        view.removeFromSuperview()
        XCTAssertNil(scene.closureConfirmation)
        window.addSubview(view)
        XCTAssertNotNil(scene.closureConfirmation)
        view.clearClosureConfirmation()
        XCTAssertNil(scene.closureConfirmation)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testNativeWindowReviewCancelsSystemClosureForOneOrManyDocuments() {
        let view = SceneRegistrationView()
        for count in [1, 3] {
            view.unsavedDocumentCount = count
            let actions = view.closureActions()
            XCTAssertEqual(actions.map(\.title), ["Review Changes…", "Don’t Save"])
            XCTAssertEqual(
                actions.map(\.style), [.cancel, .destructive],
                "UIKit closes after every non-cancel action; reviewing must keep the scene alive")
            XCTAssertEqual(
                actions.filter { $0.style == .cancel }.count, 1,
                "UIAlertController allows only one cancel action")
        }
    }

    func test_closeWindowCommandUsesTheRequestedWindowConfirmation() {
        let first = EditorSession()
        let second = EditorSession()
        var firstRequests = 0
        var secondRequests = 0
        first.requestClose = { target in
            guard case .window = target else { return XCTFail("Expected window closure") }
            firstRequests += 1
        }
        second.requestClose = { _ in secondRequests += 1 }
        CommandActions.closeWindow(session: first)
        XCTAssertEqual(firstRequests, DeviceIdiom.supportsMultipleWindows ? 1 : 0)
        XCTAssertEqual(secondRequests, 0)
        XCTAssertFalse(first.isClosingWindow)
    }

    func test_saveAllAndCloseCommandUsesOnlyItsOwningWindow() {
        let bus = AppStateBus.shared
        let first = EditorSession()
        let other = EditorSession()
        let previousFocus = bus.scenes.currentSession
        bus.scenes.currentSession = other
        defer { bus.scenes.currentSession = previousFocus }
        var saves = 0
        first.requestClose = { _ in XCTFail("Save All must skip review") }
        first.requestSaveAllAndCloseWindow = { saves += 1 }
        other.requestSaveAllAndCloseWindow = { XCTFail("Must not save the newly focused window") }

        CommandActions.saveAllAndCloseWindow(session: first)

        XCTAssertEqual(saves, DeviceIdiom.supportsMultipleWindows ? 1 : 0)
        XCTAssertFalse(first.isClosingWindow, "The command must wait for the owning scene to finish saving")
        first.requestSaveAllAndCloseWindow = nil
        CommandActions.saveAllAndCloseWindow(session: first)
        XCTAssertFalse(first.isClosingWindow)
        if DeviceIdiom.supportsMultipleWindows {
            XCTAssertNotNil(first.activeTab.state.operationError)
        }
    }

    func test_windowSaveAsFailureLeavesUntitledWorkOpen() async throws {
        let session = EditorSession()
        let tab = session.activeTab
        tab.startDocument(with: "unsaved 😀")
        defer { tab.document.deleteScratchFile() }
        do {
            _ = try await session.saveDocumentsBeforeClosing { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("Expected Save As failure")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteNoPermission)
        }
        XCTAssertTrue(session.activeTab === tab)
        XCTAssertEqual(tab.document.text, "unsaved 😀")
        XCTAssertTrue(tab.document.isDirty)
        XCTAssertNil(tab.document.fileURL)
        XCTAssertFalse(session.isClosingWindow)
    }

    func test_windowSaveIncludesPinnedAndInactiveTabsButNotOtherWindows() async throws {
        let session = EditorSession()
        let other = EditorSession()
        let first = session.activeTab
        first.startDocument(with: "first 😀")
        first.isPinned = true
        let second = session.newTab()
        second.startDocument(with: "second")
        session.newTab()
        other.activeTab.startDocument(with: "other window")
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            for tab in session.tabs + other.tabs { tab.document.deleteScratchFile() }
        }
        var savedIDs: [UUID] = []
        let saved = try await session.saveDocumentsBeforeClosing { tab in
            XCTAssertEqual(session.selectedTabID, tab.id)
            savedIDs.append(tab.id)
            try await DocumentWorkflow.save(tab, to: directory.appendingPathComponent("\(tab.id).txt"))
            return true
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(savedIDs, [first.id, second.id])
        XCTAssertEqual(session.unsavedDocumentCount, 0)
        XCTAssertEqual(other.unsavedDocumentCount, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(first.document.fileURL)), first.document.originalData)
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(second.document.fileURL), encoding: .utf8), second.document.text)
    }

    func test_windowSaveUpdatesExistingFileBeforeCancelledSaveAsAndKeepsTabs() async throws {
        let session = EditorSession()
        let first = session.activeTab
        first.startDocument(with: "original")
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            for tab in session.tabs { tab.document.deleteScratchFile() }
        }
        let url = directory.appendingPathComponent("existing.txt")
        try await DocumentWorkflow.save(first, to: url)
        first.document.text = "edited existing file"
        first.document.isDirty = true
        let second = session.newTab()
        second.startDocument(with: "untitled work")
        let saved = try await session.saveDocumentsBeforeClosing { tab in
            XCTAssertTrue(tab === second)
            return false
        }
        XCTAssertFalse(saved)
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertFalse(session.isClosingWindow)
        XCTAssertFalse(first.document.isDirty)
        XCTAssertTrue(second.document.isDirty)
        XCTAssertNil(second.document.fileURL)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first.document.text)
    }

    func test_windowSaveFailureDoesNotOverwriteExternalChangesOrContinue() async throws {
        let session = EditorSession()
        let tab = session.activeTab
        tab.startDocument(with: "original")
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            for tab in session.tabs { tab.document.deleteScratchFile() }
        }
        let url = directory.appendingPathComponent("conflict.txt")
        try await DocumentWorkflow.save(tab, to: url)
        tab.document.text = "my edits"
        tab.document.isDirty = true
        session.newTab().startDocument(with: "keep this too")
        let external = Data("external edits".utf8)
        try external.write(to: url, options: .atomic)
        do {
            _ = try await session.saveDocumentsBeforeClosing { _ in
                XCTFail("Save As must not continue after a failed source save")
                return true
            }
            XCTFail("Expected source conflict")
        } catch PlainTextDocument.DocumentError.sourceChanged {}
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(tab.document.text, "my edits")
        XCTAssertEqual(session.unsavedDocumentCount, 2)
        XCTAssertFalse(session.isClosingWindow)
    }

    func test_windowSaveWaitsForSaveAsAndCancellationStopsClose() async throws {
        let session = EditorSession()
        session.activeTab.startDocument(with: "waiting")
        defer { for tab in session.tabs { tab.document.deleteScratchFile() } }
        var reply: CheckedContinuation<Bool, Never>?
        var finished = false
        let operation = Task { @MainActor in
            defer { finished = true }
            return try await session.saveDocumentsBeforeClosing { _ in
                await withCheckedContinuation { reply = $0 }
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while reply == nil, clock.now < deadline { await Task.yield() }
        guard let reply else {
            operation.cancel()
            XCTFail("Save As was not requested")
            return
        }
        XCTAssertFalse(finished)
        XCTAssertFalse(session.isClosingWindow)
        operation.cancel()
        reply.resume(returning: true)
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(session.unsavedDocumentCount, 1)
        XCTAssertEqual(session.tabs.count, 1)
    }

    func test_windowSaveRefusesCloseWhenAnotherTabGainsChanges() async throws {
        let session = EditorSession()
        session.activeTab.startDocument(with: "save this")
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            for tab in session.tabs { tab.document.deleteScratchFile() }
        }
        do {
            _ = try await session.saveDocumentsBeforeClosing { tab in
                try await DocumentWorkflow.save(tab, to: directory.appendingPathComponent("saved.txt"))
                session.newTab().startDocument(with: "new changes during Save As")
                return true
            }
            XCTFail("New changes must prevent closing")
        } catch EditorSession.WindowSaveError.changedDuringSave {}
        XCTAssertEqual(session.unsavedDocumentCount, 1)
        XCTAssertEqual(session.tabs.count, 2)
    }

    @MainActor
    private final class Pane {
        let document: PlainTextDocument
        let state: EditorState
        let editor = PilcrowTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let coordinator: EditorTextViewCoordinator

        init(document: PlainTextDocument, state: EditorState = EditorState()) {
            self.document = document
            self.state = state
            coordinator = EditorTextViewCoordinator(document: document, state: state)
            editor.text = document.text
            editor.editorDelegate = coordinator
            state.text = document.text
            state.textView = editor
            coordinator.lastPushedDocumentText = document.text
        }
    }

    private func panes(_ text: String) -> (Pane, Pane) {
        let document = PlainTextDocument()
        document.text = text
        let first = Pane(document: document)
        let second = Pane(document: document)
        first.state.siblingState = second.state
        second.state.siblingState = first.state
        second.editor.shareUndoHistory(with: first.editor)
        return (first, second)
    }

    func test_splitTypingUndoAndRedoShareOneHistory() {
        let (first, second) = panes("abc")
        first.editor.selectedRange = NSRange(location: 3, length: 0)
        first.editor.insertText("😀")
        XCTAssertEqual(first.editor.text, "abc😀")
        XCTAssertEqual(second.editor.text, first.editor.text)
        XCTAssertTrue(first.editor.undoManager === second.editor.undoManager)

        second.editor.undoManager?.undo()
        XCTAssertEqual(first.editor.text, "abc")
        XCTAssertEqual(second.editor.text, "abc")
        first.editor.undoManager?.redo()
        XCTAssertEqual(first.editor.text, "abc😀")
        XCTAssertEqual(second.editor.text, "abc😀")
    }

    func test_splitSecondaryEditsAndUndoPreservePrimarySelection() {
        let (first, second) = panes("abc def")
        first.editor.selectedRange = NSRange(location: 5, length: 2)
        second.editor.selectedRange = NSRange(location: 0, length: 0)
        second.editor.insertText("😀")
        XCTAssertEqual(first.editor.text, "😀abc def")
        XCTAssertEqual(first.editor.selectedRange, NSRange(location: 7, length: 2))
        first.editor.undoManager?.undo()
        XCTAssertEqual(first.editor.text, "abc def")
        XCTAssertEqual(second.editor.text, "abc def")
        XCTAssertEqual(first.editor.selectedRange, NSRange(location: 5, length: 2))
    }

    func test_splitListContinuationMirrorsOnlyAcceptedEdit() {
        let key = AppPreferenceKey.autoContinueLists
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let (first, second) = panes("- item")
        first.editor.selectedRange = NSRange(location: 6, length: 0)
        first.editor.insertText("\n")
        XCTAssertEqual(first.editor.text, "- item\n- ")
        XCTAssertEqual(second.editor.text, first.editor.text)
        first.editor.insertText("\n")
        XCTAssertEqual(first.editor.text, "- item\n")
        XCTAssertEqual(second.editor.text, first.editor.text)
    }

    func test_numberedListAtIntegerLimitDoesNotOverflow() {
        let document = PlainTextDocument()
        document.text = "\(Int.max). item"
        let pane = Pane(document: document)
        let range = NSRange(location: document.text.utf16.count, length: 0)
        _ = MarkdownListContinuation.handle(in: pane.editor, replacing: range)
        XCTAssertEqual(pane.editor.text, "\(Int.max). item\n\(Int.max). ")
    }

    func test_splitBatchReplaceIndentAndMoveLinesStaySynchronized() {
        let (first, second) = panes("one\ntwo\n")
        second.editor.selectedRange = NSRange(location: 4, length: 2)
        first.editor.replaceText(
            in: BatchReplaceSet(replacements: [
                .init(range: NSRange(location: 0, length: 3), text: "😀"),
                .init(range: NSRange(location: 4, length: 3), text: "TWO"),
            ]))
        XCTAssertEqual(second.editor.selectedRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(first.editor.text, "😀\nTWO\n")
        XCTAssertEqual(second.editor.text, first.editor.text)
        second.editor.undoManager?.undo()
        XCTAssertEqual(first.editor.text, "one\ntwo\n")
        XCTAssertEqual(second.editor.text, first.editor.text)

        first.editor.selectedRange = NSRange(location: 0, length: 3)
        first.editor.shiftRight()
        XCTAssertEqual(second.editor.text, first.editor.text)
        first.editor.moveSelectedLinesDown()
        XCTAssertEqual(second.editor.text, first.editor.text)
        second.editor.undoManager?.undo()
        XCTAssertEqual(second.editor.text, first.editor.text)
    }

    func test_splitMarkedTextKeepsCompositionInOriginatingPane() throws {
        let (first, second) = panes("abc")
        let input = try XCTUnwrap(first.editor.accessibilityTextInputResponder)
        first.editor.selectedRange = NSRange(location: 3, length: 0)
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(second.editor.text, "abcに")
        XCTAssertNotNil(first.editor.markedTextRange)
        XCTAssertNil(second.editor.markedTextRange)
        input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(first.editor.text, "abc日本")
        XCTAssertEqual(second.editor.text, first.editor.text)
        input.unmarkText()
        XCTAssertNil(first.editor.markedTextRange)
    }

    func test_dismantleCommitsLatestTextAndSelectionBeforeDebounce() {
        let document = PlainTextDocument()
        document.text = "a"
        let pane = Pane(document: document)
        pane.editor.selectedRange = NSRange(location: 1, length: 0)
        pane.editor.insertText("😀")
        XCTAssertEqual(document.text, "a")
        EditorTextView.dismantleUIView(pane.editor, coordinator: pane.coordinator)
        XCTAssertEqual(document.text, "a😀")
        XCTAssertEqual(pane.state.text, "a😀")
        XCTAssertEqual(pane.state.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertNil(pane.state.textView)
        XCTAssertNil(pane.coordinator.bufferSnapshotTask)
    }

    func test_dismantleCannotOverwriteAnExternalLoad() {
        let document = PlainTextDocument()
        document.text = "old"
        let pane = Pane(document: document)
        pane.editor.insertText("edit")
        document.text = "new document"
        EditorTextView.dismantleUIView(pane.editor, coordinator: pane.coordinator)
        XCTAssertEqual(document.text, "new document")
    }

    func test_obsoleteViewCannotOverwriteItsReplacement() {
        let document = PlainTextDocument()
        document.text = "old"
        let pane = Pane(document: document)
        pane.editor.insertText("edit")
        let replacement = PilcrowTextView()
        replacement.text = "new view"
        pane.state.textView = replacement
        EditorTextView.dismantleUIView(pane.editor, coordinator: pane.coordinator)
        XCTAssertEqual(document.text, "old")
        XCTAssertTrue(pane.state.textView === replacement)
    }

    func test_headingScanAndFoldingAgreeForUnicodeAndAllLineEndings() {
        for newline in ["\n", "\r", "\r\n"] {
            let text =
                ["# 😀", "body", "##\tSecond ##", "body", "#"].joined(separator: newline) as NSString
            let entries = OutlineBuilder.build(in: text)
            XCTAssertEqual(entries.map(\.row), [0, 2, 4])
            XCTAssertEqual(entries.map(\.level), [1, 2, 1])
            XCTAssertEqual(entries.map(\.title), ["😀", "Second", ""])
            XCTAssertEqual(entries, OutlineDiscovery.entries(in: text, language: .markdown))
            XCTAssertEqual(entries.map(\.id), OutlineBuilder.build(in: text).map(\.id))
            let folds = FoldDiscovery.allFoldableHeaders(in: text, language: .markdown)
            XCTAssertEqual(folds.map(\.headerRow), [0, 2])
            XCTAssertEqual(folds.map(\.bodyRange), [1...3, 3...3])
            XCTAssertEqual(
                FoldDiscovery.bodyRange(forHeaderRow: 0, in: text, language: .markdown), 1...3)
        }
    }

    func test_headingScanPreservesLiteralHashesAndRejectsNonHeadings() {
        let text = "# C#\n## title#\n### title ###\n#not-a-heading\n####### no\nplain" as NSString
        XCTAssertEqual(OutlineBuilder.build(in: text).map(\.title), ["C#", "title#", "title"])
        XCTAssertTrue(OutlineBuilder.build(in: "" as NSString).isEmpty)
    }

    private final class MountedEditorHost: UIHostingController<AnyView> {
        var didAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear?()
            didAppear = nil
        }
    }

    func test_compactEditorReservesStatusBarSpaceAndKeepsFirstLineAtTop() async throws {
        let document = PlainTextDocument()
        document.text = "dogs"
        let state = EditorState()
        let previousStatusBar = state.showStatusBar
        state.showStatusBar = true
        defer { state.showStatusBar = previousStatusBar }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let mounted = expectation(description: "Compact editor mounted")
        let host = MountedEditorHost(
            rootView: AnyView(
                EditorView(document: document, state: state)
                    .frame(width: 600, height: 300)
            ))
        host.didAppear = { mounted.fulfill() }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        await fulfillment(of: [mounted], timeout: 5)
        host.view.layoutIfNeeded()
        let editor = try XCTUnwrap(state.textView)
        editor.layoutIfNeeded()
        let firstLineY = editor.caretRect(atCharacterIndex: 0).minY - editor.contentOffset.y
        print(
            "EDITOR_LAYOUT frame=\(editor.frame) bounds=\(editor.bounds) inset=\(editor.adjustedContentInset) firstLineY=\(firstLineY)"
        )
        XCTAssertLessThanOrEqual(editor.bounds.height, 276, "The status bar must reserve space below the editor")
        XCTAssertLessThanOrEqual(firstLineY, 20, "The first line must not gain a blank header")
        XCTAssertGreaterThanOrEqual(firstLineY, 0)
        let attachment = XCTAttachment(
            image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
        attachment.name = "compact-editor-layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test_windowLayoutReservesStatusSpaceDuringResize() async throws {
        let session = EditorSession()
        session.activeTab.startDocument(with: "dogs")
        let state = session.activeTab.state
        let previousToolbar = state.showToolbar
        let previousStatus = state.showStatusBar
        state.showStatusBar = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let appeared = expectation(description: "Window content mounted")
        let host = MountedEditorHost(
            rootView: AnyView(
                EditorScene(route: .constant(.newDocument()), session: session)
                    .environment(\.scenePhase, .active)
            ))
        host.didAppear = { appeared.fulfill() }
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        window.rootViewController = container
        host.view.frame = CGRect(x: 30, y: 100, width: 700, height: 500)
        window.makeKeyAndVisible()
        defer {
            session.isClosingWindow = true
            state.textView?.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            state.autoSaveTask?.cancel()
            session.activeTab.document.deleteScratchFile()
            state.showToolbar = previousToolbar
            state.showStatusBar = previousStatus
        }
        await fulfillment(of: [appeared], timeout: 5)
        try await Task.sleep(for: .milliseconds(150))
        let editor = try XCTUnwrap(state.textView)
        let sizes = [CGSize(width: 700, height: 500), CGSize(width: 360, height: 300)]
        for (toolbar, size) in [false, true].flatMap({ toolbar in sizes.map { (toolbar, $0) } }) {
            state.showToolbar = toolbar
            host.view.frame.size = size
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let frame = editor.convert(editor.bounds, to: host.view)
            let firstLineY = editor.caretRect(atCharacterIndex: 0).minY - editor.contentOffset.y
            print(
                "WINDOW_LAYOUT toolbar=\(toolbar) size=\(size) editor=\(frame) inset=\(editor.adjustedContentInset) firstLineY=\(firstLineY)"
            )
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertGreaterThanOrEqual(frame.height, 0)
            XCTAssertLessThanOrEqual(frame.maxY, size.height - 20, "The status bar must reserve space")
            XCTAssertLessThanOrEqual(firstLineY, 20)
            XCTAssertGreaterThanOrEqual(firstLineY, 0)
        }
        let attachment = XCTAttachment(
            image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
        attachment.name = "compact-window-with-status"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test_keyboardSafeAreaTracksOffsetAndResizedEditor() async throws {
        let session = EditorSession()
        session.activeTab.startDocument(with: Array(repeating: "dogs", count: 100).joined(separator: "\n"))
        let state = session.activeTab.state
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let appeared = expectation(description: "Offset editor mounted")
        let host = MountedEditorHost(rootView: AnyView(EditorScene(route: .constant(.newDocument()), session: session)))
        host.didAppear = { appeared.fulfill() }
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        window.rootViewController = container
        host.view.frame = CGRect(x: 30, y: 100, width: 700, height: 500)
        window.makeKeyAndVisible()
        defer {
            session.isClosingWindow = true
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            state.autoSaveTask?.cancel()
            session.activeTab.document.deleteScratchFile()
        }
        await fulfillment(of: [appeared], timeout: 5)
        let editor = try XCTUnwrap(state.textView)
        editor.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(500))
        let baselineBottom = editor.convert(editor.bounds, to: host.view).maxY
        let end = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.selectedRange = end
        editor.scrollRangeToVisible(end)
        editor.becomeFirstResponder()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while container.view.keyboardLayoutGuide.layoutFrame.height < 100, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard container.view.keyboardLayoutGuide.layoutFrame.height > 100 else {
            throw XCTSkip("Requires Simulator software keyboard; the UI test separately requires it to be visible.")
        }
        let keyboardTop = container.view.keyboardLayoutGuide.layoutFrame.minY
        for frame in [
            CGRect(x: 30, y: 100, width: 700, height: 500),
            CGRect(x: 30, y: keyboardTop - 350, width: 700, height: 500),
            CGRect(x: 30, y: keyboardTop - 300, width: 360, height: 400),
            CGRect(x: 30, y: 100, width: 700, height: 500),
        ] {
            host.view.frame = frame
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let actual = editor.convert(editor.bounds, to: host.view)
            let overlap = max(0, frame.maxY - keyboardTop)
            let statusHeight = 500 - baselineBottom
            let expectedBottom = frame.height - overlap - statusHeight
            print("OFFSET_KEYBOARD host=\(frame) editor=\(actual) keyboardTop=\(keyboardTop)")
            XCTAssertGreaterThanOrEqual(actual.minY, 0)
            XCTAssertGreaterThan(actual.height, 44)
            let caret = editor.caretRect(atCharacterIndex: end.location).offsetBy(
                dx: -editor.contentOffset.x, dy: -editor.contentOffset.y)
            print("RESIZE_CARET caret=\(caret) bounds=\(editor.bounds)")
            XCTAssertGreaterThanOrEqual(caret.minY, 0)
            XCTAssertLessThanOrEqual(caret.maxY, editor.bounds.height + 1)
            XCTAssertEqual(
                actual.maxY, expectedBottom, accuracy: 35,
                "Reserve the local keyboard overlap once, keeping status controls at the visible bottom")
        }
        // Resizing while reading elsewhere must preserve the user's scroll position.
        editor.setContentOffset(.zero, animated: false)
        host.view.frame.size.height = 400
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(editor.contentOffset.y, 0, accuracy: 1)
        XCTAssertEqual(editor.selectedRange, end)
    }

    func test_keyboardAccessoryExposesButtonAndStickySelection() {
        let button = AccessoryButton()
        button.configure(symbol: "command", accessibility: "Command")
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertEqual(button.accessibilityLabel, "Command")
        XCTAssertEqual(button.accessibilityTraits, .button)
        button.isToggled = true
        XCTAssertEqual(button.accessibilityTraits, [.button, .selected])
        button.isToggled = false
        XCTAssertEqual(button.accessibilityTraits, .button)
    }

    func test_exportFilenamePreservesUserSuffixAndSelectedLanguage() {
        XCTAssertEqual(
            LanguageRegistry.suggestedFilename("Untitled", language: .markdown), "Untitled.md")
        XCTAssertEqual(
            LanguageRegistry.suggestedFilename("notes.tex", language: .plain), "notes.tex")
        XCTAssertEqual(
            LanguageRegistry.suggestedFilename("Untitled", language: .plain), "Untitled.txt")
        XCTAssertEqual(TextFileWrapperProxy.writableContentTypes, [.data])
    }

    func test_shortViewportKeepsCaretVisibleWithScrollPastEnd() async throws {
        let document = PlainTextDocument()
        document.text = Array(repeating: "line", count: 20).joined(separator: "\n")
        let state = EditorState()
        let previousOverscroll = state.overscroll
        state.overscroll = true
        defer { state.overscroll = previousOverscroll }
        let appeared = expectation(description: "Short text view mounted")
        let host = MountedEditorHost(
            rootView: AnyView(
                EditorTextView(document: document, state: state).frame(width: 600, height: 80)
            ))
        host.didAppear = { appeared.fulfill() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [appeared], timeout: 5)
        let editor = try XCTUnwrap(state.textView)
        editor.layoutIfNeeded()
        let end = NSRange(location: editor.text.utf16.count, length: 0)
        editor.setSelection(end)
        for _ in 0..<3 {
            editor.scrollRangeToVisible(end)
            let caret = editor.caretRect(atCharacterIndex: end.location).offsetBy(
                dx: -editor.contentOffset.x, dy: -editor.contentOffset.y)
            XCTAssertGreaterThanOrEqual(caret.minY, 0, "Repeated caret reveal must not scroll it above the viewport")
            XCTAssertLessThanOrEqual(caret.maxY, editor.bounds.height + 1)
        }
    }

    func test_shortSplitPanesStayInsideTheirAvailableSpace() async throws {
        let session = EditorSession()
        let tab = session.activeTab
        tab.startDocument(with: "dogs")
        let state = tab.state
        state.splitOpen = true
        state.splitOrientation = .vertical
        let secondary = tab.ensureSecondaryState()
        let router = AppStateBus.shared.scenes
        let previousSession = router.currentSession
        let previousEditor = router.currentEditor
        let previousStatus = state.showStatusBar
        state.showStatusBar = false
        router.registerSession(session)
        router.claimFocus(session: session)
        let appeared = expectation(description: "Short split mounted")
        let host = MountedEditorHost(
            rootView: AnyView(
                EditorView(document: tab.document, state: state).frame(width: 600, height: 100)
            ))
        host.didAppear = { appeared.fulfill() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
            state.showStatusBar = previousStatus
            router.deregisterSession(session)
            router.currentSession = previousSession
            router.currentEditor = previousEditor
            state.autoSaveTask?.cancel()
            tab.document.deleteScratchFile()
        }
        await fulfillment(of: [appeared], timeout: 5)
        host.view.layoutIfNeeded()
        let first = try XCTUnwrap(state.textView)
        let second = try XCTUnwrap(secondary.textView)
        let firstFrame = first.convert(first.bounds, to: host.view)
        let secondFrame = second.convert(second.bounds, to: host.view)
        print("SPLIT_LAYOUT first=\(firstFrame) second=\(secondFrame)")
        XCTAssertGreaterThan(first.bounds.height, 0)
        XCTAssertGreaterThan(second.bounds.height, 0)
        XCTAssertLessThanOrEqual(secondFrame.maxY - firstFrame.minY, 100)
        XCTAssertEqual(secondFrame.minY - firstFrame.maxY, 6, accuracy: 1)
        state.splitOrientation = .horizontal
        host.rootView = AnyView(EditorView(document: tab.document, state: state).frame(width: 100, height: 300))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.textView === first)
        XCTAssertTrue(secondary.textView === second)
        let left = first.convert(first.bounds, to: host.view)
        let right = second.convert(second.bounds, to: host.view)
        XCTAssertGreaterThan(first.bounds.width, 0)
        XCTAssertGreaterThan(second.bounds.width, 0)
        XCTAssertLessThanOrEqual(right.maxX - left.minX, 100)
        XCTAssertEqual(right.minX - left.maxX, 6, accuracy: 1)
    }

    func test_scrollPastEndExtentTracksResizeAndCanBeDisabled() {
        let editor = PilcrowTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
        editor.text = "dogs"
        editor.layoutIfNeeded()
        let documentHeight = editor.contentSize.height
        editor.verticalOverscrollFactor = 0.5
        editor.layoutIfNeeded()
        XCTAssertEqual(editor.contentSize.height, documentHeight + 50, accuracy: 1)
        editor.frame.size.height = 300
        editor.layoutIfNeeded()
        XCTAssertEqual(editor.contentSize.height, documentHeight + 150, accuracy: 1)
        editor.verticalOverscrollFactor = 0
        editor.layoutIfNeeded()
        XCTAssertEqual(editor.contentSize.height, documentHeight, accuracy: 1)
    }

    func test_editorDoesNotReapplyContainerTopInset() async throws {
        let document = PlainTextDocument()
        document.text = "dogs"
        let state = EditorState()
        let appeared = expectation(description: "Editor with container chrome mounted")
        let host = MountedEditorHost(
            rootView: AnyView(
                EditorTextView(document: document, state: state)
                    .ignoresSafeArea(.container, edges: .top)
            ))
        host.additionalSafeAreaInsets.top = 108
        host.didAppear = { appeared.fulfill() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [appeared], timeout: 5)
        let editor = try XCTUnwrap(state.textView)
        editor.layoutIfNeeded()
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let firstLineY = editor.caretRect(atCharacterIndex: 0).minY - editor.contentOffset.y
        print(
            "CONTAINER_INSET safe=\(editor.safeAreaInsets) adjusted=\(editor.adjustedContentInset) firstLineY=\(firstLineY)"
        )
        XCTAssertGreaterThanOrEqual(firstLineY, 0)
        XCTAssertLessThanOrEqual(firstLineY, 20, "Native scrolling must respect the rectangle allocated by SwiftUI")
    }

    func test_headingsAndPreviewAgreeAcrossFencesAndSetext() {
        for newline in ["\n", "\r", "\r\n"] {
            let source = [
                "Title 😀", "===", "  ````swift", "# hidden", "```", "[^hidden]: literal", "  ````",
                "    # code", "Subheading", "---", "## C# ##",
            ].joined(separator: newline)
            let headings = OutlineBuilder.build(in: source as NSString)
            XCTAssertEqual(headings.map(\.row), [0, 8, 10])
            XCTAssertEqual(headings.map(\.title), ["Title 😀", "Subheading", "C#"])
            let html = SwiftMarkdown.render(source)
            XCTAssertTrue(html.contains("<h1>Title 😀</h1>"))
            XCTAssertTrue(html.contains("<h2>Subheading</h2>"))
            XCTAssertTrue(html.contains("<h2>C#</h2>"))
            XCTAssertFalse(html.contains("<h1>hidden</h1>"))
            XCTAssertFalse(html.contains("class=\"footnotes\""))
            XCTAssertTrue(html.contains("[^hidden]: literal"))
        }
    }

    func test_windowChromePreservesSecondaryPaneAndPickerOwnership() throws {
        let router = SceneRouter()
        let first = EditorSession()
        let second = EditorSession()
        router.registerSession(first)
        router.registerSession(second)
        let secondary = first.activeTab.ensureSecondaryState()
        router.claimFocus(state: secondary)
        router.claimFocus(preservingPaneOf: first.activeTab.state)
        XCTAssertTrue(router.currentEditor === secondary)
        XCTAssertTrue(router.currentSession === first)
        first.pickers.pending = .saveAs
        router.claimFocus(session: second)
        second.pickers.pending = .insertFile
        XCTAssertEqual(first.pickers.pending, .saveAs)
        XCTAssertEqual(second.pickers.pending, .insertFile)
        let sources = MultiFileSearchSheet.SearchEngine.tabsSources(in: first)
        XCTAssertEqual(sources.first?.groupKey, .tab(first.activeTab.id))
        let url = URL(fileURLWithPath: "/tmp/review.txt")
        let route = EditorRoute.openDocument(url, line: 42)
        XCTAssertNotEqual(route, EditorRoute.openDocument(url, line: 42))
        XCTAssertEqual(
            try JSONDecoder().decode(EditorRoute.self, from: JSONEncoder().encode(route)), route)
    }

    func test_folderSearchReportsSkippedFilesAndInsertionFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("cat".utf8).write(to: root.appendingPathComponent("good.txt"))
        try Data(repeating: 0, count: 5 * 1024 * 1024 + 1).write(
            to: root.appendingPathComponent("large.txt"))
        let output = try await MultiFileSearchSheet.SearchEngine.runFolderSearch(
            folder: root,
            matcher: .init(regex: nil, literal: "cat", caseSensitive: true), extensions: ["txt"])
        XCTAssertEqual(output.results.count, 1)
        XCTAssertEqual(output.sourcesScanned, 2)
        XCTAssertTrue(output.issues.contains { $0.contains("large.txt") })
        let listing = try await DocumentWorkflow.insertionText(
            from: root, folder: true, lineEnding: "\r\n")
        XCTAssertTrue(listing.contains("├── good.txt\r\n└── large.txt\r\n"))
        do {
            _ = try await DocumentWorkflow.insertionText(
                from: root.appendingPathComponent("missing"), folder: true, lineEnding: "\n")
            XCTFail("An unreadable folder must report failure")
        } catch {}
    }

    func test_newSplitPaneStartsWithLatestUnflushedText() async throws {
        let document = PlainTextDocument()
        document.text = "a"
        let first = Pane(document: document)
        first.editor.selectedRange = NSRange(location: 1, length: 0)
        first.editor.insertText("😀")
        XCTAssertEqual(document.text, "a")
        first.coordinator.bufferSnapshotTask?.cancel()

        let secondState = EditorState()
        first.state.siblingState = secondState
        secondState.siblingState = first.state
        let mounted = expectation(description: "Split pane mounted")
        let host = MountedEditorHost(
            rootView: AnyView(EditorTextView(document: document, state: secondState)))
        host.didAppear = { mounted.fulfill() }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.view.layoutIfNeeded()
        await fulfillment(of: [mounted], timeout: 2)
        let second = try XCTUnwrap(secondState.textView)
        XCTAssertEqual(document.text, "a😀")
        XCTAssertEqual(second.text, first.editor.text)
        XCTAssertTrue(second.undoManager === first.editor.undoManager)
        second.undoManager?.undo()
        XCTAssertEqual(first.editor.text, "a")
        XCTAssertEqual(second.text, "a")
    }

    func test_failedSavePreservesDirtyBufferAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = root.appendingPathComponent("recovery.txt")
        try Data("unsaved".utf8).write(to: draft)
        let tab = TabModel()
        let document = tab.document
        document.text = "unsaved"
        document.isDirty = true
        document.draftURL = draft
        let originalKey = document.revisionKey
        do {
            try await DocumentWorkflow.save(tab, to: root)
            XCTFail("Saving over a directory must fail")
        } catch {}
        XCTAssertNil(document.fileURL)
        XCTAssertEqual(document.text, "unsaved")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.draftURL, draft)
        XCTAssertEqual(document.revisionKey, originalKey)
        XCTAssertEqual(try Data(contentsOf: draft), Data("unsaved".utf8))
    }

    func test_saveToNewLocationUpdatesRevisionIdentityAndPreservesOldFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old.txt")
        let newURL = root.appendingPathComponent("new.txt")
        let tab = TabModel()
        let document = tab.document
        document.text = "first"
        try await DocumentWorkflow.save(tab, to: oldURL)
        let firstData = try Data(contentsOf: oldURL)
        document.text = "second"
        document.isDirty = true
        try await DocumentWorkflow.save(tab, to: newURL)
        XCTAssertEqual(document.revisionKey, RevisionStore.key(for: newURL))
        XCTAssertEqual(document.fileURL, newURL)
        XCTAssertEqual(document.originalData, try Data(contentsOf: newURL))
        XCTAssertEqual(try Data(contentsOf: oldURL), firstData)
        XCTAssertFalse(document.isDirty)
    }

    func test_saveRejectsChangedBytesEvenWhenSizeAndDateMatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = TabModel()
        tab.document.text = "original"
        try await DocumentWorkflow.save(tab, to: url)
        let date = try XCTUnwrap(tab.document.sourceMtimeAtLoad)
        try Data("external".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        tab.document.text = "my edit"
        tab.document.isDirty = true
        do {
            try await DocumentWorkflow.save(tab)
            XCTFail("A same-size external edit must not be overwritten")
        } catch PlainTextDocument.DocumentError.sourceChanged {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        XCTAssertEqual(tab.document.text, "my edit")
        XCTAssertTrue(tab.document.isDirty)
        try await DocumentWorkflow.save(tab, overwrite: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "my edit")
    }

    func test_saveRetainsEditsMadeWhileWaitingForFileCoordination() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = TabModel()
        tab.document.text = "base"
        try await DocumentWorkflow.save(tab, to: url)
        tab.document.text = "saved"
        let pane = Pane(document: tab.document, state: tab.state)
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await CoordinatedFileAccess.perform(at: url, writing: true) { _ in
                entered.continuation.yield(())
                entered.continuation.finish()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        for await _ in entered.stream { break }
        let saving = Task { try await DocumentWorkflow.save(tab) }
        while !tab.document.isSaving { await Task.yield() }
        pane.editor.selectedRange = NSRange(location: 5, length: 0)
        pane.editor.insertText(" newer")
        release.signal()
        try await blocker.value
        try await saving.value
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved")
        XCTAssertEqual(pane.editor.text, "saved newer")
        XCTAssertEqual(tab.document.text, "saved newer")
        XCTAssertTrue(tab.document.isDirty)
        XCTAssertEqual(tab.state.savedBaselineText, "saved")
        tab.document.deleteScratchFile()
    }

    func test_cancelledFileAccessDoesNotRunItsAccessor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await CoordinatedFileAccess.perform(at: url, writing: true) { destination in
                try Data("should not be written".utf8).write(to: destination)
            }
        }
        do {
            try await task.value
            XCTFail("Canceled access should fail before writing")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_folderReplacementRejectsPostSearchChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("cat cat".utf8)
        try Data("cat dog".utf8).write(to: url)
        var context = FindContext()
        context.query = "cat"
        let engine = MultiFileSearchSheet.ReplacementEngine(folder: nil)
        do {
            _ = try await engine.applyReplacement(
                in: .url(url), query: "cat", replacement: "fox",
                context: context, expectedFingerprint: MultiFileSearchSheet.fingerprint(original),
                targetRanges: [NSRange(location: 0, length: 3)])
            XCTFail("Changed search sources must be rejected")
        } catch {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "cat dog")
    }

    func test_queryReplacementUpdatesSourceVersionAndOnlyDisplayedMatches() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("cat cat cat".utf8)
        try original.write(to: url)
        var context = FindContext()
        context.query = "cat"
        let engine = MultiFileSearchSheet.ReplacementEngine(folder: nil)
        let first = try await engine.applyReplacement(
            in: .url(url), query: "cat", replacement: "elephant",
            context: context, expectedFingerprint: MultiFileSearchSheet.fingerprint(original),
            targetRanges: [NSRange(location: 0, length: 3)])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "elephant cat cat")
        let second = try await engine.applyReplacement(
            in: .url(url), query: "cat", replacement: "elephant",
            context: context, expectedFingerprint: first.fingerprint,
            targetRanges: [NSRange(location: 4 + first.utf16Delta, length: 3)])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "elephant elephant cat")
    }

    func test_folderReplacementProtectsDirtyCopyInAnyWindow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("cat".utf8)
        try bytes.write(to: url)
        let sessions = [EditorSession(), EditorSession()]
        for session in sessions {
            session.activeTab.document.fileURL = url
            session.activeTab.document.text = "cat"
            session.activeTab.state.savedBaselineText = "cat"
            AppStateBus.shared.scenes.registerSession(session)
        }
        defer { for session in sessions { AppStateBus.shared.scenes.deregisterSession(session) } }
        sessions[1].activeTab.document.text = "unsaved"
        sessions[1].activeTab.document.isDirty = true
        var context = FindContext()
        context.query = "cat"
        do {
            _ = try await MultiFileSearchSheet.ReplacementEngine(folder: nil).applyReplacement(
                in: .url(url), query: "cat", replacement: "dog", context: context,
                expectedFingerprint: MultiFileSearchSheet.fingerprint(bytes),
                targetRanges: [NSRange(location: 0, length: 3)])
            XCTFail("A dirty copy in another window must be protected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(sessions[1].activeTab.document.text, "unsaved")
    }

    func test_targetedRegexReplacementUsesOriginalLookaroundContext() throws {
        var context = FindContext()
        context.query = "a(?=a)|a$"
        context.useRegex = true
        let result = try MultiFileSearchSheet.replaceInString(
            "aa", query: context.query,
            replacement: "b", context: context, limitToFirst: false,
            targetRanges: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])
        XCTAssertEqual(result.0, "bb")
        XCTAssertEqual(result.1, 2)
    }

    func test_closingTabCancelsPendingWork() async {
        let session = EditorSession()
        let tab = session.activeTab
        let load = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(60))
        }
        let autosave = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(60))
        }
        tab.state.loadTask = load
        tab.state.autoSaveTask = autosave
        session.closeTab(tab.id, disposition: .discard)
        XCTAssertTrue(load.isCancelled)
        XCTAssertTrue(autosave.isCancelled)
        XCTAssertNil(tab.state.loadTask)
        await load.value
        await autosave.value
    }

    func test_failedAsyncLoadPreservesExistingDocument() async throws {
        let document = PlainTextDocument()
        document.text = "unsaved"
        document.isDirty = true
        document.fileURL = URL(fileURLWithPath: "/original.txt")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        do {
            try await document.loadAsync(from: missing)
            XCTFail("A missing file should fail")
        } catch {
            XCTAssertEqual(document.text, "unsaved")
            XCTAssertTrue(document.isDirty)
            XCTAssertEqual(document.fileURL?.path, "/original.txt")
            XCTAssertFalse(document.isLoading)
        }
    }
}

extension EngineeringRegressionTests {
    func testDiscardWindowRemovesOnlyItsRecoveryAndLeavesSourceUnchanged() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("original file".utf8).write(to: source)
        let closing = EditorSession()
        let other = EditorSession()
        closing.sceneUUID = UUID().uuidString
        let first = closing.activeTab
        let second = other.activeTab
        let inactive = closing.newTab()
        defer {
            first.document.deleteScratchFile()
            second.document.deleteScratchFile()
            inactive.document.deleteScratchFile()
            SessionsStore.shared.remove(forScene: closing.sceneUUID)
            try? FileManager.default.removeItem(at: directory)
        }
        for tab in [first, second, inactive] {
            try await tab.document.loadAsync(from: source)
            tab.document.text = "edits in \(tab.id) 😀"
            tab.state.text = tab.document.text
            tab.document.isDirty = true
            try await tab.document.commitRecoverySnapshot()
            await tab.document.autoSave().value
        }
        let removed = try XCTUnwrap(first.document.draftURL)
        let retained = try XCTUnwrap(second.document.draftURL)
        let inactiveRecovery = try XCTUnwrap(inactive.document.draftURL)
        closing.persistRestorationRecord()
        XCTAssertNotNil(SessionsStore.shared.record(forScene: closing.sceneUUID))
        XCTAssertFalse(closing.prepareForWindowClose(discardChanges: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: removed.path))
        let lateCheckpoint = first.document.autoSave()
        let lateCommit = Task { try await closing.checkpointDocuments() }
        await Task.yield()

        XCTAssertTrue(closing.prepareForWindowClose(discardChanges: true))
        await lateCheckpoint.value
        try await lateCommit.value
        XCTAssertNil(SessionsStore.shared.record(forScene: closing.sceneUUID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertFalse(ScratchStore.loadAll().contains { $0.url.lastPathComponent == first.document.scratchFilename })
        XCTAssertFalse(
            ClosedWindowsStore.shared.records.contains { $0.draftFilenames.contains(removed.lastPathComponent) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveRecovery.path))
        XCTAssertFalse(
            ScratchStore.loadAll().contains { $0.url.lastPathComponent == inactive.document.scratchFilename })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original file")
        XCTAssertTrue(second.needsCloseConfirmation)
    }

    func testDiscardLastTabRemovesRestorationRecordAndDoesNotEnterClosedHistory() async throws {
        let session = EditorSession()
        session.sceneUUID = UUID().uuidString
        let tab = session.activeTab
        tab.startDocument(with: "discard this exact buffer 😀")
        defer {
            tab.document.deleteScratchFile()
            SessionsStore.shared.remove(forScene: session.sceneUUID)
        }
        await tab.document.autoSave().value
        session.persistRestorationRecord()
        let history = ClosedTabsStore.shared.records.map(\.id)
        XCTAssertNotNil(SessionsStore.shared.record(forScene: session.sceneUUID))

        XCTAssertTrue(session.closeTab(tab.id, disposition: .discard))

        XCTAssertEqual(session.activeTab.kind, .launcher)
        XCTAssertNil(SessionsStore.shared.record(forScene: session.sceneUUID))
        XCTAssertEqual(ClosedTabsStore.shared.records.map(\.id), history)
        XCTAssertFalse(ScratchStore.loadAll().contains { $0.url.lastPathComponent == tab.document.scratchFilename })
    }

    func testSaveSelectedTabsLeavesUnrelatedDirtyTabsOpen() async throws {
        let directory = try temporaryDirectory()
        let session = EditorSession()
        let kept = session.activeTab
        kept.startDocument(with: "keep writing here")
        let saved = session.newTab()
        saved.startDocument(with: "save only this 😀")
        session.selectedTabID = kept.id
        defer {
            for tab in session.tabs { tab.document.deleteScratchFile() }
            try? FileManager.default.removeItem(at: directory)
        }
        var asked: [UUID] = []
        let success = try await session.saveDocumentsBeforeClosing(tabIDs: [saved.id]) { tab in
            asked.append(tab.id)
            try await DocumentWorkflow.save(tab, to: directory.appendingPathComponent("saved.txt"))
            return true
        }
        XCTAssertTrue(success)
        XCTAssertEqual(asked, [saved.id])
        XCTAssertTrue(kept.needsCloseConfirmation)
        XCTAssertFalse(saved.needsCloseConfirmation)
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(saved.document.fileURL), encoding: .utf8), "save only this 😀")
    }

    func testTabAndBatchCloseReviewsStayWithTheirOriginatingWindow() {
        let bus = AppStateBus.shared
        let first = EditorSession()
        let second = EditorSession()
        let previousFocus = bus.scenes.currentSession
        bus.scenes.currentSession = second
        first.activeTab.startDocument(with: "unsaved")
        defer {
            bus.scenes.currentSession = previousFocus
            first.activeTab.document.deleteScratchFile()
        }
        var requests: [[UUID]] = []
        first.requestClose = { target in
            guard case .tabs(let ids) = target else { return XCTFail("Expected tab closure") }
            requests.append(ids)
        }
        second.requestClose = { _ in XCTFail("Must not review the newly focused window") }
        let tab = first.activeTab
        CommandActions.requestCloseTab(tab.id, in: first)
        CommandActions.requestCloseAllTabs(in: first)
        XCTAssertEqual(requests, [[tab.id], [tab.id]])
        XCTAssertEqual(first.tabs.count, 1)
        XCTAssertEqual(tab.document.text, "unsaved")
    }

    func testOneOrManyUnsavedDocumentsUseTheSameBatchReview() {
        for dirtyCount in [1, 2] {
            let session = EditorSession()
            session.activeTab.startDocument(with: "first")
            let second = session.newTab(kind: .editor)
            if dirtyCount == 2 { second.startDocument(with: "second") }
            defer { for tab in session.tabs { tab.document.deleteScratchFile() } }
            var requestedIDs: [UUID]?
            session.requestClose = { target in
                guard case .tabs(let ids) = target else { return XCTFail("Expected tab closure") }
                requestedIDs = ids
            }

            CommandActions.requestCloseAllTabs(in: session)

            XCTAssertEqual(requestedIDs, session.tabs.map(\.id))
            XCTAssertEqual(session.tabs.count, 2)
            XCTAssertEqual(session.unsavedDocumentCount, dirtyCount)
        }
    }

    func testMissingReviewPresenterKeepsAllUnsavedTabsOpen() {
        for dirtyCount in [1, 2] {
            let session = EditorSession()
            session.activeTab.startDocument(with: "first")
            if dirtyCount == 2 { session.newTab(kind: .editor).startDocument(with: "second") }
            defer { for tab in session.tabs { tab.document.deleteScratchFile() } }
            let contents = session.tabs.map(\.document.text)

            CommandActions.requestCloseAllTabs(in: session)

            XCTAssertEqual(session.tabs.map(\.document.text), contents)
            XCTAssertEqual(session.unsavedDocumentCount, dirtyCount)
            XCTAssertNotNil(session.activeTab.state.operationError)
        }
    }

    func testRestoreUsesNewerCheckpointAndPreservesExternalChangeBaseline() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let original = EditorSession()
        let restored = EditorSession()
        let tab = original.activeTab
        let previousStale = AppStateBus.shared.presentation.sourceStaleCheck
        defer {
            tab.document.deleteScratchFile()
            for tab in restored.tabs { tab.document.deleteScratchFile() }
            AppStateBus.shared.presentation.sourceStaleCheck = previousStale
            try? FileManager.default.removeItem(at: directory)
        }
        try await tab.document.loadAsync(from: source)
        let baselineDate = tab.document.sourceMtimeAtLoad
        let baselineSize = tab.document.sourceSizeAtLoad
        tab.document.text = "older lifecycle snapshot"
        tab.state.text = tab.document.text
        tab.document.isDirty = true
        try await tab.document.commitRecoverySnapshot()
        await tab.document.autoSave().value
        let record = SessionRecord(scene: UUID().uuidString, session: original)
        // Simulate further typing after the last lifecycle notification.
        tab.document.text = "newest 😀 e\u{301} text   \r\nno final newline"
        await tab.document.autoSave().value
        try Data("externally changed source with different length".utf8).write(to: source)

        SessionRestore.apply(record, to: restored)
        await restored.activeTab.state.loadTask?.value

        XCTAssertEqual(restored.activeTab.document.text, tab.document.text)
        XCTAssertTrue(restored.activeTab.needsCloseConfirmation)
        XCTAssertEqual(restored.activeTab.document.sourceMtimeAtLoad, baselineDate)
        XCTAssertEqual(restored.activeTab.document.sourceSizeAtLoad, baselineSize)
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8), "externally changed source with different length")
        guard case .changedOnAdopt(let id, _) = AppStateBus.shared.presentation.sourceStaleCheck else {
            return XCTFail("Expected external-change warning")
        }
        XCTAssertEqual(id, restored.activeTab.id)
    }

    func testRestoreUntitledCheckpointBeforeFirstBackgroundTransition() async throws {
        let original = EditorSession()
        let tab = original.activeTab
        let restored = EditorSession()
        defer {
            tab.document.deleteScratchFile()
            for tab in restored.tabs { tab.document.deleteScratchFile() }
        }
        tab.startDocument(with: "never backgrounded 😀\nkeep trailing spaces   ")
        await tab.document.autoSave().value
        XCTAssertNil(tab.document.draftURL)
        let record = SessionRecord(scene: UUID().uuidString, session: original)
        XCTAssertEqual(record.tabs.count, 1)
        XCTAssertEqual(record.tabs.first?.scratchFilename, tab.document.scratchFilename)

        SessionRestore.apply(record, to: restored)
        await restored.activeTab.state.loadTask?.value

        XCTAssertEqual(restored.activeTab.document.text, tab.document.text)
        XCTAssertTrue(restored.activeTab.needsCloseConfirmation)
        XCTAssertNil(restored.activeTab.document.fileURL)
        let recoveryURL = try XCTUnwrap(restored.activeTab.document.draftURL)
        let preserved = try await DraftsStore.readText(at: recoveryURL)
        XCTAssertEqual(preserved, tab.document.text)
    }
}

extension EngineeringRegressionTests {
    func testRestoreEmptyLegacyFileSnapshotDoesNotReloadDeletedText() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("legacy.txt")
        try Data("saved source text".utf8).write(to: source)
        let recovery = DraftsStore.shared.directory.appendingPathComponent("\(UUID()).txt")
        try Data().write(to: recovery)
        let session = EditorSession()
        let previousStale = AppStateBus.shared.presentation.sourceStaleCheck
        defer {
            DraftsStore.shared.discard(recovery)
            for tab in session.tabs { tab.document.deleteScratchFile() }
            AppStateBus.shared.presentation.sourceStaleCheck = previousStale
            try? FileManager.default.removeItem(at: directory)
        }
        let record = SessionRecord(
            sceneUUID: UUID().uuidString,
            tabs: [
                TabSnapshot(
                    fileBookmark: try source.bookmarkData(), draftFilename: recovery.lastPathComponent,
                    isPinned: false)
            ], activeIndex: 0, lastModified: Date(), launchID: "legacy", persistentIdentifier: nil)
        SessionRestore.apply(record, to: session)
        await session.activeTab.state.loadTask?.value
        XCTAssertEqual(session.activeTab.document.text, "")
        XCTAssertTrue(session.activeTab.needsCloseConfirmation)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "saved source text")
    }

    func testAppendRecoveredTabsPreservesExistingWork() async throws {
        let original = EditorSession()
        original.activeTab.startDocument(with: "recover this")
        await original.activeTab.document.autoSave().value
        let record = SessionRecord(scene: UUID().uuidString, session: original)
        let destination = EditorSession()
        let existing = destination.activeTab
        existing.startDocument(with: "keep this current work")
        defer {
            for tab in original.tabs + destination.tabs { tab.document.deleteScratchFile() }
        }
        SessionRestore.apply(record, to: destination, append: true)
        await destination.activeTab.state.loadTask?.value
        XCTAssertEqual(destination.tabs.count, 2)
        XCTAssertTrue(destination.tabs.first === existing)
        XCTAssertEqual(existing.document.text, "keep this current work")
        XCTAssertEqual(destination.activeTab.document.text, "recover this")
    }
}

extension EngineeringRegressionTests {
    func testReviewedCloseSavesOnlyCheckedDocumentsBeforeDiscard() async throws {
        let session = EditorSession()
        let discarded = session.activeTab
        discarded.startDocument(with: "unchecked work")
        let selected = session.newTab()
        selected.startDocument(with: "save this 😀")
        let directory = try temporaryDirectory()
        defer {
            discarded.document.deleteScratchFile()
            selected.document.deleteScratchFile()
            try? FileManager.default.removeItem(at: directory)
        }
        try await discarded.document.commitRecoverySnapshot()
        let recovery = try XCTUnwrap(discarded.document.draftURL)
        let reviewed = Set([discarded.id, selected.id])
        var saved: [UUID] = []

        let success = try await session.saveDocumentsBeforeClosing(
            discarding: [discarded.id], reviewed: reviewed
        ) { tab in
            saved.append(tab.id)
            try await DocumentWorkflow.save(tab, to: directory.appendingPathComponent("selected.txt"))
            return true
        }

        XCTAssertTrue(success)
        XCTAssertEqual(saved, [selected.id])
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertTrue(discarded.needsCloseConfirmation)
        XCTAssertFalse(selected.needsCloseConfirmation)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(selected.document.fileURL), encoding: .utf8), "save this 😀")
        XCTAssertTrue(session.prepareForWindowClose(discardChanges: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testReviewedCloseCancellationOrFailurePreservesUncheckedRecovery() async throws {
        let session = EditorSession()
        let discarded = session.activeTab
        discarded.startDocument(with: "unchecked must survive a canceled close")
        let selected = session.newTab()
        selected.startDocument(with: "selected but not yet saved")
        defer { for tab in session.tabs { tab.document.deleteScratchFile() } }
        try await session.checkpointDocuments()
        let recovery = try XCTUnwrap(discarded.document.draftURL)
        let reviewed = Set(session.tabs.map(\.id))

        let success = try await session.saveDocumentsBeforeClosing(
            discarding: [discarded.id], reviewed: reviewed
        ) { tab in
            XCTAssertTrue(tab === selected)
            return false
        }
        XCTAssertFalse(success)
        do {
            _ = try await session.saveDocumentsBeforeClosing(
                discarding: [discarded.id], reviewed: reviewed
            ) { _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("Expected save failure")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertEqual(session.unsavedDocumentCount, 2)
        XCTAssertFalse(session.isClosingWindow)
        let recovered = try await DraftsStore.readText(at: recovery)
        XCTAssertEqual(recovered, discarded.document.text)
    }

    func testReviewedCloseRejectsChangesNotIncludedInReview() async throws {
        let session = EditorSession()
        session.activeTab.startDocument(with: "reviewed")
        let reviewed = Set(session.tabs.map(\.id))
        session.newTab().startDocument(with: "arrived after review")
        defer { for tab in session.tabs { tab.document.deleteScratchFile() } }
        do {
            _ = try await session.saveDocumentsBeforeClosing(discarding: reviewed, reviewed: reviewed) { _ in
                XCTFail("New unsaved work requires a fresh decision")
                return true
            }
            XCTFail("Expected unreviewed changes to keep the window open")
        } catch EditorSession.WindowSaveError.changedDuringSave {}
        XCTAssertEqual(session.unsavedDocumentCount, 2)
        XCTAssertFalse(session.isClosingWindow)
    }

    func testReviewedCloseWithNothingSelectedDoesNotPresentSaveAs() async throws {
        let session = EditorSession()
        session.activeTab.startDocument(with: "first")
        session.newTab().startDocument(with: "second")
        defer { for tab in session.tabs { tab.document.deleteScratchFile() } }
        let reviewed = Set(session.tabs.map(\.id))
        let success = try await session.saveDocumentsBeforeClosing(discarding: reviewed, reviewed: reviewed) { _ in
            XCTFail("All documents were explicitly unchecked")
            return false
        }
        XCTAssertTrue(success)
        XCTAssertEqual(session.unsavedDocumentCount, 2, "The owner closes only after this operation succeeds")
    }
}

extension EngineeringRegressionTests {
    func testFailedWindowClosureCanResumePeriodicCheckpoints() async throws {
        let session = EditorSession()
        let tab = session.activeTab
        tab.startDocument(with: "before attempting to close")
        let pending = tab.state.autoSaveTask
        defer {
            tab.state.autoSaveTask?.cancel()
            tab.document.deleteScratchFile()
        }
        XCTAssertTrue(session.prepareForWindowClose(discardChanges: true))
        // UIKit can reject destruction. The owning window remains open and
        // returns to its normal editing state in the destruction error handler.
        session.isClosingWindow = false
        tab.document.text = "continued editing after the close failed 😀"
        tab.document.bufferRevision &+= 1
        tab.state.scheduleAutoSave(for: tab.document)
        await pending?.value
        await tab.state.autoSaveTask?.value

        let checkpoint = try XCTUnwrap(
            ScratchStore.loadAll().first {
                $0.url.lastPathComponent == tab.document.scratchFilename
            })
        let recovered = try await DraftsStore.readText(at: checkpoint.url)
        XCTAssertEqual(recovered, tab.document.text)
        XCTAssertTrue(session.tabs.contains { $0 === tab })
        XCTAssertTrue(tab.needsCloseConfirmation)
    }
}
