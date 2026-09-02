import Foundation
import EditorEngine
import TreeSitter

import TreeSitterBash
import TreeSitterC
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTypeScript
import TreeSitterJava
import TreeSitterCPP
import TreeSitterLatex
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterTypst

/// Maps a language identifier to a EditorEngine `TreeSitterLanguage` with its
/// bundled `highlights.scm` query loaded.
///
/// Each tree-sitter grammar SPM package forward-declares its own `TSLanguage`
/// type, so each `tree_sitter_xxx()` function returns a pointer typed against
/// that module's own opaque struct. The underlying C type is the same; we
/// bridge with `unsafeBitCast` to the canonical `TreeSitter.TSLanguage`.
public enum SyntaxRegistry {

    /// All supported language identifiers, in display order.
    public static let supportedIdentifiers: [String] = [
        "bash", "c", "cpp", "css", "go", "html",
        "java", "javascript", "latex", "markdown",
        "python", "ruby", "rust", "swift",
        "typescript", "typst"
    ]

    /// Returns whether the given identifier has Tree-sitter support.
    public static func isSupported(_ identifier: String) -> Bool {
        supportedIdentifiers.contains(identifier)
    }

    /// Builds a EditorEngine `TreeSitterLanguage` for the given identifier.
    /// Returns `nil` for "plain" or unknown identifiers.
    public static func language(for identifier: String) -> TreeSitterLanguage? {
        switch identifier {
        case "bash":       return make(tree_sitter_bash(),       queryName: "Bash")
        case "c":          return make(tree_sitter_c(),          queryName: "C")
        case "cpp":        return make(tree_sitter_cpp(),        queryName: "C++")
        case "css":        return make(tree_sitter_css(),        queryName: "CSS")
        case "go":         return make(tree_sitter_go(),         queryName: "Go")
        case "html":       return make(tree_sitter_html(),       queryName: "HTML")
        case "java":       return make(tree_sitter_java(),       queryName: "Java")
        case "javascript": return make(tree_sitter_javascript(), queryName: "JavaScript")
        case "python":     return make(tree_sitter_python(),     queryName: "Python")
        case "ruby":       return make(tree_sitter_ruby(),       queryName: "Ruby")
        case "rust":       return make(tree_sitter_rust(),       queryName: "Rust")
        case "swift":      return make(tree_sitter_swift(),      queryName: "Swift")
        case "typescript": return make(tree_sitter_typescript(), queryName: "TypeScript")
        case "latex":      return make(tree_sitter_latex(),      queryName: "LaTeX")
        // Markdown: use the BLOCK grammar so headings, fenced code blocks,
        // and lists pick up tree-sitter highlights. Inline patterns
        // (`*emphasis*`, `**strong**`, `` `code` ``, links) are picked up
        // separately by the app-layer MarkdownInlineHighlighter scanner
        // because EditorEngine doesn't run two grammars in parallel.
        case "markdown":   return make(tree_sitter_markdown(),   queryName: "Markdown")
        case "typst":      return make(tree_sitter_typst(),      queryName: "Typst")
        default:           return nil
        }
    }

    // MARK: - Helpers

    private static func make<T>(_ rawPointer: UnsafePointer<T>, queryName: String) -> TreeSitterLanguage {
        // Each `tree_sitter_*()` returns a pointer to that module's own
        // forward-declared `TSLanguage` struct; the underlying C type is
        // identical. Round-tripping through `OpaquePointer` is the
        // sanctioned way to rebrand a C pointer's element type — unlike
        // `unsafeBitCast`, it doesn't trip the "changes pointee type" UB
        // diagnostic and doesn't go through value-bit reinterpretation.
        guard let bridged = UnsafePointer<TreeSitter.TSLanguage>(OpaquePointer(rawPointer)) else {
            fatalError("tree_sitter_\(queryName) returned a null language pointer")
        }
        let highlights = loadQuery(named: "highlights", language: queryName)
        return TreeSitterLanguage(bridged, highlightsQuery: highlights)
    }

    private static func loadQuery(named name: String, language: String) -> TreeSitterLanguage.Query? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "scm",
            subdirectory: "Queries/\(language)"
        ) else { return nil }
        return TreeSitterLanguage.Query(contentsOf: url)
    }
}
