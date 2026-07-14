import SwiftUI
import AVFoundation
import FileEncoding
import LineEnding
import LineSort

@MainActor
enum CommandActions {

    static func presentSheet(_ sheet: EditorSheet) {
        Self.context.presentation.presentedSheet = sheet
    }

    static func newWindow() {
        Self.context.scenes.openWindow?(.editor)
    }

    static func newTab() {
        Self.context.scenes.currentSession?.newTab()
    }

    static func openFile() {
        Self.context.pickers.pending = .open
    }

    static func saveFile() {
        guard let session = Self.context.scenes.currentSession else { return }
        saveDocumentSafely(session.activeTab, session: session)
    }

    static func saveFileAs() {
        Self.context.pickers.pending = .saveAs
    }

    static func revertToSaved() {
        Self.context.presentation.revertRequestCount += 1
    }

    static func presentPreferences() {
        if DeviceIdiom.isPhone {
            Self.context.presentation.presentedSheet = .preferences
        } else {
            Self.context.scenes.openWindow?(.preferences)
        }
    }

    static func presentCommandPalette() {
        Self.context.presentation.presentedSheet = .commandPalette
    }

    /// Window destination: one fresh browser scene per pick. Tab
    /// destination: sheet on the active editor — picks add tabs to
    /// the same session.
    static func presentFileBrowser() {
        switch DocumentDestination.current() {
        case .window:
            Self.context.scenes.requestOpenWindow(.fileBrowser)
            Self.context.scenes.openWindow?(.fileBrowser)
        case .tab:
            Self.context.presentation.presentedSheet = .fileBrowser
        }
    }

    /// Replaces the old `SceneRouter.routeOpenURL` closure. Caller is
    /// any URL-producing surface (FileBrowser, DocumentPicker) that
    /// has no scene of its own — resolves the active session here
    /// and dispatches per `DocumentDestination`.
    static func routeOpenURL(_ url: URL) {
        let destination = DocumentDestination.current()
        Self.context.pending.nextOpenDestinationOverride = nil
        switch destination {
        case .window:
            Self.context.pending.newWindow = url
            Self.context.scenes.openWindow?(.editor)
        case .tab:
            guard let session = Self.context.scenes.currentSession else {
                Self.context.pending.newWindow = url
                Self.context.scenes.openWindow?(.editor)
                return
            }
            let tab = session.newTab(kind: .editor)
            DocumentWorkflow.open(url, in: tab)
        }
    }

    /// One-shot destination override for "Open in New Tab…" /
    /// "Open in New Window…". Cleared by `EditorScene.route(open:)`
    /// once the picked URL lands.
    static func presentFileBrowser(forceDestination destination: DocumentDestination) {
        Self.context.pending.nextOpenDestinationOverride = destination
        presentFileBrowser()
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

    /// `EditorActions` doesn't surface `undoManager`, but the sole
    /// conformer is a UITextView subclass, so a UIResponder cast is
    /// safe.
    static func undo() {
        (actions as? UIResponder)?.undoManager?.undo()
    }

    static func redo() {
        (actions as? UIResponder)?.undoManager?.redo()
    }

    // MARK: - Tabs

    /// Per-window flag — used to live on the shared PresentationState,
    /// which made every open scene flip in lockstep. Targets the
    /// focused session so multi-window only flips the window the user
    /// interacted with (or, for menu-bar invocations, the frontmost).
    static func showTabSwitcher() {
        guard let session = Self.context.scenes.currentSession else { return }
        withAnimation(.appSwitcherMorph) {
            session.tabSwitcherActive.toggle()
        }
    }

    static func openCurrentDocumentInNewWindow() {
        guard let url = Self.context.scenes.currentEditor?.fileURL else { return }
        Self.context.pending.newWindow = url
        Self.context.scenes.openWindow?(.editor)
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

    static func presentSnippetsManager()   { presentSheet(.snippetsManager) }
    static func presentClipboardHistory()  { presentSheet(.clipboardHistory) }
    static func presentDraftsRecovery()    { presentSheet(.draftsRecovery) }
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

    struct QueryReplaceMatch {
        let range: NSRange
        let replacement: String
    }

    /// `preferLast` lets the sheet drive reverse-direction matching
    /// off the same forward primitives — it scans the full range and
    /// returns the last hit instead of the first.
    static func nextQueryReplaceMatch(
        query: String,
        replacement: String,
        useRegex: Bool,
        caseSensitive: Bool,
        startingAt cursor: Int,
        searchUpTo upperBound: Int? = nil,
        preferLast: Bool = false
    ) throws -> QueryReplaceMatch? {
        guard let textView = actions, !query.isEmpty else { return nil }
        let nsText = textView.text as NSString
        let totalLength = nsText.length
        let cap = upperBound ?? totalLength
        guard cursor < cap else { return nil }
        let searchRange = NSRange(location: cursor, length: cap - cursor)

        if useRegex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: query, options: options)
            } catch {
                throw LineMatchError.invalidRegex(query)
            }
            if preferLast {
                let matches = regex.matches(in: textView.text, range: searchRange)
                guard let last = matches.last else { return nil }
                let replaced = regex.replacementString(for: last, in: textView.text, offset: 0, template: replacement)
                return QueryReplaceMatch(range: last.range, replacement: replaced)
            }
            guard let match = regex.firstMatch(in: textView.text, range: searchRange) else { return nil }
            let replaced = regex.replacementString(for: match, in: textView.text, offset: 0, template: replacement)
            return QueryReplaceMatch(range: match.range, replacement: replaced)
        } else {
            var opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            if preferLast { opts.insert(.backwards) }
            let range = nsText.range(of: query, options: opts, range: searchRange)
            guard range.location != NSNotFound else { return nil }
            return QueryReplaceMatch(range: range, replacement: replacement)
        }
    }

    static func applyQueryReplaceMatch(_ match: QueryReplaceMatch) {
        guard let textView = actions else { return }
        textView.replace(match.range, withText: match.replacement)
        commitTextChange()
    }

    static func revealMatch(_ match: QueryReplaceMatch) {
        guard let textView = actions else { return }
        textView.setSelection(match.range)
        textView.scrollSelectionToVisible()
    }

    // MARK: - Helpers

    /// Test seam: swap for a stub `CommandContext` to drive commands
    /// in isolation. Every helper below routes through `Self.context`.
    static var context: any CommandContext = AppStateBus.shared

    static var state: EditorState?       { context.scenes.currentEditor }
    static var session: EditorSession?   { context.scenes.currentSession }
    static var actions: (any EditorActions)? { state?.textView }

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
