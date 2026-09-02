import Foundation
import UIKit

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
    /// `requestOpenWindow` call lets either path pass the scene's
    /// onAppear restore guard.
    static func presentMultiFileSearch() {
        Self.context.scenes.requestOpenWindow(.multiFileSearch)
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

    /// Ignores cursor position; equivalent to wrap-around without
    /// the "did it wrap?" ambiguity.
    static func findFirst() {
        guard let textView = actions else { return }
        let ctx = Self.context.find.context
        guard !ctx.query.isEmpty else { return }
        let length = (textView.text as NSString).length
        if let match = try? matchInDocument(context: ctx, forward: true, startingAt: 0, totalLength: length) {
            textView.setSelection(match.range)
            textView.scrollSelectionToVisible()
            recordPositionIfJumped()
        }
    }

    /// Replaces every match within the current selection only.
    static func replaceAllInSelection() {
        replaceAll(inRange: actions?.selectedRange)
    }

    /// Replaces every match from the cursor to the end of the document.
    static func replaceToEnd() {
        guard let textView = actions else { return }
        let cursor = textView.selectedRange.location
        let length = (textView.text as NSString).length
        guard cursor < length else { return }
        replaceAll(inRange: NSRange(location: cursor, length: length - cursor))
    }

    /// Shared by Replace All in Selection / Replace to End so both
    /// reach the same regex / case / undo handling.
    private static func replaceAll(inRange range: NSRange?) {
        guard let textView = actions, let range, range.length > 0 else { return }
        guard let original = textView.text(in: range) else { return }
        let ctx = Self.context.find.context
        guard !ctx.query.isEmpty else { return }
        do {
            let newText: String
            if FindCompile.useRegex(for: ctx) {
                let re = try FindCompile.regex(for: ctx)
                newText = re.stringByReplacingMatches(
                    in: original,
                    options: [],
                    range: NSRange(location: 0, length: (original as NSString).length),
                    withTemplate: ctx.replacement
                )
            } else {
                newText = original.replacingOccurrences(
                    of: ctx.query,
                    with: ctx.replacement,
                    options: ctx.caseSensitive ? [] : [.caseInsensitive]
                )
            }
            textView.replace(range, withText: newText)
            commitTextChange()
        } catch {
            // Invalid regex — silently no-op; sheet surfaces user errors.
        }
    }

    static func jumpToSelection() { actions?.scrollSelectionToVisible() }

    // MARK: - Find iteration

    static func stepToMatch(forward: Bool) {
        guard let textView = actions else { return }
        let ctx = Self.context.find.context
        guard !ctx.query.isEmpty else { return }
        let cursor = forward
            ? NSMaxRange(textView.selectedRange)
            : textView.selectedRange.location
        do {
            let length = (textView.text as NSString).length
            if let match = try matchInDocument(context: ctx, forward: forward, startingAt: cursor, totalLength: length) {
                textView.setSelection(match.range)
                textView.scrollSelectionToVisible()
                recordPositionIfJumped()
            } else if let wrap = try matchInDocument(
                context: ctx,
                forward: forward,
                startingAt: forward ? 0 : length,
                totalLength: length
            ) {
                textView.setSelection(wrap.range)
                textView.scrollSelectionToVisible()
                recordPositionIfJumped()
            }
        } catch {
            // Invalid regex etc. — surfaced by the sheet UI; nothing to do here.
        }
    }

    /// Compile the persistent context's pattern + find the first match at
    /// or after `cursor`. Returns nil if no match in the search range.
    static func matchInDocument(
        context: FindContext,
        forward: Bool,
        startingAt cursor: Int,
        totalLength: Int
    ) throws -> QueryReplaceMatch? {
        return try Self.nextQueryReplaceMatch(
            query: FindCompile.effectivePattern(for: context),
            replacement: context.replacement,
            useRegex: FindCompile.useRegex(for: context),
            caseSensitive: context.caseSensitive,
            startingAt: forward ? cursor : 0,
            searchUpTo: forward ? totalLength : cursor,
            preferLast: !forward
        )
    }
}
