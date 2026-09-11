import SwiftUI
import UIKit
import struct EditorEngine.BatchReplaceSet
import AVFoundation
import FileEncoding
import LineEnding
import LineSort

@MainActor
enum CommandActions {

    static func presentSheet(_ sheet: EditorSheet) {
        Self.context.presentation.present(sheet, owner: Self.context.scenes.currentEditor)
    }

    static func newWindow() {
        Self.context.scenes.openWindow?(.editor)
    }

    static func newTab() {
        Self.context.scenes.currentSession?.newTab()
    }

    /// Creates a blank document first, then asks for a template. Canceling
    /// leaves that blank document, regardless of the New Tab preference.
    static func newFromTemplate() {
        guard let session = Self.context.scenes.currentSession else { return }
        let tab = session.newTab(kind: .editor)
        Self.context.scenes.claimFocus(session: session)
        Self.context.presentation.present(.templatePicker, owner: tab.state)
    }

    static func openFile() {
        Self.context.pickers.pending = .open
    }

    static func saveFile() {
        guard let session = Self.context.scenes.currentSession else { return }
        let tab = session.activeTab
        Task { @MainActor in await saveDocumentSafely(tab) }
    }

    static func saveFileAs() {
        Self.context.pickers.pending = .saveAs
    }

    static func revertToSaved() {
        Self.context.presentation.revertRequestCount += 1
    }

    static func presentPreferences() {
        if DeviceIdiom.isPhone {
            Self.context.presentation.present(.preferences, owner: Self.context.scenes.currentEditor)
        } else {
            Self.context.scenes.openWindow?(.preferences)
        }
    }

    static func presentCommandPalette() {
        Self.context.presentation.present(.commandPalette, owner: Self.context.scenes.currentEditor)
    }

    static func presentFileBrowser() {
        presentFileBrowser(forceDestination: DocumentDestination.current())
    }

    static func presentFileBrowser(forceDestination destination: DocumentDestination) {
        switch destination {
        case .window:
            Self.context.scenes.openWindow?(.fileBrowser)
        case .tab:
            Self.context.presentation.present(.fileBrowser, owner: Self.context.scenes.currentEditor)
        }
    }

    /// Picker callbacks pass their captured session/destination. Immediate
    /// menu actions may use the currently focused session.
    static func routeOpenURL(_ url: URL, in owner: EditorSession? = nil,
                             destination: DocumentDestination = DocumentDestination.current(), line: Int? = nil) {
        if destination == .tab, let session = owner ?? Self.context.scenes.currentSession {
            let tab = session.newTab(kind: .editor)
            DocumentWorkflow.open(url, in: tab, goToLine: line)
        } else if let open = Self.context.scenes.openEditorWindow {
            open(.openDocument(url, line: line))
        } else {
            Self.context.presentation.openErrorMessage = "A new editor window isn't available yet. Try opening the file again."
        }
    }

    /// Inline browser tab — UIDocumentBrowserViewController hosted
    /// inside the tab. The pick handler flips kind back to `.editor`
    /// and loads the URL into the same tab.
    static func presentFileBrowserInNewTab() {
        guard let session = Self.session else {
            presentFileBrowser(forceDestination: .tab)
            return
        }
        session.newFileBrowserTab()
    }

    static func presentFileBrowserInNewWindow() {
        presentFileBrowser(forceDestination: .window)
    }

    // MARK: - Undo / Redo

    /// The app-owned text view is a responder and supplies its undo manager.
    static func copySelection() {
        guard let editor = actions, editor.selectedRange.length > 0,
              let text = editor.text(in: editor.selectedRange) else { return }
        UIPasteboard.general.string = text
        ClipboardHistory.shared.capture()
    }

    static func cutSelection() {
        guard let editor = actions, editor.selectedRange.length > 0 else { return }
        copySelection()
        editor.replaceText(in: EditorEngine.BatchReplaceSet(replacements: [.init(range: editor.selectedRange, text: "")]))
    }

    static func paste() {
        guard let editor = actions, let text = UIPasteboard.general.string else { return }
        editor.undoManager?.endUndoGrouping()
        editor.replace(editor.selectedRange, withText: text)
        editor.undoManager?.endUndoGrouping()
    }

    static func undo() {
        actions?.undoManager?.undo()
    }

    static func redo() {
        actions?.undoManager?.redo()
    }

    // MARK: - Tabs

    /// Per-window flag — used to live on the shared PresentationState,
    /// which made every open scene flip in lockstep. Targets the
    /// focused session so multi-window only flips the window the user
    /// interacted with (or, for menu-bar invocations, the frontmost).
    static func showTabSwitcher() {
        guard let session = Self.context.scenes.currentSession else { return }
        if !session.tabSwitcherActive {
            let tab = session.activeTab
            tab.state.textView?.resignFirstResponder()
            tab.secondaryState?.textView?.resignFirstResponder()
        }
        withAnimation(.appSwitcherMorph) {
            session.tabSwitcherActive.toggle()
        }
    }

    static func openCurrentDocumentInNewWindow() {
        guard let url = Self.context.scenes.currentEditor?.fileURL else { return }
        Self.context.scenes.openEditorWindow?(.openDocument(url))
    }

    // MARK: - Sidebar / inspector / split

    static func toggleSidebar() { showOutline() }

    static func showOutline() {
        guard let state = Self.state else { return }
        withAnimation(.appSnappyPanel) {
            state.sidebarOpen.toggle()
        }
    }

    static func toggleInspector() {
        Self.state?.inspectorOpen.toggle()
    }

    /// Cycles off → horizontal → vertical → off. Resets to 50/50
    /// on each change so a width↔height flip can't leave a sliver.
    static func cycleSplitView() {
        guard let state = Self.state else { return }
        withAnimation(.appSnappyPanel) {
            switch (state.splitOpen, state.splitOrientation) {
            case (false, _):
                state.splitOpen = true
                state.splitOrientation = .horizontal
            case (true, .horizontal):
                state.splitOrientation = .vertical
            case (true, .vertical):
                state.splitOpen = false
            }
            state.splitFraction = 0.5
        }
    }

    static func currentSplitState() -> (open: Bool, orientation: SplitOrientation)? {
        guard let state = Self.state else { return nil }
        return (state.splitOpen, state.splitOrientation)
    }

    // MARK: - View setting toggles

    private static func togglePref(_ keyPath: ReferenceWritableKeyPath<AppPreferencesStore, Bool>) {
        AppPreferencesStore.shared[keyPath: keyPath].toggle()
    }

    static func toggleShowLineNumbers()         { togglePref(\.showLineNumbers) }
    static func toggleWrapLines()               { togglePref(\.wrapLines) }
    static func toggleShowInvisibles()          { togglePref(\.showInvisibles) }
    static func toggleShowPageGuide()           { togglePref(\.showPageGuide) }
    static func toggleShowStatusBar()           { togglePref(\.showStatusBar) }
    static func toggleShowToolbar()             { togglePref(\.showToolbar) }
    static func toggleLiveMatchHighlight()      { togglePref(\.liveMatchHighlight) }
    static func toggleHighlightCurrentLine()    { togglePref(\.highlightCurrentLine) }
    static func toggleHighlightMatchingBrackets() { togglePref(\.highlightMatchingBrackets) }
    static func toggleShowChangeHistoryGutter() { togglePref(\.showChangeHistoryGutter) }

    // MARK: - Selection / line ops

    static func selectCurrentWord()       { actions?.selectCurrentWord() }
    static func selectCurrentLine()       { actions?.selectCurrentLine() }
    static func indentSelection()         { actions?.shiftSelectionRight() }
    static func outdentSelection()        { actions?.shiftSelectionLeft() }
    static func moveLineUp()              { actions?.moveSelectedLinesUp() }
    static func moveLineDown()            { actions?.moveSelectedLinesDown() }

    static func duplicateLine() {
        actions?.duplicateCurrentLine()
        commitTextChange()
    }

    static func deleteLine() {
        actions?.deleteCurrentLines()
        commitTextChange()
    }

    // MARK: - Inserts

    static func insertLoremIpsum(paragraphs: Int) {
        let nl = state?.lineEnding.string ?? "\n"
        insertAtSelection(Transformations.lipsum(paragraphs: paragraphs, separator: nl + nl))
    }

    static func insertPageBreak() {
        insertAtSelection("\u{000C}")
    }

    // MARK: - Sheet triggers

    static func presentPrefixSuffixLines() { presentSheet(.prefixSuffixLines) }
    static func presentInsertLoremIpsum() { presentSheet(.insertLoremIpsum) }
    static func presentInsertFileContents() { Self.context.pickers.pending = .insertFile }
    static func presentInsertFolderListing() { Self.context.pickers.pending = .insertFolder }

    // MARK: - Navigation / text transforms

    static func centerLine() {
        guard let textView = actions, let state = state else { return }
        let (line, _) = TextMetrics.lineColumn(for: textView.selectedRange.location, in: textView.text as NSString)
        state.textView?.goToLine(line)
    }

    static func applyPrefixSuffix(prefix: String, suffix: String) {
        transformSelection { text in
            var out = text
            if !prefix.isEmpty { out = Transformations.prefixLines(out, with: prefix) }
            if !suffix.isEmpty { out = Transformations.suffixLines(out, with: suffix) }
            return out
        }
    }

    static func surroundSelection(prefix: String, suffix: String) {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            textView.replace(range, withText: prefix + suffix)
            let cursor = range.location + (prefix as NSString).length
            textView.setSelection(NSRange(location: cursor, length: 0))
        } else {
            guard let selected = textView.text(in: range) else { return }
            let wrapped = prefix + selected + suffix
            textView.replace(range, withText: wrapped)
            let newLoc = range.location + (prefix as NSString).length
            textView.setSelection(NSRange(location: newLoc, length: range.length))
        }
        commitTextChange()
    }

    // MARK: - Speech

    static func speakSelection() {
        guard let textView = actions else { return }
        if Self.speechSynth.isSpeaking {
            Self.speechSynth.stopSpeaking(at: .immediate)
            return
        }
        let range = textView.selectedRange
        let body = range.length > 0
            ? (textView.text(in: range) ?? "")
            : textView.text
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: body)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        Self.speechSynth.speak(utterance)
    }

    static func stopSpeaking() {
        Self.speechSynth.stopSpeaking(at: .immediate)
    }

    private static let speechSynth = AVSpeechSynthesizer()

    // MARK: - Snippets / clipboard history

    static func insertSnippet(slotID: Int) {
        guard let slot = SnippetsStore.shared.slot(id: slotID),
              slot.isConfigured else { return }
        insertAtSelection(slot.content)
    }

    static func saveSelectionAsSnippet() {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        guard range.length > 0, let body = textView.text(in: range) else { return }
        let name = "Snippet \(Self.snippetDateFormatter.string(from: Date()))"
        SnippetsStore.shared.saveToFirstEmpty(name: name, content: body)
    }

    /// Copies the live buffer from the frontmost tab. Reading the text view
    /// first avoids losing keystrokes that have not reached the document's
    /// debounced model snapshot yet.
    static func copyAll(to pasteboard: UIPasteboard = .general) {
        guard let tab = Self.session?.activeTab, tab.kind == .editor else { return }
        pasteboard.string = tab.state.textView?.text ?? tab.document.text
    }

    static func presentSnippetsManager()   { presentSheet(.snippetsManager) }
    static func presentClipboardHistory()  { presentSheet(.clipboardHistory) }
    static func presentProcessLines()      { presentSheet(.processLines) }
    static func presentCanonize()          { presentSheet(.canonize) }
    static func presentCharacterPanel()    { presentSheet(.characterPanel) }

    /// Writes straight into the text view at the cursor so the
    /// clipboard history doesn't churn its own changeCount.
    static func pasteString(_ s: String) {
        insertAtSelection(s)
    }

    static let snippetDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - Inserts

    static func insertDateTime() { insertAtSelection(dateTimeFormatter.string(from: Date())) }
    static func insertDate()     { insertAtSelection(dateFormatter.string(from: Date())) }
    static func insertTime()     { insertAtSelection(timeFormatter.string(from: Date())) }
    static func insertFilePath() { if let url = state?.fileURL { insertAtSelection(url.path) } }
    static func insertFilename() { if let url = state?.fileURL { insertAtSelection(url.lastPathComponent) } }
    static func insertTab()      { insertAtSelection("\t") }
    static func insertNewline()  { insertAtSelection(state?.lineEnding.string ?? "\n") }

    // MARK: - Document settings

    /// Rewrites every break in the buffer to match. Use
    /// `setLineEnding(_:)` to change the preference without
    /// rewriting existing content.
    static func applyLineEnding(_ lineEnding: LineEnding) {
        guard let state = state, let actions = actions else { return }
        state.lineEnding = lineEnding
        let converted = actions.text.replacingLineEndings(with: lineEnding)
        replaceWholeText(with: converted)
        actions.applyLineEndingRawValue(lineEnding.rawValue)
        state.setText?(converted)
    }

    static func setEncoding(_ encoding: FileEncoding)    { state?.fileEncoding = encoding }
    static func setLineEnding(_ lineEnding: LineEnding)  { state?.lineEnding = lineEnding }
    static func reinterpretWithEncoding(_ encoding: FileEncoding) {
        state?.reinterpretWithEncoding?(encoding)
    }
    static func setLanguage(_ identifier: LanguageIdentifier) {
        state?.languageIdentifier = identifier
    }
    static func setIndentUsesTabs(_ value: Bool) { state?.usesTabs = value }
    static func setIndentWidth(_ width: Int)     { state?.indentWidth = width }

    // MARK: - Font size

    private static let fontSizeStops: [Double] = [
        9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 28, 32, 36, 42, 48, 56, 64, 72, 96
    ]

    static func increaseFontSize() {
        guard let state = state else { return }
        let current = state.fontSize
        if let next = fontSizeStops.first(where: { $0 > current }) {
            applyFontSize(next, to: state)
        }
    }

    static func decreaseFontSize() {
        guard let state = state else { return }
        let current = state.fontSize
        if let prev = fontSizeStops.reversed().first(where: { $0 < current }) {
            applyFontSize(prev, to: state)
        }
    }

    static func resetFontSize() {
        guard let state = state else { return }
        applyFontSize(AppPreferencesStore.shared.fontSize > 0 ? AppPreferencesStore.shared.fontSize : 14, to: state)
    }

    /// Writes through the EditorState setter so an active per-window
    /// font-size override moves; otherwise the global pref moves.
    private static func applyFontSize(_ value: Double, to state: EditorState) {
        state.fontSize = value
    }

    // MARK: - Cursor / character ops

    static func smartMoveToLineStart() {
        actions?.smartMoveToLineStart()
    }
    static func transposeCharacters() {
        actions?.transposeCharacters()
        commitTextChange()
    }
    static func deleteToEndOfLine() {
        actions?.deleteToEndOfLine()
        commitTextChange()
    }
    static func deleteWordBackward() {
        actions?.deleteWordBackward()
        commitTextChange()
    }
    static func deleteWordForward() {
        actions?.deleteWordForward()
        commitTextChange()
    }
    static func joinLines() {
        actions?.joinLines()
        commitTextChange()
    }

    // MARK: - Brackets

    static func goToMatchingBracket() {
        actions?.goToMatchingBracket()
        recordPositionIfJumped()
    }

    // MARK: - Position history

    static func recordPositionIfJumped() {
        guard let textView = actions, let state = state else { return }
        state.positionHistory.record(textView.selectedRange.location)
    }

    static func positionBack() {
        guard let textView = actions, let state = state,
              let target = state.positionHistory.back() else { return }
        textView.setSelection(NSRange(location: target, length: 0))
        textView.scrollSelectionToVisible()
    }

    static func positionForward() {
        guard let textView = actions, let state = state,
              let target = state.positionHistory.forward() else { return }
        textView.setSelection(NSRange(location: target, length: 0))
        textView.scrollSelectionToVisible()
    }

    // MARK: - Query Replace

    typealias QueryReplaceMatch = DocumentSearch.Match

    static func nextQueryReplaceMatch(
        query: String, replacement: String, useRegex: Bool, caseSensitive: Bool,
        startingAt cursor: Int, searchUpTo upperBound: Int? = nil, preferLast: Bool = false
    ) throws -> QueryReplaceMatch? {
        guard let textView = actions else { return nil }
        let search = try DocumentSearch(text: textView.text, context: FindContext(
            query: query, replacement: replacement, useRegex: useRegex, caseSensitive: caseSensitive))
        let end = min(upperBound ?? (search.text as NSString).length, (search.text as NSString).length)
        guard cursor >= 0, cursor <= end else { return nil }
        let matches = search.matches(in: NSRange(location: cursor, length: end - cursor))
        return preferLast ? matches.last : matches.first
    }

    static func revealMatch(_ match: QueryReplaceMatch) {
        actions?.setSelection(match.range)
        actions?.scrollSelectionToVisible()
    }

    // MARK: - Helpers

    /// Test seam: swap for a stub `CommandContext` to drive commands
    /// in isolation. Every helper below routes through `Self.context`.
    static var context: any CommandContext = AppStateBus.shared

    private static weak var invocationOwner: EditorState?

    static func perform(for editor: EditorState?, _ action: () -> Void) {
        let previous = invocationOwner
        invocationOwner = editor
        defer { invocationOwner = previous }
        if let editor { context.scenes.claimFocus(state: editor) }
        action()
    }

    static var state: EditorState? {
        if let invocationOwner { return invocationOwner }
        if context.presentation.presentedSheet != nil,
           let owner = context.presentation.presentedSheetOwner {
            return owner
        }
        return context.scenes.currentEditor
    }
    static var session: EditorSession? {
        if let owner = invocationOwner ?? context.presentation.presentedSheetOwner,
           let owningSession = context.scenes.allOpenSessions.first(where: { session in
               session.tabs.contains { $0.owns(owner) }
           }) {
            return owningSession
        }
        return context.scenes.currentSession
    }
    static var actions: PilcrowTextView? { state?.textView }

    static func commitTextChange() {
        if let textView = actions { state?.setText?(textView.text) }
    }

    static func transformSelection(_ transform: (String) -> String) {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            let newText = transform(textView.text)
            replaceWholeText(with: newText)
            state?.setText?(newText)
            return
        }
        guard let selected = textView.text(in: range) else { return }
        let replacement = transform(selected)
        textView.replace(range, withText: replacement)
        commitTextChange()
    }

    static func applyToWholeText(_ transform: (String) -> String) {
        guard let textView = actions else { return }
        let newText = transform(textView.text)
        replaceWholeText(with: newText)
        state?.setText?(newText)
    }

    /// Whole-document writes must go through `replace` — the engine's
    /// `text` setter wipes the undo stack.
    static func replaceWholeText(with newText: String) {
        guard let textView = actions else { return }
        let full = NSRange(location: 0, length: (textView.text as NSString).length)
        textView.replace(full, withText: newText)
    }

    static func insertAtSelection(_ string: String) {
        guard let textView = actions else { return }
        textView.replace(textView.selectedRange, withText: string)
        commitTextChange()
    }

    // DateFormatter construction is multi-ms on cold cache; cache.
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
