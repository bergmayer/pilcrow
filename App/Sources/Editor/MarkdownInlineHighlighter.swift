import Foundation
import UIKit
import EditorEngine

/// Adds line-scoped Markdown attributes after syntax highlighting.
@MainActor
enum MarkdownInlineHighlighter {

    static func install(
        on textView: EditorEngine.TextView,
        languageProvider: @escaping () -> LanguageIdentifier
    ) {
        textView.attributeDecorator = { [weak textView] attributed, _, lineLength in
            guard lineLength > 0,
                  languageProvider() == .markdown,
                  let theme = textView?.theme else { return }
            decorate(attributed, theme: theme)
        }
    }

    static func decorate(_ attributed: NSMutableAttributedString, theme: Theme) {
        guard attributed.string.rangeOfCharacter(from: Self.triggers) != nil else { return }
        let fullRange = NSRange(location: 0, length: (attributed.string as NSString).length)
        for rule in rules {
            rule.regex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
                guard let match else { return }
                let range = capturedRange(for: rule, in: match)
                guard range.location != NSNotFound else { return }
                applyAttributes(rule, theme: theme, in: range, on: attributed)
            }
        }
    }

    private static func capturedRange(for rule: Rule, in match: NSTextCheckingResult) -> NSRange {
        guard rule.captureGroup < match.numberOfRanges else {
            assertionFailure("Rule.captureGroup \(rule.captureGroup) out of range for pattern (\(match.numberOfRanges) groups)")
            return match.range
        }
        return match.range(at: rule.captureGroup)
    }

    private static func applyAttributes(_ rule: Rule, theme: Theme, in range: NSRange, on attributed: NSMutableAttributedString) {
        if let color = theme.textColor(for: rule.highlightName) {
            attributed.addAttribute(.foregroundColor, value: color, range: range)
        }
        let traits = symbolicTraits(for: theme.fontTraits(for: rule.highlightName))
        guard !traits.isEmpty else { return }
        attributed.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let baseFont = (value as? UIFont) ?? theme.font
            let combined = baseFont.fontDescriptor.symbolicTraits.union(traits)
            guard let descriptor = baseFont.fontDescriptor.withSymbolicTraits(combined) else { return }
            let newFont = UIFont(descriptor: descriptor, size: baseFont.pointSize)
            attributed.addAttribute(.font, value: newFont, range: subRange)
        }
    }

    private static func symbolicTraits(for fontTraits: FontTraits) -> UIFontDescriptor.SymbolicTraits {
        var out: UIFontDescriptor.SymbolicTraits = []
        if fontTraits.contains(.bold) { out.insert(.traitBold) }
        if fontTraits.contains(.italic) { out.insert(.traitItalic) }
        return out
    }

    private struct Rule {
        let regex: NSRegularExpression
        let captureGroup: Int
        let highlightName: String
    }

    private static func rule(_ pattern: String, group: Int = 0, name: String) -> Rule {
        do {
            return Rule(regex: try NSRegularExpression(pattern: pattern), captureGroup: group, highlightName: name)
        } catch {
            fatalError("Invalid MarkdownInlineHighlighter pattern \(pattern): \(error)")
        }
    }

    private static let triggers: CharacterSet = CharacterSet(charactersIn: "*_`#>[=-+~")

    // Earlier rules paint broad spans (headings paint the whole line),
    // later rules paint subsets (an *emphasis* inside a heading still
    // becomes italic). Block-level rules anchor on `^`.
    private static let rules: [Rule] = [
        // # Heading … ###### Heading
        rule(#"^[ \t]{0,3}#{1,6}[ \t].*$"#, name: "markup.heading"),
        // Setext underline
        rule(#"^[ \t]{0,3}={3,}[ \t]*$"#, name: "markup.heading"),
        rule(#"^[ \t]{0,3}-{3,}[ \t]*$"#, name: "markup.heading"),
        // Block quote
        rule(#"^[ \t]{0,3}>.*$"#, name: "markup.quote"),
        // List markers (- + * or 1.) — just the marker
        rule(#"^[ \t]*([-+*])[ \t]+"#,    group: 1, name: "markup.list"),
        rule(#"^[ \t]*(\d+[.)])[ \t]+"#,  group: 1, name: "markup.list"),
        // Fenced code block delimiter
        rule(#"^[ \t]{0,3}(`{3,}|~{3,}).*$"#, name: "punctuation.special"),
        // **strong** / __strong__
        rule(#"\*\*([^*\n]+?)\*\*"#, name: "markup.bold"),
        rule(#"__([^_\n]+?)__"#,     name: "markup.bold"),
        // *emphasis* / _emphasis_
        rule(#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, name: "markup.italic"),
        rule(#"(?<![_\w])_([^_\n]+?)_(?![_\w])"#, name: "markup.italic"),
        // `code`
        rule(#"`([^`\n]+?)`"#, name: "markup.raw"),
        // [label](url)
        rule(#"\[([^\]\n]+?)\]\(([^)\n]+?)\)"#, group: 1, name: "markup.link.label"),
        rule(#"\[([^\]\n]+?)\]\(([^)\n]+?)\)"#, group: 2, name: "markup.link.url")
    ]
}
