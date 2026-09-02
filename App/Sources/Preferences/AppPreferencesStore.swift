import SwiftUI

/// Observable, persistent application preferences.
@MainActor
@Observable
final class AppPreferencesStore {

    static let shared = AppPreferencesStore()

    // MARK: Appearance
    var themeName: String { didSet { write(AppPreferenceKey.themeName, themeName) } }
    var fontName: String  { didSet { write(AppPreferenceKey.fontName, fontName) } }
    var fontSize: Double  { didSet { write(AppPreferenceKey.fontSize, fontSize) } }
    var lineHeight: Double { didSet { write(AppPreferenceKey.lineHeight, lineHeight) } }
    var ligatures: Bool   { didSet { write(AppPreferenceKey.ligatures, ligatures) } }

    // MARK: Editor display
    var showLineNumbers: Bool        { didSet { write(AppPreferenceKey.showLineNumbers, showLineNumbers) } }
    var wrapLines: Bool              { didSet { write(AppPreferenceKey.wrapLines, wrapLines) } }
    var highlightCurrentLine: Bool   { didSet { write(AppPreferenceKey.highlightCurrentLine, highlightCurrentLine) } }
    var highlightMatchingBrackets: Bool { didSet { write(AppPreferenceKey.highlightMatchingBrackets, highlightMatchingBrackets) } }
    var showPageGuide: Bool          { didSet { write(AppPreferenceKey.showPageGuide, showPageGuide) } }
    var pageGuideColumn: Int         { didSet { write(AppPreferenceKey.pageGuideColumn, pageGuideColumn) } }
    var showStatusBar: Bool          { didSet { write(AppPreferenceKey.showStatusBar, showStatusBar) } }
    var showToolbar: Bool            { didSet { write(AppPreferenceKey.showToolbar, showToolbar) } }
    var liveMatchHighlight: Bool     { didSet { write(AppPreferenceKey.liveMatchHighlight, liveMatchHighlight) } }
    var showChangeHistoryGutter: Bool { didSet { write(AppPreferenceKey.showChangeHistoryGutter, showChangeHistoryGutter) } }
    var overscroll: Bool             { didSet { write(AppPreferenceKey.overscroll, overscroll) } }

    // MARK: Invisibles
    var showInvisibles: Bool                  { didSet { write(AppPreferenceKey.showInvisibles, showInvisibles) } }
    var showInvisibleSpace: Bool              { didSet { write(AppPreferenceKey.showInvisibleSpace, showInvisibleSpace) } }
    var showInvisibleTab: Bool                { didSet { write(AppPreferenceKey.showInvisibleTab, showInvisibleTab) } }
    var showInvisibleNewline: Bool            { didSet { write(AppPreferenceKey.showInvisibleNewline, showInvisibleNewline) } }
    var showInvisibleNonBreakingSpace: Bool   { didSet { write(AppPreferenceKey.showInvisibleNonBreakingSpace, showInvisibleNonBreakingSpace) } }

    // MARK: Status bar items
    var statusShowsLineCol: Bool   { didSet { write(AppPreferenceKey.statusShowsLineCol, statusShowsLineCol) } }
    var statusShowsCharCount: Bool { didSet { write(AppPreferenceKey.statusShowsCharCount, statusShowsCharCount) } }
    var statusShowsLineCount: Bool { didSet { write(AppPreferenceKey.statusShowsLineCount, statusShowsLineCount) } }

    // MARK: Indentation
    var usesTabs: Bool   { didSet { write(AppPreferenceKey.usesTabs, usesTabs) } }
    var indentWidth: Int { didSet { write(AppPreferenceKey.indentWidth, indentWidth) } }

    // MARK: Editing
    var insertCharacterPairs: Bool { didSet { write(AppPreferenceKey.insertCharacterPairs, insertCharacterPairs) } }
    var autoCorrect: Bool          { didSet { write(AppPreferenceKey.autoCorrect, autoCorrect) } }
    var autoCapitalize: Bool       { didSet { write(AppPreferenceKey.autoCapitalize, autoCapitalize) } }
    var smartQuotes: Bool          { didSet { write(AppPreferenceKey.smartQuotes, smartQuotes) } }
    var spellCheck: Bool           { didSet { write(AppPreferenceKey.spellCheck, spellCheck) } }
    var autoLinkDetection: Bool    { didSet { write(AppPreferenceKey.autoLinkDetection, autoLinkDetection) } }
    var autoContinueLists: Bool    { didSet { write(AppPreferenceKey.autoContinueLists, autoContinueLists) } }

    // MARK: Save behaviour
    var ensureTrailingNewline: Bool       { didSet { write(AppPreferenceKey.ensureTrailingNewline, ensureTrailingNewline) } }
    var trimTrailingWhitespaceOnSave: Bool { didSet { write(AppPreferenceKey.trimTrailingWhitespaceOnSave, trimTrailingWhitespaceOnSave) } }
    var saveUTF8BOM: Bool                 { didSet { write(AppPreferenceKey.saveUTF8BOM, saveUTF8BOM) } }

    // MARK: Defaults for new documents
    var defaultEncodingRaw: Int      { didSet { write(AppPreferenceKey.defaultEncodingRaw, defaultEncodingRaw) } }
    var defaultLineEndingRaw: String { didSet { write(AppPreferenceKey.defaultLineEndingRaw, defaultLineEndingRaw) } }
    var defaultLanguage: String      { didSet { write(AppPreferenceKey.defaultLanguage, defaultLanguage) } }

    // MARK: Large-file behaviour
    var syntaxLimitBytes: Int { didSet { write(AppPreferenceKey.syntaxLimitBytes, syntaxLimitBytes) } }

    private init() {
        let d = UserDefaults.standard
        themeName = d.string(forKey: AppPreferenceKey.themeName) ?? AppThemeName.automatic.rawValue
        fontName = d.string(forKey: AppPreferenceKey.fontName) ?? EditorFont.systemMono.rawValue
        fontSize = AppPreferencesStore.positiveDouble(d, AppPreferenceKey.fontSize, fallback: 14)
        lineHeight = AppPreferencesStore.positiveDouble(d, AppPreferenceKey.lineHeight, fallback: 1.2)
        ligatures = d.bool(forKey: AppPreferenceKey.ligatures)

        showLineNumbers = d.bool(forKey: AppPreferenceKey.showLineNumbers)
        wrapLines = d.bool(forKey: AppPreferenceKey.wrapLines)
        highlightCurrentLine = d.bool(forKey: AppPreferenceKey.highlightCurrentLine)
        highlightMatchingBrackets = d.bool(forKey: AppPreferenceKey.highlightMatchingBrackets)
        showPageGuide = d.bool(forKey: AppPreferenceKey.showPageGuide)
        pageGuideColumn = AppPreferencesStore.positiveInt(d, AppPreferenceKey.pageGuideColumn, fallback: 80)
        showStatusBar = d.bool(forKey: AppPreferenceKey.showStatusBar)
        showToolbar = d.bool(forKey: AppPreferenceKey.showToolbar)
        liveMatchHighlight = d.bool(forKey: AppPreferenceKey.liveMatchHighlight)
        showChangeHistoryGutter = d.bool(forKey: AppPreferenceKey.showChangeHistoryGutter)
        overscroll = d.bool(forKey: AppPreferenceKey.overscroll)

        showInvisibles = d.bool(forKey: AppPreferenceKey.showInvisibles)
        showInvisibleSpace = d.bool(forKey: AppPreferenceKey.showInvisibleSpace)
        showInvisibleTab = d.bool(forKey: AppPreferenceKey.showInvisibleTab)
        showInvisibleNewline = d.bool(forKey: AppPreferenceKey.showInvisibleNewline)
        showInvisibleNonBreakingSpace = d.bool(forKey: AppPreferenceKey.showInvisibleNonBreakingSpace)

        statusShowsLineCol = d.bool(forKey: AppPreferenceKey.statusShowsLineCol)
        statusShowsCharCount = d.bool(forKey: AppPreferenceKey.statusShowsCharCount)
        statusShowsLineCount = d.bool(forKey: AppPreferenceKey.statusShowsLineCount)

        usesTabs = d.bool(forKey: AppPreferenceKey.usesTabs)
        indentWidth = AppPreferencesStore.positiveInt(d, AppPreferenceKey.indentWidth, fallback: 4)

        insertCharacterPairs = d.bool(forKey: AppPreferenceKey.insertCharacterPairs)
        autoCorrect = d.bool(forKey: AppPreferenceKey.autoCorrect)
        autoCapitalize = d.bool(forKey: AppPreferenceKey.autoCapitalize)
        smartQuotes = d.bool(forKey: AppPreferenceKey.smartQuotes)
        spellCheck = d.bool(forKey: AppPreferenceKey.spellCheck)
        autoLinkDetection = d.bool(forKey: AppPreferenceKey.autoLinkDetection)
        autoContinueLists = d.bool(forKey: AppPreferenceKey.autoContinueLists)

        ensureTrailingNewline = d.bool(forKey: AppPreferenceKey.ensureTrailingNewline)
        trimTrailingWhitespaceOnSave = d.bool(forKey: AppPreferenceKey.trimTrailingWhitespaceOnSave)
        saveUTF8BOM = d.bool(forKey: AppPreferenceKey.saveUTF8BOM)

        defaultEncodingRaw = AppPreferencesStore.positiveInt(d, AppPreferenceKey.defaultEncodingRaw, fallback: Int(String.Encoding.utf8.rawValue))
        defaultLineEndingRaw = d.string(forKey: AppPreferenceKey.defaultLineEndingRaw) ?? "\n"
        defaultLanguage = d.string(forKey: AppPreferenceKey.defaultLanguage) ?? LanguageIdentifier.markdown.rawValue

        // Zero and -1 are valid syntax-limit sentinels.
        let storedLimit = d.object(forKey: AppPreferenceKey.syntaxLimitBytes) as? Int
        syntaxLimitBytes = storedLimit.flatMap(SyntaxLimit.init(rawValue:))?.rawByteValue
            ?? SyntaxLimit.up5MB.rawByteValue

    }

    private func write<T>(_ key: String, _ value: T) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func positiveInt(_ d: UserDefaults, _ key: String, fallback: Int) -> Int {
        let v = d.integer(forKey: key)
        return v > 0 ? v : fallback
    }

    private static func positiveDouble(_ d: UserDefaults, _ key: String, fallback: Double) -> Double {
        let v = d.double(forKey: key)
        return v > 0 ? v : fallback
    }
}
