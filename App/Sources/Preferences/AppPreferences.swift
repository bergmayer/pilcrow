import Foundation

/// UserDefaults key constants. `AppPreferencesStore` is the typed
/// `@Observable` surface that reads/writes these; views @Bindable into
/// that store rather than touching keys directly.
enum AppPreferenceKey {

    // MARK: Appearance
    static let themeName              = "themeName"
    /// Sentinel value identifying which font face to use. See `EditorFont`.
    static let fontName               = "fontName"
    static let fontSize               = "fontSize"
    static let lineHeight             = "lineHeight"
    static let ligatures              = "ligatures"

    // MARK: Editor display
    static let documentTabAppearance = "documentTabAppearance"
    static let showLineNumbers        = "showLineNumbers"
    static let wrapLines              = "wrapLines"
    static let highlightCurrentLine   = "highlightCurrentLine"
    static let highlightMatchingBrackets = "highlightMatchingBrackets"
    static let showPageGuide          = "showPageGuide"
    static let pageGuideColumn        = "pageGuideColumn"
    static let showStatusBar          = "showStatusBar"
    /// Per-line green/yellow/red bars in the gutter showing what's
    /// changed since load/save. Off by default — the per-line diff
    /// is fast on small files but the engine's `caretRect` lookups
    /// + bar layout grow O(n) with line count, so it's gated on a
    /// hard byte ceiling (`changeHistoryGutterByteLimit`) on top of
    /// the per-window preference.
    static let showChangeHistoryGutter = "showChangeHistoryGutter"
    /// Extra scrollable space below the last line, sized as ten
    /// lines of the current font/line height. On by default — keeps
    /// the last line from being pinned to the bottom edge of the
    /// window.
    static let overscroll              = "overscroll"

    // MARK: Invisible characters (granular — master toggle + per-kind)
    static let showInvisibles         = "showInvisibles"
    static let showInvisibleSpace     = "showInvisibleSpace"
    static let showInvisibleTab       = "showInvisibleTab"
    static let showInvisibleNewline   = "showInvisibleNewline"
    static let showInvisibleNonBreakingSpace = "showInvisibleNonBreakingSpace"

    // MARK: Status bar items
    static let statusShowsLineCol     = "statusShowsLineCol"
    static let statusShowsCharCount   = "statusShowsCharCount"
    static let statusShowsLineCount   = "statusShowsLineCount"

    // MARK: Indentation
    static let usesTabs               = "usesTabs"
    static let indentWidth            = "indentWidth"

    // MARK: Editing
    static let insertCharacterPairs   = "insertCharacterPairs"
    static let autoCorrect            = "autoCorrect"
    static let autoCapitalize         = "autoCapitalize"
    static let smartQuotes            = "smartQuotes"
    static let spellCheck             = "spellCheck"
    static let autoLinkDetection      = "autoLinkDetection"
    static let autoContinueLists      = "autoContinueLists"
    static let jsTransformSlots       = "jsTransformSlots"

    // MARK: Save behavior
    static let ensureTrailingNewline  = "ensureTrailingNewline"
    static let trimTrailingWhitespaceOnSave = "trimTrailingWhitespaceOnSave"
    static let saveUTF8BOM            = "saveUTF8BOM"

    // MARK: Defaults for new documents
    static let newWindowContent = "newWindowContent"
    static let newTabContent = "newTabContent"
    static let defaultEncodingRaw     = "defaultEncodingRaw"
    static let defaultLineEndingRaw   = "defaultLineEndingRaw"
    static let defaultLanguage        = "defaultLanguage"

    // MARK: Large-file behaviour
    /// Maximum file size (in bytes) for which the engine applies syntax
    /// highlighting, fold discovery, and the markdown inline decorator.
    /// Files larger than this open in plain-text mode for responsiveness.
    /// Use `SyntaxLimit` constants — see `SyntaxLimit.rawByteValue`.
    static let syntaxLimitBytes       = "syntaxLimitBytes"

    // MARK: Toolbar
    /// JSON-encoded `[ToolbarSlot]` — symbol + command id for each
    /// item in the per-window in-app toolbar.
    static let toolbarSlots = "toolbarSlots"
    /// Whether the per-window in-app toolbar is rendered at the top of
    /// every editor scene.
    static let showToolbar  = "showToolbar"

    // MARK: Snippets
    /// JSON-encoded `[Snippet]` — ten fixed text-macro slots, parallel
    /// to JS Transforms. Slots without `content` stay disabled in the
    /// Text ▸ Snippets menu rather than disappearing.
    static let snippetSlots = "snippetSlots"
    /// JSON-encoded `[ClosedTabRecord]` — closed-tab recovery
    /// pool that survives window close and app restart.
    static let closedTabRecords = "closedTabRecords"
    /// JSON-encoded `[SessionRecord]` — open-window roster (tab list
    /// + file bookmarks + draft refs) so windows resume on next launch.
    static let sessionRecords = "sessionRecords"
    /// JSON-encoded `[ClosedWindowRecord]` — windows the user dismissed
    /// while they still contained locally recoverable unsaved changes.
    static let closedWindowRecords = "closedWindowRecords"
    static let canonizePairs = "canonizePairs"
    static let canonizeRegex = "canonizeRegex"

    // MARK: Live match highlighting
    /// When `true`, every occurrence of the current selection (≥2 chars,
    /// no newline) is tinted in the editor and tallied in the status bar.
    static let liveMatchHighlight = "liveMatchHighlight"

}

/// Default values applied on first launch and used as fallbacks when
/// `UserDefaults.standard` returns the zero value for a key.
enum AppPreferenceDefaults {

    static func register() {
        let defaults: [String: Any] = [
            // Appearance
            AppPreferenceKey.themeName: AppThemeName.automatic.rawValue,
            AppPreferenceKey.fontName: EditorFont.systemMono.rawValue,
            AppPreferenceKey.fontSize: 14.0,
            AppPreferenceKey.lineHeight: 1.2,
            AppPreferenceKey.ligatures: false,

            // Editor display
            AppPreferenceKey.documentTabAppearance: DocumentTabAppearance.tabBar.rawValue,
            AppPreferenceKey.showLineNumbers: true,
            AppPreferenceKey.wrapLines: true,
            AppPreferenceKey.highlightCurrentLine: true,
            AppPreferenceKey.highlightMatchingBrackets: true,
            AppPreferenceKey.showPageGuide: false,
            AppPreferenceKey.pageGuideColumn: 80,
            AppPreferenceKey.showStatusBar: true,
            AppPreferenceKey.showToolbar: true,
            AppPreferenceKey.liveMatchHighlight: true,
            AppPreferenceKey.showChangeHistoryGutter: false,
            AppPreferenceKey.overscroll: true,

            // Invisibles
            AppPreferenceKey.showInvisibles: false,
            AppPreferenceKey.showInvisibleSpace: true,
            AppPreferenceKey.showInvisibleTab: true,
            AppPreferenceKey.showInvisibleNewline: true,
            AppPreferenceKey.showInvisibleNonBreakingSpace: true,

            // Status bar items
            AppPreferenceKey.statusShowsLineCol: true,
            AppPreferenceKey.statusShowsCharCount: true,
            AppPreferenceKey.statusShowsLineCount: true,

            // Indentation
            AppPreferenceKey.usesTabs: false,
            AppPreferenceKey.indentWidth: 4,

            // Editing
            AppPreferenceKey.insertCharacterPairs: true,
            AppPreferenceKey.autoCorrect: false,
            AppPreferenceKey.autoCapitalize: false,
            AppPreferenceKey.smartQuotes: false,
            AppPreferenceKey.spellCheck: false,
            AppPreferenceKey.autoLinkDetection: false,
            AppPreferenceKey.autoContinueLists: true,

            // Save behavior
            AppPreferenceKey.ensureTrailingNewline: false,
            AppPreferenceKey.trimTrailingWhitespaceOnSave: false,
            AppPreferenceKey.saveUTF8BOM: false,

            // Defaults for new documents
            AppPreferenceKey.newWindowContent: NewDocumentContent.startPage.rawValue,
            AppPreferenceKey.newTabContent: NewDocumentContent.blankDocument.rawValue,
            AppPreferenceKey.defaultEncodingRaw: Int(String.Encoding.utf8.rawValue),
            AppPreferenceKey.defaultLineEndingRaw: "\n",
            AppPreferenceKey.defaultLanguage: LanguageIdentifier.markdown.rawValue,

            // Large-file behaviour — default to 5 MB. Above that, the
            // engine opens the file in plain-text mode so the initial
            // parse / fold-discovery / decorator passes don't lag the
            // UI on huge logs and minified bundles.
            AppPreferenceKey.syntaxLimitBytes: SyntaxLimit.up5MB.rawByteValue
        ]
        UserDefaults.standard.register(defaults: defaults)
    }
}
