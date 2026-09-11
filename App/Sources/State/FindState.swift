import Foundation

/// Retains the current search so ⌘G / ⌘⇧G keep working after the
/// sheet is dismissed.
@MainActor
@Observable
final class FindState {
    var context = FindContext()

    /// One-shot toggles cleared by `FindReplaceSheet.onAppear` after
    /// reading. Let menu items request the sheet with Replace
    /// expanded or in step-through mode.
    var pendingShowReplace = false
    var pendingQueryMode = false
}

struct FindContext: Equatable, Sendable {
    var query: String = ""
    var replacement: String = ""
    var useRegex: Bool = false
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
}

/// Shared regex/literal compilation for any find call site
/// (CommandActions+Find for single-document, MultiFileSearchSheet for
/// cross-file). Centralizes `wholeWord` wrapping and case-insensitive
/// option handling so the two paths can't drift apart on bug fixes.
enum FindCompile {

    /// `true` when the context needs an NSRegularExpression
    /// (explicit regex OR whole-word, since whole-word relies on
    /// `\b` boundaries).
    static func useRegex(for ctx: FindContext) -> Bool {
        ctx.useRegex || ctx.wholeWord
    }

    /// The pattern after `wholeWord` wrapping. For non-regex queries
    /// the inner is escaped first so user-typed `.` / `+` don't get
    /// interpreted as metacharacters when wrapped with `\b…\b`.
    static func effectivePattern(for ctx: FindContext) -> String {
        guard ctx.wholeWord else { return ctx.query }
        let inner =
            ctx.useRegex
            ? ctx.query
            : NSRegularExpression.escapedPattern(for: ctx.query)
        // Group before wrapping: bare \b…\b binds per-alternative, so
        // `cat|dog` would become `\bcat|dog\b`.
        return #"\b(?:"# + inner + #")\b"#
    }

    /// Throws when the user's regex doesn't compile. Callers should
    /// gate on `useRegex(for:)` first; this asserts that.
    static func regex(for ctx: FindContext) throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if !ctx.caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: effectivePattern(for: ctx), options: options)
    }
}

/// All ranges refer to one complete buffer. Matching before editing preserves
/// anchors, lookarounds, capture groups, and zero-width matches during replacement.
struct DocumentSearch {
    struct Match: Equatable {
        let range: NSRange
        let replacement: String
    }

    let text: String
    let context: FindContext
    let matches: [Match]

    init(text: String, context: FindContext) throws {
        self.text = text
        self.context = context
        guard !context.query.isEmpty else {
            matches = []
            return
        }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        if FindCompile.useRegex(for: context) {
            let regex = try FindCompile.regex(for: context)
            matches = regex.matches(in: text, range: fullRange).map { result in
                Match(
                    range: result.range,
                    replacement: context.useRegex
                        ? regex.replacementString(for: result, in: text, offset: 0, template: context.replacement)
                        : context.replacement)
            }
        } else {
            var found: [Match] = []
            var cursor = 0
            while cursor < source.length {
                let range = source.range(
                    of: context.query,
                    options: context.caseSensitive ? [] : [.caseInsensitive],
                    range: NSRange(location: cursor, length: source.length - cursor))
                guard range.location != NSNotFound, range.length > 0 else { break }
                found.append(Match(range: range, replacement: context.replacement))
                cursor = NSMaxRange(range)
            }
            matches = found
        }
    }

    func matches(in range: NSRange) -> [Match] {
        matches.filter { $0.range.location >= range.location && NSMaxRange($0.range) <= NSMaxRange(range) }
    }

    func next(from selection: NSRange, forward: Bool, excludingCurrent: Bool) -> Match? {
        let eligible = matches.filter { !excludingCurrent || $0.range != selection }
        if forward {
            return eligible.first { $0.range.location >= NSMaxRange(selection) } ?? eligible.first
        }
        return eligible.last { NSMaxRange($0.range) <= selection.location } ?? eligible.last
    }
}

/// A query-replace walk visits the original matches exactly once. Edits shift
/// later ranges; inserted text is never searched again. The expected buffer
/// prevents an outstanding confirmation from replacing text that has changed.
struct QueryReplacementSession {
    private let remaining: [DocumentSearch.Match]
    private var index = 0
    private(set) var expectedText: String
    private var offset = 0

    init(search: DocumentSearch, startingAt cursor: Int) {
        remaining = search.matches.filter { $0.range.location >= cursor }
        expectedText = search.text
    }

    var current: DocumentSearch.Match? {
        guard index < remaining.count else { return nil }
        let match = remaining[index]
        return DocumentSearch.Match(
            range: NSRange(location: match.range.location + offset, length: match.range.length),
            replacement: match.replacement)
    }

    mutating func skip() { index = min(index + 1, remaining.count) }

    mutating func acceptReplacement(actualText: String) {
        offset += (actualText as NSString).length - (expectedText as NSString).length
        expectedText = actualText
        skip()
    }
}
