import Foundation

/// Stable identifier for a syntax language. Raw values are persisted to
/// UserDefaults via `AppPreferenceKey.defaultLanguage` and used as keys in
/// the tree-sitter Queries directory — do not change them lightly.
enum LanguageIdentifier: String, CaseIterable, Codable, Hashable, Sendable {
    case plain, bash, c, cpp, csharp, css, go, html, java, javascript,
         json, kotlin, latex, lua, make, markdown, php, python, ruby, rust,
         scala, sql, swift, typescript, typst, xml, yaml
}

/// Maps file extensions to a language identifier and display name, and
/// provides per-language metadata (line-comment delimiter).
enum LanguageRegistry {

    struct Language {
        let identifier: LanguageIdentifier
        let displayName: String
        let extensions: [String]
        /// Line-comment prefix for Format ▸ Toggle Line Comment. Empty
        /// means the language does not have a single-line comment syntax
        /// we support.
        let lineComment: String
    }

    static let all: [Language] = [
        .init(identifier: .plain,      displayName: "Plain Text",  extensions: ["txt", "text", "log"], lineComment: ""),
        .init(identifier: .bash,       displayName: "Bash",        extensions: ["sh", "bash", "zsh"], lineComment: "#"),
        .init(identifier: .c,          displayName: "C",           extensions: ["c", "h"], lineComment: "//"),
        .init(identifier: .cpp,        displayName: "C++",         extensions: ["cpp", "cc", "hpp", "cxx"], lineComment: "//"),
        .init(identifier: .csharp,     displayName: "C#",          extensions: ["cs"], lineComment: "//"),
        .init(identifier: .css,        displayName: "CSS",         extensions: ["css"], lineComment: ""),
        .init(identifier: .go,         displayName: "Go",          extensions: ["go"], lineComment: "//"),
        .init(identifier: .html,       displayName: "HTML",        extensions: ["html", "htm"], lineComment: ""),
        .init(identifier: .java,       displayName: "Java",        extensions: ["java"], lineComment: "//"),
        .init(identifier: .javascript, displayName: "JavaScript",  extensions: ["js", "mjs", "cjs"], lineComment: "//"),
        .init(identifier: .json,       displayName: "JSON",        extensions: ["json"], lineComment: ""),
        .init(identifier: .kotlin,     displayName: "Kotlin",      extensions: ["kt", "kts"], lineComment: "//"),
        .init(identifier: .latex,      displayName: "LaTeX",       extensions: ["tex", "ltx"], lineComment: "%"),
        .init(identifier: .lua,        displayName: "Lua",         extensions: ["lua"], lineComment: "--"),
        .init(identifier: .make,       displayName: "Makefile",    extensions: ["mk", "make"], lineComment: "#"),
        .init(identifier: .markdown,   displayName: "Markdown",    extensions: ["md", "markdown"], lineComment: ""),
        .init(identifier: .php,        displayName: "PHP",         extensions: ["php"], lineComment: "//"),
        .init(identifier: .python,     displayName: "Python",      extensions: ["py"], lineComment: "#"),
        .init(identifier: .ruby,       displayName: "Ruby",        extensions: ["rb"], lineComment: "#"),
        .init(identifier: .rust,       displayName: "Rust",        extensions: ["rs"], lineComment: "//"),
        .init(identifier: .scala,      displayName: "Scala",       extensions: ["scala"], lineComment: "//"),
        .init(identifier: .sql,        displayName: "SQL",         extensions: ["sql"], lineComment: "--"),
        .init(identifier: .swift,      displayName: "Swift",       extensions: ["swift"], lineComment: "//"),
        .init(identifier: .typescript, displayName: "TypeScript",  extensions: ["ts", "tsx"], lineComment: "//"),
        .init(identifier: .typst,      displayName: "Typst",       extensions: ["typ"], lineComment: "//"),
        .init(identifier: .xml,        displayName: "XML",         extensions: ["xml"], lineComment: ""),
        .init(identifier: .yaml,       displayName: "YAML",        extensions: ["yml", "yaml"], lineComment: "#")
    ]

    /// Pick a language for a file URL by extension. Falls back to `.plain`.
    static func identifier(for url: URL?) -> LanguageIdentifier {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else { return .plain }
        return all.first { $0.extensions.contains(ext) }?.identifier ?? .plain
    }

    /// The native exporter accepts arbitrary text extensions; suggest one
    /// for an untitled document without changing a user-provided suffix.
    static func suggestedFilename(_ title: String, language: LanguageIdentifier) -> String {
        guard (title as NSString).pathExtension.isEmpty else { return title }
        let suffix = all.first { $0.identifier == language }?.extensions.first ?? "txt"
        return title + "." + suffix
    }

    /// Display name for an identifier — useful for the status bar and menus.
    static func displayName(for identifier: LanguageIdentifier) -> String {
        all.first { $0.identifier == identifier }?.displayName ?? "Plain Text"
    }

    /// Line-comment prefix, or "" if the language doesn't have one we support.
    static func lineComment(for identifier: LanguageIdentifier) -> String {
        all.first { $0.identifier == identifier }?.lineComment ?? ""
    }
}
