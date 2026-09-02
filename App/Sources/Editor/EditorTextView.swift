import SwiftUI
import UIKit
import EditorEngine
import PilcrowSyntax

/// The engine's `TextView` is the buffer's source of truth. The
/// coordinator bumps `document.bufferRevision` per keystroke;
/// status bar / preview read a debounced snapshot. Earlier
/// designs piped full text through `Binding<String>` and froze
/// editing on multi-MB files.
struct EditorTextView: UIViewRepresentable {

    let document: PlainTextDocument
    let state: EditorState
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedStyle: UIUserInterfaceStyle {
        colorScheme == .dark ? .dark : .light
    }

    func makeUIView(context: Context) -> PilcrowTextView {
        let textView = PilcrowTextView()
        textView.editorDelegate = context.coordinator
        let initialThemeKey = EditorTextViewCoordinator.ThemeCacheKey(
            name: state.themeName,
            font: state.font,
            fontSize: currentFontSize(),
            style: resolvedStyle == .dark ? .dark : .light
        )
        let initialTheme = AppTheme.current(
            initialThemeKey.name,
            font: initialThemeKey.font,
            fontSize: initialThemeKey.fontSize,
            userInterfaceStyle: initialThemeKey.style
        )
        textView.theme = initialTheme
        // EditorEngine.TextView hardcodes white as scroll-view
        // background; DarkTheme (white text) needs an explicit fix.
        textView.backgroundColor = (initialTheme as? EditorBackgroundProviding)?
            .editorBackgroundColor ?? .systemBackground
        context.coordinator.themeCacheKey = initialThemeKey
        textView.text = document.text
        context.coordinator.lastPushedDocumentText = document.text
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .always
        KeyboardAccessoryBar.install(on: textView)
        textView.onFoldToggle = { [weak textView] body in
            guard let textView else { return }
            let isFolded = body.contains { textView.foldedLineIndices.contains($0) }
            textView.setLinesFolded(!isFolded, range: body)
        }
        // No-op on large files; decorator walks every line per
        // render. Weak capture avoids a state→textView→closure cycle.
        MarkdownInlineHighlighter.install(on: textView) { [weak state] in
            guard let state, !state.isLargeFile else { return .plain }
            return state.languageIdentifier
        }

        applyTypingPreferences(to: textView)
        applyViewSettings(to: textView)
        applyOverscroll(to: textView)
        applyLanguage(to: textView, identifier: state.languageIdentifier, coordinator: context.coordinator)
        applyIndentStrategy(to: textView)
        applyCharacterPairs(to: textView)

        // Subviews of the engine's scroll view so they scroll with
        // content. Each rebuilds in its own `layoutSubviews`; the
        // coordinator pushes fresh data through `updateUIView`.
        let bookmarks = BookmarkGutterOverlay(host: textView)
        textView.addSubview(bookmarks)
        context.coordinator.bookmarkOverlay = bookmarks

        let matchMarks = MatchScrollMarksOverlay(host: textView)
        textView.addSubview(matchMarks)
        context.coordinator.matchScrollOverlay = matchMarks

        let history = ChangeHistoryGutterOverlay(host: textView)
        textView.addSubview(history)
        context.coordinator.changeHistoryOverlay = history

        // Fold-selection markers synthesize a `FoldableRegion` per
        // `userFoldedBodyRanges` entry so the engine paints its own
        // gutter chevron (sibling overlays got buried under
        // `bringSubviewToFront(gutterContainerView)`).

        state.textView = textView
        applyFocusRequestIfNeeded(to: textView, context: context)
        return textView
    }

    func updateUIView(_ textView: PilcrowTextView, context: Context) {
        synchronizeDocumentText(with: textView, coordinator: context.coordinator)
        applyTypingPreferences(to: textView)
        applyViewSettings(to: textView)
        applyOverscroll(to: textView)
        synchronizeTheme(with: textView, coordinator: context.coordinator)
        applyIndentStrategy(to: textView)
        applyCharacterPairs(to: textView)
        synchronizeLanguage(with: textView, coordinator: context.coordinator)
        context.coordinator.refreshFoldableRegions(textView)
        applyFocusRequestIfNeeded(to: textView, context: context)
        context.coordinator.bookmarkOverlay?.bookmarks = state.bookmarks
        refreshChangeHistoryOverlay(for: textView, coordinator: context.coordinator)
    }

    /// Only pushes external document writes (load, Revert, restore, or a
    /// Save-As re-decode). The cache avoids an O(n) compare on every render.
    private func synchronizeDocumentText(
        with textView: PilcrowTextView,
        coordinator: EditorTextViewCoordinator
    ) {
        guard coordinator.lastPushedDocumentText != document.text else { return }
        coordinator.lastPushedDocumentText = document.text
        if textView.text != document.text {
            textView.text = document.text
        }
    }

    private func synchronizeTheme(
        with textView: PilcrowTextView,
        coordinator: EditorTextViewCoordinator
    ) {
        let themeKey = EditorTextViewCoordinator.ThemeCacheKey(
            name: state.themeName,
            font: state.font,
            fontSize: currentFontSize(),
            style: resolvedStyle == .dark ? .dark : .light
        )
        guard coordinator.themeCacheKey != themeKey else { return }
        let resolved = AppTheme.current(
            themeKey.name,
            font: themeKey.font,
            fontSize: themeKey.fontSize,
            userInterfaceStyle: themeKey.style
        )
        textView.theme = resolved
        textView.backgroundColor = (resolved as? EditorBackgroundProviding)?
            .editorBackgroundColor ?? .systemBackground
        coordinator.themeCacheKey = themeKey
    }

    private func synchronizeLanguage(
        with textView: PilcrowTextView,
        coordinator: EditorTextViewCoordinator
    ) {
        guard coordinator.currentLanguageIdentifier != state.languageIdentifier else { return }
        applyLanguage(
            to: textView,
            identifier: state.languageIdentifier,
            coordinator: coordinator
        )
    }

    private func refreshChangeHistoryOverlay(
        for textView: PilcrowTextView,
        coordinator: EditorTextViewCoordinator
    ) {
        guard let overlay = coordinator.changeHistoryOverlay else { return }
        guard let currentText = changeHistoryText(from: textView) else {
            clearChangeHistoryOverlay(overlay, coordinator: coordinator)
            return
        }

        let baselineText = state.savedBaselineText
        guard coordinator.changeHistoryBaselineCache != baselineText
                || coordinator.changeHistoryCurrentCache != currentText
        else { return }

        coordinator.overlayRefreshTask?.cancel()
        coordinator.overlayRefreshTask = Task { @MainActor [weak coordinator, weak overlay] in
            try? await Task.sleep(for: Timing.changeHistoryOverlayDebounce)
            if Task.isCancelled { return }
            guard let coordinator, let overlay else { return }
            if coordinator.changeHistoryBaselineCache != baselineText {
                coordinator.changeHistoryBaselineCache = baselineText
                overlay.baseline = baselineText.components(separatedBy: "\n")
            }
            if coordinator.changeHistoryCurrentCache != currentText {
                coordinator.changeHistoryCurrentCache = currentText
                overlay.current = currentText.components(separatedBy: "\n")
            }
        }
    }

    private func changeHistoryText(from textView: PilcrowTextView) -> String? {
        // Gutter gated on pref + byte ceiling
        // (`changeHistoryGutterByteLimit` — per-line diff +
        // caretRect lookups slow past 100KB) + cache short-circuit.
        // Pref / large-file checks run BEFORE touching `textView.text`
        // — the getter is an O(n) buffer copy per render.
        guard state.showChangeHistoryGutter, !state.isLargeFile else { return nil }
        let candidate = textView.text
        guard candidate.utf16.count <= Timing.changeHistoryGutterByteLimit else { return nil }
        return candidate
    }

    private func clearChangeHistoryOverlay(
        _ overlay: ChangeHistoryGutterOverlay,
        coordinator: EditorTextViewCoordinator
    ) {
        // Drop stale bars; resetting caches lets a re-enable render fresh.
        coordinator.overlayRefreshTask?.cancel()
        guard !overlay.baseline.isEmpty || !overlay.current.isEmpty else { return }
        overlay.baseline = []
        overlay.current = []
        coordinator.changeHistoryBaselineCache = nil
        coordinator.changeHistoryCurrentCache = nil
    }

    func makeCoordinator() -> EditorTextViewCoordinator {
        EditorTextViewCoordinator(document: document, state: state)
    }

    private func applyFocusRequestIfNeeded(to textView: PilcrowTextView, context: Context) {
        let requestID = state.editorFocusRequestID
        guard requestID != 0, context.coordinator.handledFocusRequestID != requestID else { return }
        context.coordinator.handledFocusRequestID = requestID
        DispatchQueue.main.async { [weak textView] in
            textView?.focusForEditing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak textView] in
                textView?.focusForEditing()
            }
        }
    }

    // MARK: - Settings

    private func applyTypingPreferences(to textView: PilcrowTextView) {
        textView.autocorrectionType = state.autoCorrect ? .yes : .no
        textView.autocapitalizationType = state.autoCapitalize ? .sentences : .none
        textView.smartQuotesType = state.smartQuotes ? .yes : .no
        textView.smartDashesType = state.smartQuotes ? .yes : .no
        textView.spellCheckingType = state.spellCheck ? .yes : .no
        // `autoLinkDetection` stored but not wired — engine doesn't
        // expose `dataDetectorTypes`.
        textView.keyboardType = .default
    }

    private func applyViewSettings(to textView: PilcrowTextView) {
        textView.showLineNumbers = state.showLineNumbers
        textView.isLineWrappingEnabled = state.wrapLines

        let inv = state.showInvisibles
        textView.showTabs              = inv && state.showInvisibleTab
        textView.showSpaces            = inv && state.showInvisibleSpace
        textView.showLineBreaks        = inv && state.showInvisibleNewline
        textView.showSoftLineBreaks    = inv && state.showInvisibleNewline
        textView.showNonBreakingSpaces = inv && state.showInvisibleNonBreakingSpace

        textView.showPageGuide   = state.showPageGuide
        textView.pageGuideColumn = state.pageGuideColumn

        textView.lineHeightMultiplier  = CGFloat(state.lineHeight)
        textView.lineSelectionDisplayType = state.highlightCurrentLine ? .line : .disabled
        textView.applyLineEndingRawValue(state.lineEnding.rawValue)

        // A page guide is a visual ruler, not a second wrapping width.
        // Wrapping remains tied to the viewport so resizing an iPad window
        // cannot leave stale, clipped line fragments behind.
        if textView.textContainerInset.right != 0 {
            var inset = textView.textContainerInset
            inset.right = 0
            textView.textContainerInset = inset
        }
    }

    /// Ten lines of `contentInset.bottom` cushion so the final
    /// line doesn't pin to the window edge.
    private func applyOverscroll(to textView: PilcrowTextView) {
        let font = state.font.uiFont(size: CGFloat(state.fontSize))
        let perLine = font.lineHeight * CGFloat(state.lineHeight)
        let target: CGFloat = state.overscroll ? perLine * 10 : 0
        if abs(textView.contentInset.bottom - target) > 0.5 {
            textView.contentInset.bottom = target
        }
    }

    private func applyIndentStrategy(to textView: PilcrowTextView) {
        textView.indentStrategy = state.usesTabs
            ? .tab(length: state.indentWidth)
            : .space(length: state.indentWidth)
    }

    private func applyCharacterPairs(to textView: PilcrowTextView) {
        textView.characterPairs = state.insertCharacterPairs ? Self.commonPairs : []
    }

    private func applyLanguage(
        to textView: PilcrowTextView,
        identifier: LanguageIdentifier,
        coordinator: EditorTextViewCoordinator
    ) {
        coordinator.currentLanguageIdentifier = identifier
        // Large files bypass tree-sitter; the initial parse is O(N).
        if state.isLargeFile {
            textView.setLanguageMode(PlainTextLanguageMode())
            return
        }
        if let language = SyntaxRegistry.language(for: identifier.rawValue) {
            textView.setLanguageMode(TreeSitterLanguageMode(language: language))
        } else {
            textView.setLanguageMode(PlainTextLanguageMode())
        }
    }

    private func currentFontSize() -> CGFloat {
        CGFloat(state.fontSize)
    }

    private static let commonPairs: [BasicCharacterPair] = [
        BasicCharacterPair(leading: "(", trailing: ")"),
        BasicCharacterPair(leading: "[", trailing: "]"),
        BasicCharacterPair(leading: "{", trailing: "}"),
        BasicCharacterPair(leading: "\"", trailing: "\""),
        BasicCharacterPair(leading: "'", trailing: "'"),
        BasicCharacterPair(leading: "`", trailing: "`")
    ]

}

private struct BasicCharacterPair: EditorEngine.CharacterPair {
    let leading: String
    let trailing: String
}

// MARK: - Editor commands

extension PilcrowTextView {

    func focusForEditing() {
        _ = becomeFirstResponder()
    }

    func presentFindNavigator() {
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func presentFindAndReplaceNavigator() {
        findInteraction?.presentFindNavigator(showingReplace: true)
    }

    func findNext() {
        findInteraction?.findNext()
    }

    func findPrevious() {
        findInteraction?.findPrevious()
    }

    func shiftSelectionLeft() {
        shiftLeft()
    }

    func shiftSelectionRight() {
        shiftRight()
    }

    func selectAll() {
        let length = (text as NSString).length
        selectedRange = NSRange(location: 0, length: length)
    }

    func selectCurrentWord() {
        let nsText = text as NSString
        let location = selectedRange.location
        let length = nsText.length
        guard length > 0 else { return }

        let alnum = CharacterSet.alphanumerics
        var start = min(location, length - 1)
        var end = start

        while start > 0,
              let scalar = nsText.substring(with: NSRange(location: start - 1, length: 1)).unicodeScalars.first,
              alnum.contains(scalar) || scalar == "_" {
            start -= 1
        }
        while end < length,
              let scalar = nsText.substring(with: NSRange(location: end, length: 1)).unicodeScalars.first,
              alnum.contains(scalar) || scalar == "_" {
            end += 1
        }
        if end > start {
            selectedRange = NSRange(location: start, length: end - start)
        }
    }

    func selectCurrentLine() {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selectedRange)
        selectedRange = lineRange
    }

    func setSelection(_ range: NSRange) {
        let length = (text as NSString).length
        let clamped = NSRange(
            location: max(0, min(range.location, length)),
            length: max(0, min(range.length, length - max(0, min(range.location, length))))
        )
        selectedRange = clamped
    }

    func useSelectionForFind() {
        guard selectedRange.length > 0 else { return }
        let nsText = text as NSString
        let selected = nsText.substring(with: selectedRange)
        findInteraction?.searchText = selected
    }

    func scrollSelectionToVisible() {
        scrollRangeToVisible(selectedRange)
    }

    func goToLine(_ line: Int) {
        _ = goToLine(line - 1, select: .beginning)
    }

    func duplicateCurrentLine() {
        let range = selectedRange
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: range)
        let lineContent = nsText.substring(with: lineRange)
        let endOfLines = lineRange.location + lineRange.length
        let needsLeadingNewline = (endOfLines == nsText.length) && !lineContent.hasSuffix("\n") && !lineContent.hasSuffix("\r")
        let insertion = needsLeadingNewline ? ("\n" + lineContent) : lineContent
        replace(NSRange(location: endOfLines, length: 0), withText: insertion)
    }

    func deleteCurrentLines() {
        let range = selectedRange
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: range)
        replace(lineRange, withText: "")
    }

    // MARK: - Selection of selection

    func findNextOccurrenceOfSelection() {
        findOccurrenceOfSelection(forward: true)
    }

    func findPreviousOccurrenceOfSelection() {
        findOccurrenceOfSelection(forward: false)
    }

    private func findOccurrenceOfSelection(forward: Bool) {
        guard selectedRange.length > 0 else { return }
        let nsText = text as NSString
        let needle = nsText.substring(with: selectedRange)
        guard !needle.isEmpty else { return }
        let length = nsText.length
        let searchRange: NSRange
        if forward {
            let start = NSMaxRange(selectedRange)
            searchRange = NSRange(location: start, length: max(0, length - start))
        } else {
            searchRange = NSRange(location: 0, length: selectedRange.location)
        }
        var found = nsText.range(of: needle, options: forward ? [] : .backwards, range: searchRange)
        if found.location == NSNotFound {
            // Wrap.
            found = nsText.range(of: needle, options: forward ? [] : .backwards)
        }
        guard found.location != NSNotFound else { return }
        selectedRange = found
        scrollRangeToVisible(found)
    }

    // MARK: - Smart Home

    func smartMoveToLineStart() {
        let nsText = text as NSString
        let cursor = selectedRange.location
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let lineStart = lineRange.location
        // Find first non-whitespace.
        var firstNonWS = lineStart
        let lineEnd = lineRange.location + lineRange.length
        while firstNonWS < lineEnd {
            let ch = nsText.character(at: firstNonWS)
            if ch != UInt16(0x20) && ch != UInt16(0x09) { break }
            firstNonWS += 1
        }
        // If we're at the first non-whitespace already, snap to column 0;
        // otherwise jump to the first non-whitespace.
        let target = (cursor == firstNonWS) ? lineStart : firstNonWS
        selectedRange = NSRange(location: target, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    // MARK: - Transpose, deletion

    func transposeCharacters() {
        let nsText = text as NSString
        let length = nsText.length
        var cursor = selectedRange.location
        guard length >= 2 else { return }
        if cursor == 0 { cursor = 1 }
        if cursor >= length { cursor = length - 1 }
        // Composed sequences, not single UTF-16 units — swapping raw
        // units splits surrogate pairs next to emoji.
        let leftRange = nsText.rangeOfComposedCharacterSequence(at: cursor - 1)
        let rightRange = nsText.rangeOfComposedCharacterSequence(at: cursor)
        // Cursor mid-sequence: both probes land in the same character.
        guard leftRange.location < rightRange.location else { return }
        let left = nsText.substring(with: leftRange)
        let right = nsText.substring(with: rightRange)
        let combined = NSRange(
            location: leftRange.location,
            length: NSMaxRange(rightRange) - leftRange.location
        )
        replace(combined, withText: right + left)
        selectedRange = NSRange(location: NSMaxRange(combined), length: 0)
    }

    func deleteToEndOfLine() {
        let nsText = text as NSString
        let cursor = selectedRange.location
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        var end = lineRange.location + lineRange.length
        // Keep the trailing newline (Mac convention). `lineRange`
        // already covers CRLF, so we step back over either byte.
        while end > cursor {
            let last = nsText.character(at: end - 1)
            guard last == 0x0A || last == 0x0D else { break }
            end -= 1
        }
        if end > cursor {
            replace(NSRange(location: cursor, length: end - cursor), withText: "")
        }
    }

    func deleteWordBackward() {
        let cursor = selectedRange.location
        guard cursor > 0 else { return }
        let nsText = text as NSString
        var idx = cursor
        // Skip whitespace immediately behind cursor.
        while idx > 0 && Self.isWhitespaceByte(nsText.character(at: idx - 1)) {
            idx -= 1
        }
        // Then consume the word characters.
        while idx > 0 && !Self.isWhitespaceByte(nsText.character(at: idx - 1)) {
            idx -= 1
        }
        let range = NSRange(location: idx, length: cursor - idx)
        if range.length > 0 { replace(range, withText: "") }
    }

    func deleteWordForward() {
        let cursor = selectedRange.location
        let nsText = text as NSString
        let length = nsText.length
        guard cursor < length else { return }
        var idx = cursor
        while idx < length && Self.isWhitespaceByte(nsText.character(at: idx)) {
            idx += 1
        }
        while idx < length && !Self.isWhitespaceByte(nsText.character(at: idx)) {
            idx += 1
        }
        let range = NSRange(location: cursor, length: idx - cursor)
        if range.length > 0 { replace(range, withText: "") }
    }

    private static func isWhitespaceByte(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    // MARK: - Join lines

    func joinLines() {
        let nsText = text as NSString
        let length = nsText.length
        let cursor = selectedRange.location
        // Find the end of the current line.
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let endOfLine = lineRange.location + lineRange.length
        guard endOfLine < length else { return }
        // Determine the line terminator length (1 for LF/CR, 2 for CRLF).
        let terminatorLen: Int
        let last = nsText.character(at: endOfLine - 1)
        if last == 0x0A,
           endOfLine - 2 >= 0,
           nsText.character(at: endOfLine - 2) == 0x0D {
            terminatorLen = 2
        } else if last == 0x0A || last == 0x0D {
            terminatorLen = 1
        } else {
            return
        }
        let terminatorStart = endOfLine - terminatorLen
        // Skip leading whitespace on the next line, then replace the
        // terminator (and that whitespace) with a single space.
        var trimmed = endOfLine
        while trimmed < length {
            let c = nsText.character(at: trimmed)
            if c == 0x20 || c == 0x09 { trimmed += 1 } else { break }
        }
        replace(NSRange(location: terminatorStart, length: trimmed - terminatorStart), withText: " ")
        selectedRange = NSRange(location: terminatorStart + 1, length: 0)
    }

    // MARK: - Spell check

    /// One instance per process; retains learned words for the app's
    /// lifetime.
    private static let textChecker = UITextChecker()

    /// Remembers ignored words so the highlighter doesn't immediately
    /// re-flag them — UITextChecker's ignoreWord is per-checker but
    /// doesn't filter the highlight pass.
    /// Follow the active keyboard when possible, then the user's preferred
    /// languages. UITextChecker uses underscore locale identifiers on some
    /// OS versions and hyphenated identifiers on others, so match both the
    /// full locale and its language prefix.
    private var spellCheckingLanguage: String {
        let available = UITextChecker.availableLanguages
        let candidates = [textInputMode?.primaryLanguage] + Locale.preferredLanguages.map(Optional.some)
        for candidate in candidates.compactMap({ $0 }) {
            let normalized = candidate.replacingOccurrences(of: "-", with: "_")
            if let exact = available.first(where: {
                $0.caseInsensitiveCompare(candidate) == .orderedSame
                    || $0.caseInsensitiveCompare(normalized) == .orderedSame
            }) {
                return exact
            }
            let language = normalized.split(separator: "_").first?.lowercased()
            if let language,
               let regional = available.first(where: {
                   $0.lowercased().split(separator: "_").first.map(String.init) == language
               }) {
                return regional
            }
        }
        return available.first ?? "en_US"
    }

    func jumpToNextMisspelling() {
        let nsText = text as NSString
        let start = selectedRange.location
        var range = Self.textChecker.rangeOfMisspelledWord(
            in: nsText as String,
            range: NSRange(location: 0, length: nsText.length),
            startingAt: start,
            wrap: true,
            language: spellCheckingLanguage
        )
        // Skip ranges whose word we've been told to ignore. With
        // wrap:true the checker cycles forever when every remaining
        // hit is ignored — bail once the first range comes around
        // again.
        var firstSeen: NSRange?
        while range.location != NSNotFound {
            if let firstSeen, NSEqualRanges(range, firstSeen) { return }
            if firstSeen == nil { firstSeen = range }
            let word = nsText.substring(with: range)
            if !ignoredSpellingWords.contains(word) {
                selectedRange = range
                scrollRangeToVisible(range)
                return
            }
            range = Self.textChecker.rangeOfMisspelledWord(
                in: nsText as String,
                range: NSRange(location: 0, length: nsText.length),
                startingAt: NSMaxRange(range),
                wrap: true,
                language: spellCheckingLanguage
            )
        }
    }

    func learnSelectedWord() {
        guard let word = wordAtSelection(), !word.isEmpty else { return }
        learnWord(word)
    }

    func ignoreSelectedWord() {
        guard let word = wordAtSelection(), !word.isEmpty else { return }
        ignoreWord(word)
    }

    func learnWord(_ word: String) {
        // `learnWord` is a static — it writes to the system-wide
        // learned-words dictionary. `ignoreWord` is an instance
        // method scoped per checker.
        UITextChecker.learnWord(word)
        ignoredSpellingWords.remove(word)
    }

    func ignoreWord(_ word: String) {
        Self.textChecker.ignoreWord(word)
        ignoredSpellingWords.insert(word)
    }

    /// Walk-through driver: skips over session-ignored words and
    /// returns the first flagged hit at or after `location`, wrapping
    /// once. `suggestions` is ranked best-first by UITextChecker.
    func nextMisspelling(from location: Int) -> (range: NSRange, word: String, suggestions: [String])? {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var range = Self.textChecker.rangeOfMisspelledWord(
            in: nsText as String,
            range: full,
            startingAt: max(0, min(location, nsText.length)),
            wrap: true,
            language: spellCheckingLanguage
        )
        // wrap:true cycles forever when every remaining hit is
        // ignored — bail once the first range comes around again.
        var firstSeen: NSRange?
        while range.location != NSNotFound {
            if let firstSeen, NSEqualRanges(range, firstSeen) { return nil }
            if firstSeen == nil { firstSeen = range }
            let word = nsText.substring(with: range)
            if !ignoredSpellingWords.contains(word) {
                let guesses = Self.textChecker.guesses(
                    forWordRange: range,
                    in: nsText as String,
                    language: spellCheckingLanguage
                ) ?? []
                return (range, word, guesses)
            }
            range = Self.textChecker.rangeOfMisspelledWord(
                in: nsText as String,
                range: full,
                startingAt: NSMaxRange(range),
                wrap: true,
                language: spellCheckingLanguage
            )
        }
        return nil
    }

    /// Namespace so we replace only misspelling marks, not live-match
    /// / bracket-match / find-bar highlights.
    private static let misspellingHighlightID = "pilcrow.misspelling-"

    func highlightAllMisspellings() {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var hits: [NSRange] = []
        var cursor = 0
        while cursor < nsText.length {
            let r = Self.textChecker.rangeOfMisspelledWord(
                in: nsText as String,
                range: full,
                startingAt: cursor,
                wrap: false,
                language: spellCheckingLanguage
            )
            guard r.location != NSNotFound else { break }
            // Skip words the user has flagged as ignored this session.
            let word = nsText.substring(with: r)
            if !ignoredSpellingWords.contains(word) {
                hits.append(r)
            }
            cursor = r.location + max(r.length, 1)
            // Safety cap so an unexpectedly large doc can't lock the
            // main thread on the menu action.
            if hits.count > 5_000 { break }
        }
        // Replace any previous misspelling marks; leave other
        // highlights (live match, bracket match, find) untouched.
        let surviving = highlightedRanges.filter { !$0.id.hasPrefix(Self.misspellingHighlightID) }
        let tint = UIColor.systemRed.withAlphaComponent(0.22)
        let fresh = hits.enumerated().map { idx, range in
            HighlightedRange(
                id: "\(Self.misspellingHighlightID)\(idx)",
                range: range,
                color: tint,
                cornerRadius: 2
            )
        }
        highlightedRanges = surviving + fresh
    }

    func clearMisspellingHighlights() {
        highlightedRanges = highlightedRanges.filter {
            !$0.id.hasPrefix(Self.misspellingHighlightID)
        }
    }

    /// Scans the current misspelling highlights and returns the one
    /// containing `location` — inclusive of the trailing edge so a
    /// cursor parked right after the last letter still counts as
    /// "inside the word".
    func misspellingRange(at location: Int) -> NSRange? {
        for hr in highlightedRanges where hr.id.hasPrefix(Self.misspellingHighlightID) {
            if NSLocationInRange(location, hr.range) || location == NSMaxRange(hr.range) {
                return hr.range
            }
        }
        return nil
    }

    /// Word at the cursor; nil if the cursor sits in whitespace.
    private func wordAtSelection() -> String? {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return nil }
        var start = min(selectedRange.location, length)
        var end = start
        let isWordChar: (unichar) -> Bool = { ch in
            // Surrogate halves aren't valid scalars (force-unwrap
            // trapped on emoji); treat them as non-word.
            guard let scalar = Unicode.Scalar(ch) else { return false }
            return CharacterSet.letters.contains(scalar) || (ch >= 0x30 && ch <= 0x39) || ch == 0x27
        }
        while start > 0 {
            let ch = nsText.character(at: start - 1)
            if !isWordChar(ch) { break }
            start -= 1
        }
        while end < length {
            let ch = nsText.character(at: end)
            if !isWordChar(ch) { break }
            end += 1
        }
        guard end > start else { return nil }
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - Bracket match

    private static let bracketHighlightID = "pilcrow.bracketMatch"

    func goToMatchingBracket() {
        guard let match = BracketMatcher.matchingLocation(in: text as NSString, cursor: selectedRange.location) else { return }
        selectedRange = NSRange(location: match, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    func clearBracketMatchHighlight() {
        highlightedRanges = highlightedRanges.filter {
            $0.id != Self.bracketHighlightID && $0.id != Self.bracketHighlightID + ".pair"
        }
    }

    func refreshBracketMatchHighlight() {
        let cursor = selectedRange.location
        // Strip any prior bracket highlight.
        var others = highlightedRanges.filter { $0.id != Self.bracketHighlightID && $0.id != Self.bracketHighlightID + ".pair" }
        defer { highlightedRanges = others }
        guard selectedRange.length == 0 else { return }
        // Peek one UTF-16 unit either side via the engine's ranged
        // read — this runs per caret move, and `text as NSString`
        // is an O(n) buffer copy. `text(in:)` is nil out of bounds.
        func unit(at index: Int) -> unichar? {
            guard index >= 0 else { return nil }
            return text(in: NSRange(location: index, length: 1))?.utf16.first
        }
        // Look at char before or at cursor.
        var bracketIndex: Int?
        if let ch = unit(at: cursor), BracketMatcher.isBracket(ch) {
            bracketIndex = cursor
        } else if let ch = unit(at: cursor - 1), BracketMatcher.isBracket(ch) {
            bracketIndex = cursor - 1
        }
        guard let bracket = bracketIndex else { return }
        // Adjacent to a bracket — only now pay for the full bridge
        // to walk for the mate.
        let nsText = text as NSString
        guard let mate = BracketMatcher.matchingLocation(in: nsText, atBracketAt: bracket) else {
            return
        }
        let color = UIColor.systemBlue.withAlphaComponent(0.25)
        others.append(HighlightedRange(id: Self.bracketHighlightID, range: NSRange(location: bracket, length: 1), color: color, cornerRadius: 2))
        others.append(HighlightedRange(id: Self.bracketHighlightID + ".pair", range: NSRange(location: mate, length: 1), color: color, cornerRadius: 2))
    }

    // MARK: - Folding (indent-based v1)

    func unfoldAll() {
        unfoldAllLines()
    }

    func applyFoldRanges(_ ranges: [ClosedRange<Int>]) {
        // Idempotent — unfold everything first so we don't get duplicates,
        // then fold the persisted ranges.
        unfoldAllLines()
        for range in ranges {
            setLinesFolded(true, range: range)
        }
    }

    func applyLineEndingRawValue(_ rawValue: Character) {
        let mapped: EditorEngine.LineEnding
        switch rawValue {
        case "\n":   mapped = .lf
        case "\r":   mapped = .cr
        case "\r\n": mapped = .crlf
        default:     mapped = .lf
        }
        self.lineEndings = mapped
    }
}
