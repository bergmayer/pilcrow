import XCTest
import UIKit
import EditorEngine
import FileEncoding
import LineEnding
@testable import Pilcrow

final class PlainTextDocumentEncodeTests: XCTestCase {

    // MARK: - Encoding choice

    func test_encode_utf8_noBOM_unlessOptedIn() throws {
        let data = try PlainTextDocument.encode(
            text: "hello",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(Array(data), Array("hello".utf8))
    }

    func test_encode_utf8_addsBOMWhenPrefIsOn() throws {
        let data = try PlainTextDocument.encode(
            text: "hello",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: true
        )
        let prefix = Array(data.prefix(3))
        XCTAssertEqual(prefix, [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(Array(data.dropFirst(3)), Array("hello".utf8))
    }

    func test_encode_utf8_addsBOMWhenDocumentRemembersBOM() throws {
        // Per-document toggle — the document itself remembers it had a
        // BOM at load time, so it should write one back even when the
        // global pref is off.
        let encoding = FileEncoding(encoding: .utf8, withUTF8BOM: true)
        let data = try PlainTextDocument.encode(
            text: "hello",
            encoding: encoding,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func test_encode_utf16LE_writesByteOrderMarkAndPairs() throws {
        let data = try PlainTextDocument.encode(
            text: "Aé",
            encoding: FileEncoding(encoding: .utf16LittleEndian, withUTF8BOM: false),
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        let decoded = String(data: data, encoding: .utf16LittleEndian)
        XCTAssertEqual(decoded, "Aé")
    }

    func test_encode_isoLatin1_handlesAccentedCharacters() throws {
        let data = try PlainTextDocument.encode(
            text: "café",
            encoding: FileEncoding(encoding: .isoLatin1, withUTF8BOM: false),
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        let decoded = String(data: data, encoding: .isoLatin1)
        XCTAssertEqual(decoded, "café")
    }

    func test_encode_throwsWhenEncodingCannotRepresentCharacter() {
        // ISO Latin 1 can't encode '日' — expect lossy failure to throw.
        XCTAssertThrowsError(
            try PlainTextDocument.encode(
                text: "日本語",
                encoding: FileEncoding(encoding: .isoLatin1, withUTF8BOM: false),
                lineEnding: .lf,
                trimTrailingWhitespace: false,
                ensureTrailingNewline: false,
                saveUTF8BOMPref: false
            )
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, CocoaError.fileWriteInapplicableStringEncoding)
        }
    }

    // MARK: - Line endings

    func test_encode_normalizesMixedToLF() throws {
        let data = try PlainTextDocument.encode(
            text: "a\r\nb\rc\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\nb\nc\n")
    }

    func test_encode_normalizesToCRLF() throws {
        let data = try PlainTextDocument.encode(
            text: "a\nb\rc\r\nd",
            encoding: .utf8,
            lineEnding: .crlf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\r\nb\r\nc\r\nd")
    }

    func test_encode_normalizesToCR() throws {
        let data = try PlainTextDocument.encode(
            text: "a\nb\r\nc",
            encoding: .utf8,
            lineEnding: .cr,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\rb\rc")
    }

    // MARK: - Trim trailing whitespace

    func test_encode_trimsTrailingWhitespacePerLineWhenEnabled() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha   \nbeta\t\ngamma\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: true,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\nbeta\ngamma\n")
    }

    func test_encode_doesNotTrimWhenDisabled() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha   \nbeta\t\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha   \nbeta\t\n")
    }

    // MARK: - Ensure trailing newline

    func test_encode_ensuresTrailingNewlineWhenEnabled() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\n")
    }

    func test_encode_ensureNewline_isNoOpWhenAlreadyPresent() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\n")
    }

    func test_encode_ensureNewline_addsCRLFWhenLineEndingIsCRLF() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha",
            encoding: .utf8,
            lineEnding: .crlf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\r\n")
    }

    // MARK: - Decode (Unicode BOMs)

    func test_decode_utf16LEWithBOM_roundTrips() throws {
        // UTF-16 data is full of NUL high bytes — the BOM must route it
        // past the binary-file heuristic into encoding detection.
        let text = "héllo wörld"
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        let payload = try PlainTextDocument.decodePayload(from: data)
        XCTAssertEqual(payload.text, text)
    }

    func test_decode_utf16BEWithBOM_roundTrips() throws {
        let text = "héllo wörld"
        var data = Data([0xFE, 0xFF])
        data.append(try XCTUnwrap(text.data(using: .utf16BigEndian)))
        let payload = try PlainTextDocument.decodePayload(from: data)
        XCTAssertEqual(payload.text, text)
    }

    func test_decode_nulBytesWithoutBOM_throwsBinaryFile() {
        let data = Data([0x68, 0x69, 0x00, 0x68, 0x69])
        XCTAssertThrowsError(try PlainTextDocument.decodePayload(from: data)) { error in
            guard case PlainTextDocument.DocumentError.binaryFile = error else {
                return XCTFail("Expected .binaryFile, got \(error)")
            }
        }
    }

    // MARK: - Composite

    func test_encode_allOptions_chainCorrectly() throws {
        let input = "alpha   \r\nbeta\t\r\ngamma"
        let data = try PlainTextDocument.encode(
            text: input,
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: true,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        // Trim first → "alpha\r\nbeta\r\ngamma", then normalize CRLF→LF
        // → "alpha\nbeta\ngamma", then ensure trailing → "alpha\nbeta\ngamma\n".
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\nbeta\ngamma\n")
    }

    // MARK: - Multi-file replacement encoding and targeting

    func test_multiFileReplacement_refusesLossyLegacyEncoding() throws {
        let original = try XCTUnwrap("café".data(using: .isoLatin1))
        let encoded = MultiFileSearchSheet.encodeReplacement(
            "café 😀",
            encoding: .isoLatin1,
            originalData: original
        )
        XCTAssertNil(encoded)
    }

    func test_multiFileReplacement_preservesUTF16BigEndianBOM() throws {
        var original = Data([0xFE, 0xFF])
        original.append(try XCTUnwrap("cat".data(using: .utf16BigEndian)))
        let encoded = try XCTUnwrap(MultiFileSearchSheet.encodeReplacement(
            "dog",
            encoding: .utf16,
            originalData: original
        ))
        XCTAssertTrue(encoded.starts(with: [0xFE, 0xFF]))
        XCTAssertEqual(
            String(data: encoded.dropFirst(2), encoding: .utf16BigEndian),
            "dog"
        )
    }

    func test_multiFileQueryReplacement_targetsChosenLiteralMatch() throws {
        var context = FindContext()
        context.query = "cat"
        let result = try MultiFileSearchSheet.replaceInString(
            "cat cat",
            query: "cat",
            replacement: "dog",
            context: context,
            limitToFirst: false,
            targetRanges: [NSRange(location: 4, length: 3)]
        )
        XCTAssertEqual(result.0, "cat dog")
        XCTAssertEqual(result.1, 1)
    }

    func test_multiFileQueryReplacement_targetsChosenRegexMatchWithCapture() throws {
        var context = FindContext()
        context.query = #"a(\d)"#
        context.useRegex = true
        let result = try MultiFileSearchSheet.replaceInString(
            "a1 a2",
            query: context.query,
            replacement: "b$1",
            context: context,
            limitToFirst: false,
            targetRanges: [NSRange(location: 3, length: 2)]
        )
        XCTAssertEqual(result.0, "a1 b2")
        XCTAssertEqual(result.1, 1)
    }

    func test_multiFileReplacement_replacesAllCaseInsensitiveLiterals() throws {
        var context = FindContext()
        context.query = "cat"
        let result = try MultiFileSearchSheet.replaceInString(
            "Cat cat",
            query: context.query,
            replacement: "dog",
            context: context,
            limitToFirst: false
        )
        XCTAssertEqual(result.0, "dog dog")
        XCTAssertEqual(result.1, 2)
    }

    func test_multiFileReplacement_limitsRegexToFirstMatch() throws {
        var context = FindContext()
        context.query = #"a(\d)"#
        context.useRegex = true
        let result = try MultiFileSearchSheet.replaceInString(
            "a1 a2",
            query: context.query,
            replacement: "b$1",
            context: context,
            limitToFirst: true
        )
        XCTAssertEqual(result.0, "b1 a2")
        XCTAssertEqual(result.1, 1)
    }
}

@MainActor
final class EditorSafetyRegressionTests: XCTestCase {

    @MainActor
    private final class Harness {
        let document: PlainTextDocument
        let state: EditorState
        let editor: PilcrowTextView
        let coordinator: EditorTextViewCoordinator

        init(text: String) {
            document = PlainTextDocument()
            document.text = text
            document.isDirty = false
            state = EditorState()
            state.text = text
            editor = PilcrowTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            coordinator = EditorTextViewCoordinator(document: document, state: state)
            editor.editorDelegate = coordinator
            editor.text = text
            state.textView = editor
        }
    }

    private func makeEditor(text: String) -> Harness {
        Harness(text: text)
    }

    func test_widthChangeRetypesetsEveryCharacterInsideNewWrapWidth() throws {
        let source = String(repeating: "wrapped text must remain visible ", count: 30)
        let editor = makeEditor(text: source).editor
        editor.isLineWrappingEnabled = true
        editor.layoutIfNeeded()

        var inset = editor.textContainerInset
        inset.right = 400
        editor.textContainerInset = inset
        editor.layoutIfNeeded()

        let length = (source as NSString).length
        var greatestY: CGFloat = 0
        for offset in stride(from: 0, through: length, by: 7) {
            let position = try XCTUnwrap(editor.position(from: editor.beginningOfDocument, offset: offset))
            let caret = editor.caretRect(for: position)
            XCTAssertLessThanOrEqual(caret.maxX, 205, "Character \(offset) remained in a clipped wide fragment")
            greatestY = max(greatestY, caret.minY)
        }
        XCTAssertGreaterThan(greatestY, 0, "The narrowed editor should produce multiple visual lines")
    }

    func test_viewportResizeRetypesetsInsteadOfClippingOldFragments() throws {
        let source = String(repeating: "resizing must preserve every wrapped segment ", count: 24)
        let editor = makeEditor(text: source).editor
        editor.isLineWrappingEnabled = true
        editor.layoutIfNeeded()

        editor.frame.size.width = 220
        editor.setNeedsLayout()
        editor.layoutIfNeeded()

        let length = (source as NSString).length
        var greatestY: CGFloat = 0
        for offset in stride(from: 0, through: length, by: 7) {
            let position = try XCTUnwrap(editor.position(from: editor.beginningOfDocument, offset: offset))
            let caret = editor.caretRect(for: position)
            XCTAssertLessThanOrEqual(caret.maxX, 225, "Character \(offset) kept a fragment from the old viewport")
            greatestY = max(greatestY, caret.minY)
        }
        XCTAssertGreaterThan(greatestY, 0, "The resized editor should produce multiple visual lines")
    }

    func test_indentAndUndoBothMarkCleanDocumentDirty() {
        let harness = makeEditor(text: "one\ntwo")
        let (document, editor) = (harness.document, harness.editor)
        editor.selectedRange = NSRange(location: 0, length: 3)
        editor.shiftRight()
        XCTAssertTrue(document.isDirty)

        document.isDirty = false // Simulate a successful save checkpoint.
        let revisionBeforeUndo = document.bufferRevision
        editor.undoManager?.undo()
        XCTAssertTrue(document.isDirty)
        XCTAssertGreaterThan(document.bufferRevision, revisionBeforeUndo)
    }

    func test_moveLinesAndBatchReplaceMarkCleanDocumentDirty() {
        let harness = makeEditor(text: "one\ntwo\n")
        let (document, editor) = (harness.document, harness.editor)
        editor.selectedRange = NSRange(location: 0, length: 3)
        editor.moveSelectedLinesDown()
        XCTAssertTrue(document.isDirty)

        document.isDirty = false
        editor.replaceText(in: BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "ONE")
        ]))
        XCTAssertTrue(document.isDirty)
    }

    func test_accessibilityForwardsToEditableTextInput() {
        let editor = makeEditor(text: "editable").editor
        XCTAssertFalse(editor.accessibilityTraits.contains(.staticText))
        XCTAssertNotNil(editor.accessibilityTextInputResponder)
        XCTAssertTrue(editor.accessibilityTextInputResponder?.hasText == true)
        XCTAssertEqual(editor.accessibilityValue, "editable")
    }

    func test_ignoredSpellingWordsAreIsolatedPerDocument() {
        let first = PilcrowTextView()
        let second = PilcrowTextView()

        first.ignoreWord("Pilcrow")

        XCTAssertTrue(first.ignoredSpellingWords.contains("Pilcrow"))
        XCTAssertFalse(second.ignoredSpellingWords.contains("Pilcrow"))
    }

    func test_failedReinterpretLeavesTextAndEncodingUnchanged() {
        let document = PlainTextDocument()
        document.text = "original"
        document.fileEncoding = .utf8
        document.originalData = Data([0xFF])

        XCTAssertThrowsError(
            try document.reinterpretOriginalData(
                as: FileEncoding(encoding: .ascii)
            )
        )
        XCTAssertEqual(document.text, "original")
        XCTAssertEqual(document.fileEncoding, .utf8)
    }

    func test_presentedSheetKeepsOwningEditorWhenFocusChanges() {
        let context = TestCommandContext()
        let owner = EditorState()
        let other = EditorState()
        context.scenes.currentEditor = other
        context.presentation.present(.findReplace, owner: owner)
        CommandActions.context = context
        defer { CommandActions.context = AppStateBus.shared }

        XCTAssertTrue(CommandActions.state === owner)
        context.presentation.presentedSheet = nil
        XCTAssertTrue(CommandActions.state === other)
    }

    func test_copyAllCopiesFrontmostDocumentBuffer() {
        let context = TestCommandContext()
        let session = EditorSession()
        session.activeTab.kind = .editor
        session.activeTab.document.text = "entire document"
        context.scenes.registerSession(session)
        context.scenes.claimFocus(session: session)
        CommandActions.context = context
        let pasteboard = UIPasteboard.withUniqueName()
        defer {
            UIPasteboard.remove(withName: pasteboard.name)
            CommandActions.context = AppStateBus.shared
        }

        CommandActions.copyAll(to: pasteboard)

        XCTAssertEqual(pasteboard.string, "entire document")
    }

    func test_queryReplace_findsLastLiteralInRange() throws {
        let harness = makeEditor(text: "cat cat cat")
        let context = TestCommandContext()
        context.scenes.currentEditor = harness.state
        CommandActions.context = context
        defer { CommandActions.context = AppStateBus.shared }

        let match = try XCTUnwrap(CommandActions.nextQueryReplaceMatch(
            query: "cat",
            replacement: "dog",
            useRegex: false,
            caseSensitive: true,
            startingAt: 0,
            searchUpTo: 7,
            preferLast: true
        ))
        XCTAssertEqual(match.range, NSRange(location: 4, length: 3))
        XCTAssertEqual(match.replacement, "dog")
    }

    func test_queryReplace_evaluatesRegexCapture() throws {
        let harness = makeEditor(text: "a1 a2")
        let context = TestCommandContext()
        context.scenes.currentEditor = harness.state
        CommandActions.context = context
        defer { CommandActions.context = AppStateBus.shared }

        let match = try XCTUnwrap(CommandActions.nextQueryReplaceMatch(
            query: #"a(\d)"#,
            replacement: "b$1",
            useRegex: true,
            caseSensitive: true,
            startingAt: 0
        ))
        XCTAssertEqual(match.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(match.replacement, "b1")
    }

    func test_saveFormattingKeepsBufferAndDiskIdentical() async throws {
        let defaults = UserDefaults.standard
        let trimKey = AppPreferenceKey.trimTrailingWhitespaceOnSave
        let newlineKey = AppPreferenceKey.ensureTrailingNewline
        let oldTrim = defaults.object(forKey: trimKey)
        let oldNewline = defaults.object(forKey: newlineKey)
        defer {
            if let oldTrim { defaults.set(oldTrim, forKey: trimKey) } else { defaults.removeObject(forKey: trimKey) }
            if let oldNewline { defaults.set(oldNewline, forKey: newlineKey) } else { defaults.removeObject(forKey: newlineKey) }
        }
        defaults.set(true, forKey: trimKey)
        defaults.set(true, forKey: newlineKey)

        let tab = TabModel()
        let document = tab.document
        document.text = "first   \r\nsecond\t"
        document.lineEnding = .lf
        document.fileEncoding = .utf8
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilcrow-save-fidelity-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try await DocumentWorkflow.save(tab, to: url)
        let diskText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(document.text, diskText)
        XCTAssertEqual(diskText, "first\nsecond\n")
        XCTAssertFalse(document.isDirty)
    }

    func test_revertToSavedDeletesDiscardedRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilcrow-revert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.txt")
        let draft = root.appendingPathComponent("draft.txt")
        try Data("saved".utf8).write(to: source)
        try Data("discarded edits".utf8).write(to: draft)

        let tab = TabModel()
        tab.document.text = "discarded edits"
        tab.document.fileURL = source
        tab.document.draftURL = draft
        tab.document.isDirty = true

        let result = await withCheckedContinuation { continuation in
            DocumentWorkflow.revert(source, in: tab) {
                continuation.resume(returning: $0)
            }
        }
        try result.get()

        XCTAssertEqual(tab.document.text, "saved")
        XCTAssertFalse(tab.document.isDirty)
        XCTAssertNil(tab.document.draftURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.path))
    }
}

@MainActor
private final class TestCommandContext: CommandContext {
    var find = FindState()
    var scenes = SceneRouter()
    var pickers = PickerIntents()
    var presentation = PresentationState()
}
