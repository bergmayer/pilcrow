import Foundation
import UIKit
import EditorEngine

@MainActor
extension CommandActions {

    // MARK: - Find

    /// Lighter than the full Find/Replace sheet — UIFindInteraction's
    /// incremental search with live match count. ⌥⌘F leaves ⌘F for
    /// the richer sheet.
    static func presentSystemFindBar() {
        actions?.presentFindNavigator()
    }

    /// `seedFindFromSelection` is split out so menu actions can seed
    /// before routing the sheet through `@FocusedValue`.
    static func presentFindAndReplace() {
        context.find.pendingShowReplace = true
        presentFindNavigator()
    }

    static func presentFindNavigator() {
        seedFindFromSelection()
        presentSheet(.findReplace)
    }

    /// No-op for empty / multi-line selections so a stray double-tap
    /// can't blow away the user's current search string.
    static func seedFindFromSelection() {
        guard let textView = actions,
              textView.selectedRange.length > 0,
              let selected = textView.text(in: textView.selectedRange),
              !selected.contains("\n")
        else { return }
        Self.context.find.context.query = selected
    }

    /// iPad: its own scene so it stays on-screen while the user
    /// clicks results. iPhone: a sheet on the active editor. The
    static func presentMultiFileSearch() {
        if DeviceIdiom.isPhone {
            Self.context.presentation.present(.multiFileSearch, owner: Self.context.scenes.currentEditor)
        } else {
            Self.context.scenes.openWindow?(.multiFileSearch)
        }
    }

    /// Uses the persistent search context — ⌘G keeps working after
    /// the sheet is dismissed.
    static func findNext() {
        stepToMatch(forward: true)
    }

    static func findPrevious() {
        stepToMatch(forward: false)
    }

    static func findNextOccurrenceOfSelection() {
        actions?.findNextOccurrenceOfSelection()
        recordPositionIfJumped()
    }
    static func findPreviousOccurrenceOfSelection() {
        actions?.findPreviousOccurrenceOfSelection()
        recordPositionIfJumped()
    }

    static func findFirst() {
        do {
            guard let textView = actions,
                  let match = try documentSearch(in: textView).matches.first else { return }
            revealMatch(match)
            recordPositionIfJumped()
        } catch { context.presentation.openErrorMessage = error.localizedDescription }
    }

    static func replaceAllInSelection() {
        guard let range = actions?.selectedRange, range.length > 0 else { return }
        replaceMatchesReportingErrors(in: range)
    }

    static func replaceToEnd() {
        guard let textView = actions else { return }
        let cursor = textView.selectedRange.location
        replaceMatchesReportingErrors(in: NSRange(location: cursor, length: (textView.text as NSString).length - cursor))
    }

    private static func replaceMatchesReportingErrors(in range: NSRange) {
        do { _ = try replaceAllMatches(in: range) }
        catch { context.presentation.openErrorMessage = error.localizedDescription }
    }

    static func documentSearch(in textView: PilcrowTextView) throws -> DocumentSearch {
        var find = context.find.context
        find.replacement = find.replacement.replacingLineEndings(with: state?.lineEnding ?? .lf)
        return try DocumentSearch(text: textView.text, context: find)
    }

    @discardableResult
    static func replaceAllMatches(in range: NSRange? = nil) throws -> Int {
        guard let textView = actions else { return 0 }
        let search = try documentSearch(in: textView)
        let matches = range.map { search.matches(in: $0) } ?? search.matches
        textView.replaceText(in: BatchReplaceSet(replacements: matches.map {
            .init(range: $0.range, text: $0.replacement)
        }))
        commitTextChange()
        return matches.count
    }

    /// Validate the selection against the complete document, including context
    /// outside it. An arbitrary selection is never a replacement target.
    @discardableResult
    static func replaceSelectedMatch() throws -> Bool {
        guard let textView = actions else { return false }
        let search = try documentSearch(in: textView)
        guard let match = search.matches.first(where: { $0.range == textView.selectedRange }) else { return false }
        textView.replaceText(in: BatchReplaceSet(replacements: [.init(range: match.range, text: match.replacement)]))
        textView.setSelection(NSRange(location: match.range.location + (match.replacement as NSString).length, length: 0))
        commitTextChange()
        return true
    }

    static func jumpToSelection() { actions?.scrollSelectionToVisible() }

    static func stepToMatch(forward: Bool) {
        do { _ = try selectSearchMatch(forward: forward) }
        catch { context.presentation.openErrorMessage = error.localizedDescription }
    }

    /// Remember zero-width selection per editor so the first Find can land on
    /// the caret, while subsequent Find commands advance instead of stalling.
    static func selectSearchMatch(forward: Bool) throws -> String {
        guard let textView = actions else { return "No editor." }
        let search = try documentSearch(in: textView)
        let selection = textView.selectedRange
        let last = state?.lastFindSelection
        let isCurrent = selection.length > 0 || (last?.text == search.text
            && last?.context == search.context && last?.range == selection)
        guard let match = search.next(from: selection, forward: forward, excludingCurrent: isCurrent) else {
            return "No other matches."
        }
        revealMatch(match)
        state?.lastFindSelection = (search.text, search.context, match.range)
        recordPositionIfJumped()
        let index = search.matches.firstIndex(of: match) ?? 0
        return "Match \(index + 1) of \(search.matches.count)."
    }
}
