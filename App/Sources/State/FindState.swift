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
    var pendingQueryMode   = false
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
        let inner = ctx.useRegex
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
