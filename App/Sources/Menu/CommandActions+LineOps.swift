import Foundation
import struct EditorEngine.BatchReplaceSet

extension CommandActions {

    // MARK: - Line operations

    static func sortLines()      { presentSheet(.sortLines) }

    static func reverseLines() {
        applyToWholeText { text in
            let separator = state?.lineEnding.string ?? "\n"
            return text.components(separatedBy: separator).reversed().joined(separator: separator)
        }
    }

    static func uniqueLines() {
        applyToWholeText { text in
            let separator = state?.lineEnding.string ?? "\n"
            var seen = Set<String>()
            var unique: [String] = []
            for line in text.components(separatedBy: separator) where seen.insert(line).inserted {
                unique.append(line)
            }
            return unique.joined(separator: separator)
        }
    }

    static func trimTrailingWhitespace() {
        applyToWholeText { text in
            let separator = state?.lineEnding.string ?? "\n"
            return text
                .components(separatedBy: separator)
                .map { line -> String in
                    var s = line
                    while let last = s.last, last == " " || last == "\t" { s.removeLast() }
                    return s
                }
                .joined(separator: separator)
        }
    }

    /// Collapses intra-paragraph breaks into spaces. Blank-line
    /// paragraph delimiters survive — unwraps hard-wrapped prose.
    static func removeLinebreaks() {
        transformSelection { text in
            let nl = state?.lineEnding.string ?? "\n"
            let paragraphs = Transformations.splitParagraphs(text)
            let joined = paragraphs.map { paragraph -> String in
                paragraph
                    .components(separatedBy: CharacterSet.newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            return joined.joined(separator: nl + nl)
        }
    }

    /// Greedy 72-column word wrap; whitespace is normalised to single
    /// spaces first.
    static func addLinebreaks() {
        transformSelection { text in
            let nl = state?.lineEnding.string ?? "\n"
            let paragraphs = Transformations.splitParagraphs(text)
            let wrapped = paragraphs.map { Transformations.wordWrap($0, to: 72, separator: nl) }
            return wrapped.joined(separator: nl + nl)
        }
    }

    static func educateQuotes()    { transformSelection(Transformations.educateQuotes) }
    static func straightenQuotes() { transformSelection(Transformations.straightenQuotes) }

    static func tabsToSpaces() {
        let width = max(1, state?.indentWidth ?? 4)
        transformSelection { Transformations.tabsToSpaces($0, tabWidth: width) }
    }

    static func spacesToTabs() {
        let width = max(1, state?.indentWidth ?? 4)
        transformSelection { Transformations.spacesToTabs($0, tabWidth: width) }
    }

    static func normalizeSpaces()        { transformSelection(Transformations.normalizeSpaces) }
    /// No UI — strips ASCII control + invisible Unicode outright.
    /// Backs the toolbar quick action and the bare menu item; use
    /// `presentZapGremlins` for the configurable sheet.
    static func zapGremlins() { transformSelection(Transformations.zapGremlins) }

    /// Called by the sheet after the user picks categories and a
    /// replacement.
    static func zapGremlinsConfigured(options: ZapGremlinsOptions) {
        transformSelection { Transformations.zapGremlins($0, options: options) }
    }

    static func presentZapGremlins() { presentSheet(.zapGremlins) }

    /// Browse and restore previous on-disk states of the current
    /// document. No-op for untitled buffers (no URL → no revisions).
    static func presentRevisions() { presentSheet(.revisions) }
    static func stripDiacritics()        { transformSelection(Transformations.stripDiacritics) }
    static func convertToASCII()         { transformSelection(Transformations.convertToASCII) }
    static func interpretEscapeSequences() { transformSelection(Transformations.interpretEscapeSequences) }
    static func escapeSpecialCharacters()  { transformSelection(Transformations.escapeSpecialCharacters) }
    static func addLineNumbers()         { transformSelection(Transformations.addLineNumbers) }
    static func removeLineNumbers()      { transformSelection(Transformations.removeLineNumbers) }
    static func removeBlankLines()       { transformSelection(Transformations.removeBlankLines) }
    static func increaseQuoteLevel()     { transformSelection(Transformations.increaseQuoteLevel) }
    static func decreaseQuoteLevel()     { transformSelection(Transformations.decreaseQuoteLevel) }

    /// Apply the document's current line-ending choice to every break
    /// in the buffer — useful after pasting from a source with mixed
    /// or different line endings.
    static func normalizeLineEndingsToDocument() {
        let ending = state?.lineEnding.string ?? "\n"
        applyToWholeText { Transformations.normalizeLineEndings($0, to: ending) }
    }
}

@MainActor
extension CommandActions {
    static func toggleLineComment() {
        guard let editor = actions, let state else { return }
        let prefix = LanguageRegistry.lineComment(for: state.languageIdentifier)
        guard !prefix.isEmpty else { return }
        let source = editor.text as NSString
        let selection = editor.selectedRange
        let range = selection.length > 0
            ? LineEditTarget(text: editor.text, selection: selection).range
            : source.lineRange(for: selection)
        let body = source.substring(with: range)
        var lines: [(location: Int, content: String)] = []
        body.enumerateSubstrings(in: body.startIndex..., options: .byLines) { substring, localRange, _, _ in
            guard let substring else { return }
            let indentation = substring.prefix { $0 == " " || $0 == "\t" }
            let content = String(substring.dropFirst(indentation.count))
            if !content.isEmpty {
                lines.append((range.location + NSRange(localRange, in: body).location + indentation.utf16.count, content))
            }
        }
        let remove = lines.allSatisfy { $0.content.hasPrefix(prefix) }
        let edits = lines.map { line -> BatchReplaceSet.Replacement in
            let length = remove ? prefix.utf16.count + (line.content.hasPrefix(prefix + " ") ? 1 : 0) : 0
            return .init(range: NSRange(location: line.location, length: length), text: remove ? "" : prefix + " ")
        }
        editor.replaceText(in: BatchReplaceSet(replacements: edits))
        let change = edits.reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
        editor.setSelection(NSRange(location: range.location, length: range.length + change))
    }
}
