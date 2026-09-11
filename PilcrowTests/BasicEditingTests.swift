import FileEncoding
import UIKit
import XCTest

@testable import Pilcrow

@MainActor
final class BasicEditingTests: XCTestCase {
    @MainActor private final class Harness {
        let tab = TabModel()
        let editor = PilcrowTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let coordinator: EditorTextViewCoordinator
        let context = BasicCommandContext()
        init(_ text: String, find: FindContext = FindContext()) {
            tab.document.text = text
            tab.state.text = text
            tab.state.savedBaselineText = text
            editor.text = text
            coordinator = EditorTextViewCoordinator(document: tab.document, state: tab.state)
            editor.editorDelegate = coordinator
            tab.state.textView = editor
            context.scenes.currentEditor = tab.state
            context.find.context = find
            CommandActions.context = context
        }
        deinit {}
    }

    override func tearDown() async throws {
        await MainActor.run { CommandActions.context = AppStateBus.shared }
        try await super.tearDown()
    }

    func testReplaceAllExpandingMatchesIsOneUndoableEdit() throws {
        let h = Harness("cat cat cat", find: FindContext(query: "cat", replacement: "elephant"))
        XCTAssertEqual(try CommandActions.replaceAllMatches(), 3)
        XCTAssertEqual(h.editor.text, "elephant elephant elephant")
        h.editor.undoManager?.undo()
        XCTAssertEqual(h.editor.text, "cat cat cat")
        h.editor.undoManager?.redo()
        XCTAssertEqual(h.editor.text, "elephant elephant elephant")
    }

    func testReplaceAllShrinkingAndDeletingMatches() throws {
        let h = Harness("aaa", find: FindContext(query: "a", replacement: ""))
        XCTAssertEqual(try CommandActions.replaceAllMatches(), 3)
        XCTAssertEqual(h.editor.text, "")
    }

    func testWholeWordReplaceRejectsUnrelatedSelection() throws {
        let h = Harness("dog cat", find: FindContext(query: "cat", replacement: "fox", wholeWord: true))
        h.editor.setSelection(NSRange(location: 0, length: 3))
        XCTAssertFalse(try CommandActions.replaceSelectedMatch())
        XCTAssertEqual(h.editor.text, "dog cat")
    }

    func testWholeWordReplaceChecksBoundariesOutsideSelection() throws {
        let h = Harness("concatenate", find: FindContext(query: "cat", replacement: "fox", wholeWord: true))
        h.editor.setSelection(NSRange(location: 3, length: 3))
        XCTAssertFalse(try CommandActions.replaceSelectedMatch())
        XCTAssertEqual(h.editor.text, "concatenate")
    }

    func testRegexReplacementEvaluatesLookbehindInWholeDocument() throws {
        let h = Harness("prefix cat", find: FindContext(query: "(?<=prefix )(cat)", replacement: "$1!", useRegex: true))
        h.editor.setSelection(NSRange(location: 7, length: 3))
        XCTAssertTrue(try CommandActions.replaceSelectedMatch())
        XCTAssertEqual(h.editor.text, "prefix cat!")
    }

    func testWholeWordReplacementTreatsDollarAsLiteral() throws {
        let h = Harness("cat cat", find: FindContext(query: "cat", replacement: "$1", wholeWord: true))
        XCTAssertEqual(try CommandActions.replaceAllMatches(), 2)
        XCTAssertEqual(h.editor.text, "$1 $1")
    }

    func testInvalidRegexThrowsAndCommandReportsIt() {
        let h = Harness("cat", find: FindContext(query: "[", useRegex: true))
        XCTAssertThrowsError(try CommandActions.selectSearchMatch(forward: true))
        CommandActions.findNext()
        XCTAssertNotNil(h.context.presentation.openErrorMessage)
        XCTAssertEqual(h.editor.text, "cat")
    }

    func testRegexAnchorsDoNotTreatSearchSuffixAsDocument() throws {
        let h = Harness("dog cat", find: FindContext(query: "^cat", useRegex: true))
        h.editor.setSelection(NSRange(location: 4, length: 0))
        XCTAssertEqual(try CommandActions.selectSearchMatch(forward: true), "No other matches.")
        XCTAssertNil(
            try CommandActions.nextQueryReplaceMatch(
                query: "^cat", replacement: "", useRegex: true,
                caseSensitive: true, startingAt: 4))
    }

    func testZeroWidthFindAdvancesWrapsAndReachesDocumentEnd() throws {
        let h = Harness("a", find: FindContext(query: "^|$", useRegex: true))
        h.editor.setSelection(NSRange(location: 0, length: 0))
        _ = try CommandActions.selectSearchMatch(forward: true)
        XCTAssertEqual(h.editor.selectedRange.location, 0)
        _ = try CommandActions.selectSearchMatch(forward: true)
        XCTAssertEqual(h.editor.selectedRange.location, 1)
        _ = try CommandActions.selectSearchMatch(forward: true)
        XCTAssertEqual(h.editor.selectedRange.location, 0)
        _ = try CommandActions.selectSearchMatch(forward: false)
        XCTAssertEqual(h.editor.selectedRange.location, 1)
    }

    func testReplaceAllIncludesZeroWidthMatchInEmptyDocument() throws {
        let h = Harness("", find: FindContext(query: "^$", replacement: "hello", useRegex: true))
        XCTAssertEqual(try CommandActions.replaceAllMatches(), 1)
        XCTAssertEqual(h.editor.text, "hello")
    }

    func testSelectionReplaceKeepsOutsideLookaroundAndDoesNotInventAnchors() throws {
        let h = Harness("cat cat", find: FindContext(query: "^cat", replacement: "dog", useRegex: true))
        XCTAssertEqual(try CommandActions.replaceAllMatches(in: NSRange(location: 4, length: 3)), 0)
        XCTAssertEqual(h.editor.text, "cat cat")
    }

    func testQueryReplacementVisitsOriginalMatchesExactlyOnce() throws {
        let search = try DocumentSearch(text: "aa", context: FindContext(query: "a", replacement: "aaa"))
        var session = QueryReplacementSession(search: search, startingAt: 0)
        XCTAssertEqual(session.current?.range, NSRange(location: 0, length: 1))
        session.acceptReplacement(actualText: "aaaa")
        XCTAssertEqual(session.current?.range, NSRange(location: 3, length: 1))
        session.acceptReplacement(actualText: "aaaaaa")
        XCTAssertNil(session.current)
    }

    func testQuerySkipAndEndAnchorTerminate() throws {
        let search = try DocumentSearch(text: "a", context: FindContext(query: "^|$", replacement: "x", useRegex: true))
        var session = QueryReplacementSession(search: search, startingAt: 0)
        session.skip()
        XCTAssertEqual(session.current?.range, NSRange(location: 1, length: 0))
        session.acceptReplacement(actualText: "ax")
        XCTAssertNil(session.current)
    }

    func testLineSortScopeExcludesFollowingLineAndPreservesSurroundings() {
        let source = "heading\nz\na\nfooter\n"
        let target = LineEditTarget(text: source, selection: NSRange(location: 8, length: 4))
        XCTAssertEqual(target.text, "z\na\n")
        XCTAssertTrue(target.isSelection)
        XCTAssertEqual(
            (source as NSString).replacingCharacters(in: target.range, with: "a\nz\n"), "heading\na\nz\nfooter\n")
    }

    func testLineSortWithoutSelectionExplicitlyTargetsDocument() {
        let target = LineEditTarget(text: "b\na", selection: NSRange(location: 1, length: 0))
        XCTAssertFalse(target.isSelection)
        XCTAssertEqual(target.text, "b\na")
    }

    func testSelectWordHandlesContractionsCombiningMarksAndSupplementaryLetters() {
        for text in ["can't", "cafe\u{301}", "\u{10400}\u{10401}", "foo_bar"] {
            let h = Harness(text)
            h.editor.setSelection(NSRange(location: 0, length: 0))
            h.editor.selectCurrentWord()
            XCTAssertEqual(h.editor.text(in: h.editor.selectedRange), text)
        }
    }

    func testWritingStatisticsUseGraphemesAndSelection() {
        let source = "One two 😀 e\u{301}"
        let stats = WritingStatistics(
            .init(
                text: source, selection: NSRange(location: 4, length: 3),
                encoding: String.Encoding.utf8.rawValue, utf8BOM: false))
        XCTAssertEqual(stats.words, 3)
        XCTAssertEqual(stats.characters, source.count)
        XCTAssertEqual(stats.selectedWords, 1)
        XCTAssertEqual(stats.selectedCharacters, 3)
        XCTAssertEqual(stats.bufferBytes, source.utf8.count)
    }

    func testWritingStatisticsHonorEncodingAndBOM() {
        let stats = WritingStatistics(
            .init(
                text: "😀", selection: NSRange(location: 0, length: 0),
                encoding: String.Encoding.utf8.rawValue, utf8BOM: true))
        XCTAssertEqual(stats.characters, 1)
        XCTAssertEqual(stats.bufferBytes, 7)
        let invalid = WritingStatistics(
            .init(
                text: "😀", selection: .init(location: 0, length: 0),
                encoding: String.Encoding.ascii.rawValue, utf8BOM: false))
        XCTAssertNil(invalid.bufferBytes)
    }

    func testPaletteIncludesEveryBasicEditingAndSharingCommand() {
        for id in [
            "undo", "redo", "cut", "copy", "paste", "selectAll", "shareText", "shareFile", "print", "closeAllTabs",
        ] {
            XCTAssertNotNil(CommandRegistry.lookup(id: id), id)
        }
        XCTAssertEqual(CommandRegistry.lookup(id: "closeWindow") != nil, DeviceIdiom.supportsMultipleWindows)
    }

    func testDuplicateCheckpointsBeforeFurtherTyping() async throws {
        let session = EditorSession()
        let source = session.activeTab
        source.startDocument(with: "duplicate 😀 text  ")
        let context = BasicCommandContext()
        context.scenes.currentSession = session
        context.scenes.currentEditor = source.state
        CommandActions.context = context
        CommandActions.duplicateCurrentTab()
        let duplicate = session.activeTab
        defer {
            source.document.deleteScratchFile()
            duplicate.document.deleteScratchFile()
        }
        XCTAssertFalse(duplicate === source)
        let scratch = try XCTUnwrap(ScratchStore.directory)
            .appendingPathComponent(try XCTUnwrap(duplicate.document.liveRecoveryFilenames.first))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: scratch.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try String(contentsOf: scratch, encoding: .utf8), "duplicate 😀 text  ")
    }

    func testDelayedPaletteCommandKeepsOriginalEditorDespiteAnotherSheet() {
        let first = Harness("first")
        let second = Harness("second")
        second.context.presentation.present(.findReplace, owner: second.tab.state)
        CommandActions.perform(for: first.tab.state) { CommandActions.actions?.selectAll() }
        XCTAssertEqual(first.editor.selectedRange, NSRange(location: 0, length: 5))
        XCTAssertNotEqual(second.editor.selectedRange.length, 6)
        XCTAssertTrue(CommandActions.state === second.tab.state)
    }

    func testJavaScriptTransformRejectsChangesMadeWhileRunning() async throws {
        let h = Harness("original")
        let slot = JSTransformSlot(id: 1, name: "Test", code: "input + ' transformed'", scope: .document)
        JSTransformRunner.run(slot)
        let job = try XCTUnwrap(h.tab.state.transformTask)
        h.editor.insertText("new text")
        let edited = h.editor.text
        await job.value
        XCTAssertEqual(h.editor.text, edited)
        XCTAssertNotNil(h.tab.state.operationError)
    }

    func testEveryDefaultToolbarCommandExists() {
        for slot in ToolbarConfig.defaults {
            XCTAssertNotNil(CommandRegistry.lookup(id: slot.commandId), slot.commandId)
        }
    }

    func testLineCommentUsesLanguagePreservesIndentationAndRoundTrips() {
        let h = Harness("header\n  one\n\t two\nfooter\n")
        h.tab.state.languageIdentifier = .swift
        h.editor.setSelection(NSRange(location: 7, length: 12))
        CommandActions.toggleLineComment()
        XCTAssertEqual(h.editor.text, "header\n  // one\n\t // two\nfooter\n")
        CommandActions.toggleLineComment()
        XCTAssertEqual(h.editor.text, "header\n  one\n\t two\nfooter\n")
        h.editor.undoManager?.undo()
        XCTAssertEqual(h.editor.text, "header\n  // one\n\t // two\nfooter\n")
    }

    func testLegacySessionWithoutLayoutStillDecodes() throws {
        let snapshot = try JSONDecoder().decode(TabSnapshot.self, from: Data(#"{"isPinned":false}"#.utf8))
        XCTAssertNil(snapshot.editorLayout)
    }

    func testSessionRoundTripPreservesBothPanesAndSplit() throws {
        let h = Harness(String(repeating: "long line\n", count: 50))
        h.editor.setSelection(NSRange(location: 25, length: 4))
        h.tab.state.splitOpen = true
        h.tab.state.splitOrientation = .vertical
        h.tab.state.splitFraction = 0.7
        h.tab.ensureSecondaryState().selectedRange = NSRange(location: 45, length: 2)
        let snapshot = try JSONDecoder().decode(TabSnapshot.self, from: JSONEncoder().encode(TabSnapshot(of: h.tab)))
        let restored = TabModel()
        snapshot.editorLayout?.restore(to: restored)
        XCTAssertEqual(restored.state.selectedRange, NSRange(location: 25, length: 4))
        XCTAssertEqual(restored.secondaryState?.selectedRange, NSRange(location: 45, length: 2))
        XCTAssertTrue(restored.state.splitOpen)
        XCTAssertEqual(restored.state.splitOrientation, .vertical)
        XCTAssertEqual(restored.state.splitFraction, 0.7, accuracy: 0.001)
    }

    func testViewportRestoresSelectionAndScrollAfterNativeLayout() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        let h = Harness(String(repeating: "a long line for restoring position\n", count: 300))
        h.editor.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        controller.view.addSubview(h.editor)
        h.editor.layoutIfNeeded()
        h.editor.setSelection(NSRange(location: 500, length: 4))
        h.editor.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        let viewport = EditorViewport(state: h.tab.state)
        h.editor.setSelection(NSRange(location: 0, length: 0))
        h.editor.contentOffset = .zero
        h.editor.restoreOnLayout = viewport
        h.editor.setNeedsLayout()
        h.editor.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.editor.selectedRange, NSRange(location: 500, length: 4))
        XCTAssertEqual(h.editor.contentOffset.y, 300, accuracy: 1)
    }

    private func temporaryFile(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("test.txt")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return url
    }

    func testExternalChangeRefreshesCleanBuffer() async throws {
        let url = try temporaryFile("old")
        let tab = TabModel()
        try await tab.document.loadAsync(from: url)
        DocumentWorkflow.applyLoadedDocument(tab.document, at: url, to: tab.state)
        try Data("new".utf8).write(to: url, options: .atomic)
        await DocumentWorkflow.refreshExternalSource(tab, at: url)
        XCTAssertEqual(tab.document.text, "new")
        XCTAssertFalse(tab.document.isDirty)
        XCTAssertNil(tab.document.externalChangeMessage)
    }

    func testExternalChangePreservesDirtyBufferAndReportsConflict() async throws {
        let url = try temporaryFile("old")
        let tab = TabModel()
        try await tab.document.loadAsync(from: url)
        DocumentWorkflow.applyLoadedDocument(tab.document, at: url, to: tab.state)
        tab.document.text = "my edits"
        tab.document.isDirty = true
        try Data("external edits".utf8).write(to: url, options: .atomic)
        await DocumentWorkflow.refreshExternalSource(tab, at: url)
        XCTAssertEqual(tab.document.text, "my edits")
        XCTAssertEqual(tab.document.originalData, Data("old".utf8))
        XCTAssertNotNil(tab.document.externalChangeMessage)
    }

    func testMissingSourcePreservesBufferAndReportsFailure() async throws {
        let url = try temporaryFile("keep this")
        let tab = TabModel()
        try await tab.document.loadAsync(from: url)
        DocumentWorkflow.applyLoadedDocument(tab.document, at: url, to: tab.state)
        try FileManager.default.removeItem(at: url)
        await DocumentWorkflow.refreshExternalSource(tab, at: url)
        XCTAssertEqual(tab.document.text, "keep this")
        XCTAssertNotNil(tab.document.externalChangeMessage)
    }

    func testPresenterObservesCoordinatedExternalWrites() async throws {
        let url = try temporaryFile("old")
        let observation = SourceFileObservation(url: url)
        defer { observation.stop() }
        let ready = expectation(description: "initial observation")
        let changed = expectation(description: "external write notification")
        let listener = Task {
            var initial = true
            for await _ in observation.events {
                if initial {
                    initial = false
                    ready.fulfill()
                } else {
                    changed.fulfill()
                    break
                }
            }
        }
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        try await CoordinatedFileAccess.perform(at: url, writing: true) { destination in
            try Data("new".utf8).write(to: destination, options: .atomic)
        }
        await fulfillment(of: [changed], timeout: 5)
    }

    func testCoordinatedRenameNotifiesPresenterAndPreservesBytes() async throws {
        let url = try temporaryFile("bytes 😀")
        let moved = url.deletingLastPathComponent().appendingPathComponent("renamed.txt")
        let observation = SourceFileObservation(url: url)
        defer { observation.stop() }
        let notified = expectation(description: "presenter receives new URL")
        let listener = Task {
            for await event in observation.events where event == moved {
                notified.fulfill()
                break
            }
        }
        defer { listener.cancel() }
        let result = try await CoordinatedFileAccess.move(from: url, to: moved)
        XCTAssertEqual(result, moved)
        XCTAssertEqual(try Data(contentsOf: moved), Data("bytes 😀".utf8))
        await fulfillment(of: [notified], timeout: 5)
    }

    func testCoordinatedRenameDoesNotOverwriteExistingFile() async throws {
        let url = try temporaryFile("first")
        let other = url.deletingLastPathComponent().appendingPathComponent("other.txt")
        try Data("second".utf8).write(to: other)
        do {
            _ = try await CoordinatedFileAccess.move(from: url, to: other)
            XCTFail("Should reject existing destination")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("second".utf8))
    }

    func testShareFilePreservesExactTextAndSelectedEncoding() throws {
        let file = try DocumentShare.writeCopy(
            text: "unsaved 😀  ", filename: "Draft.txt", encoding: String.Encoding.utf8.rawValue, utf8BOM: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.lastPathComponent, "Draft.txt")
        XCTAssertEqual(try Data(contentsOf: file), Data([0xEF, 0xBB, 0xBF]) + Data("unsaved 😀  ".utf8))
        XCTAssertThrowsError(
            try DocumentShare.writeCopy(
                text: "😀", filename: "bad.txt", encoding: String.Encoding.ascii.rawValue, utf8BOM: false))
    }

    func testJavaScriptWorkerPreservesExpressionAndOutputVariableSemantics() async throws {
        let expression = try await JavaScriptWorker().evaluate(code: "input.toUpperCase()", input: "hello")
        XCTAssertEqual(expression, "HELLO")
        let variable = try await JavaScriptWorker().evaluate(code: "var output = text + '!'; 42", input: "hello")
        XCTAssertEqual(variable, "hello!")
    }

    func testJavaScriptWorkerTerminatesInfiniteLoopWhileMainActorRuns() async throws {
        let heartbeat = expectation(description: "main actor remains available")
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            heartbeat.fulfill()
        }
        defer { task.cancel() }
        do {
            _ = try await JavaScriptWorker().evaluate(code: "while (true) {}", input: "", timeout: 0.2)
            XCTFail("Loop must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("time limit"), error.localizedDescription) }
        await fulfillment(of: [heartbeat], timeout: 1)
        let fresh = try await JavaScriptWorker().evaluate(code: "input + ' ok'", input: "still")
        XCTAssertEqual(fresh, "still ok")
    }

    func testJavaScriptTransformPreservesDocumentLineEndingConvention() async throws {
        let h = Harness("old")
        h.tab.state.lineEnding = .crlf
        let slot = JSTransformSlot(id: 1, name: "Newlines", code: "'one\\ntwo'", scope: .document)
        JSTransformRunner.run(slot)
        let job = try XCTUnwrap(h.tab.state.transformTask)
        await job.value
        XCTAssertEqual(h.editor.text, "one\r\ntwo")
        XCTAssertNil(h.tab.state.operationError)
        h.editor.undoManager?.undo()
        XCTAssertEqual(h.editor.text, "old")
    }

    func testJavaScriptWorkerCancellation() async throws {
        let job = Task { try await JavaScriptWorker().evaluate(code: "while (true) {}", input: "") }
        try await Task.sleep(for: .milliseconds(200))
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor
private final class BasicCommandContext: CommandContext {
    var find = FindState()
    var scenes = SceneRouter()
    var pickers = PickerIntents()
    var presentation = PresentationState()
}
