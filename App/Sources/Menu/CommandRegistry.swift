import SwiftUI
import FileEncoding
import LineEnding

enum CommandCategory: String {
    case app          = "App"
    case bookmark     = "Bookmark"
    case convertCase  = "Convert Case"
    case edit         = "Edit"
    case encoding     = "Encoding"
    case file         = "File"
    case fold         = "Fold"
    case format       = "Format"
    case insert       = "Insert"
    case inspect      = "Inspect"
    case language     = "Language"
    case lineEndings  = "Line Endings"
    case markdown     = "Markdown"
    case navigate     = "Navigate"
    case search       = "Search"
    case selection    = "Selection"
    case snippets     = "Snippets"
    case speech       = "Speech"
    case spelling     = "Spelling"
    case text         = "Text"
    case tools        = "Tools"
    case unicode      = "Unicode"
    case view         = "View"
}

/// Title + synonyms + description all feed the fuzzy matcher; the
/// title wins ties since it's weighted slightly higher.
struct EditorCommandSpec: Identifiable {
    let id: String
    let title: String
    let category: CommandCategory
    let shortcutHint: String?
    let synonyms: [String]
    let description: String?
    let action: @MainActor () -> Void
    let isEnabled: @MainActor () -> Bool

    // Pre-lowercased so palette typing doesn't allocate per keystroke.
    let titleChars: [Character]
    let synonymChars: [[Character]]
    let categoryChars: [Character]
    let descriptionChars: [Character]?

    init(
        id: String,
        title: String,
        category: CommandCategory,
        shortcutHint: String? = nil,
        synonyms: [String] = [],
        description: String? = nil,
        action: @escaping @MainActor () -> Void,
        isEnabled: @escaping @MainActor () -> Bool = { AppStateBus.shared.scenes.currentEditor != nil }
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcutHint = shortcutHint
        self.synonyms = synonyms
        self.description = description
        self.action = action
        self.isEnabled = isEnabled
        self.titleChars = Array(title.lowercased())
        self.synonymChars = synonyms.map { Array($0.lowercased()) }
        self.categoryChars = Array(category.rawValue.lowercased())
        self.descriptionChars = description.map { Array($0.lowercased()) }
    }
}

/// Built dynamically so per-language / per-encoding entries are
/// included alongside the static commands. Built once per launch and
/// cached — the spec list is pure for the app's lifetime since the
/// per-device branches (e.g. `DeviceIdiom`) resolve at startup.
@MainActor
enum CommandRegistry {

    private static let cache: (commands: [EditorCommandSpec], index: [String: Int]) = {
        let commands = build()
        var index: [String: Int] = [:]
        index.reserveCapacity(commands.count)
        for (i, spec) in commands.enumerated() { index[spec.id] = i }
        return (commands, index)
    }()

    static func all() -> [EditorCommandSpec] { cache.commands }

    /// O(1) lookup; nil when no command has that id (e.g. a stale
    /// `ToolbarConfig` slot pointing at a removed command).
    static func lookup(id: String) -> EditorCommandSpec? {
        guard let i = cache.index[id] else { return nil }
        return cache.commands[i]
    }

    private static func build() -> [EditorCommandSpec] {
        var commands: [EditorCommandSpec] = []

        if DeviceIdiom.supportsMultipleWindows {
            commands.append(
                .init(id: "newWindow", title: "New Window", category: .file, shortcutHint: "⌘N",
                      synonyms: ["spawn window", "open empty editor"],
                      action: CommandActions.newWindow,
                      isEnabled: { true })
            )
            commands.append(
                .init(id: "closeWindow", title: "Close Window", category: .file, shortcutHint: "⇧⌘W",
                      synonyms: ["close this window"], action: { CommandActions.closeWindow() })
            )
            commands.append(
                .init(id: "saveAllAndCloseWindow", title: "Save All and Close Window", category: .file,
                      synonyms: ["save all", "save every document", "save and close"],
                      description: "Save each changed document, then close this window. Canceling any save keeps it open.",
                      action: { CommandActions.saveAllAndCloseWindow() })
            )
        }

        // MARK: File / Window

        commands += [
            .init(id: "newTab",     title: "New Tab",                        category: .file, shortcutHint: "⌘T",   synonyms: ["new document", "new tab", "blank document", "spawn tab", "open empty tab"], action: CommandActions.newTab, isEnabled: { AppStateBus.shared.scenes.currentSession != nil }),
            .init(id: "newTemplate", title: "New from Template…",             category: .file, synonyms: ["template", "new template document", "template picker"], action: CommandActions.newFromTemplate, isEnabled: { AppStateBus.shared.scenes.currentSession != nil }),
            .init(id: "showTabs",   title: "Show All Tabs",                  category: .file, shortcutHint: "⇧⌘\\", synonyms: ["tab switcher", "tab overview", "expose tabs", "all tabs"], action: CommandActions.showTabSwitcher, isEnabled: { true }),
            .init(id: "reopenTab",  title: "Reopen Last Closed Tab",         category: .file, shortcutHint: "⇧⌘T",  synonyms: ["restore tab", "undo close tab", "recently closed"], action: CommandActions.reopenLastClosedTab, isEnabled: { true }),
            .init(id: "closeTab",   title: "Close Tab",                      category: .file, shortcutHint: "⌘W",   synonyms: ["close current tab"], action: CommandActions.closeActiveTab),
            .init(id: "pinTab",     title: "Pin / Unpin Tab",                category: .file, synonyms: ["pin", "unpin", "favourite tab"], action: CommandActions.pinCurrentTab),
            .init(id: "closeOthers", title: "Close Other Tabs",              category: .file, synonyms: ["close all other tabs"], action: CommandActions.closeOtherTabs),
            .init(id: "closeAllTabs", title: "Close All Tabs", category: .file, synonyms: ["close every tab"], action: {
                guard let session = CommandActions.session else { return }
                CommandActions.requestCloseAllTabs(in: session)
            }),
            .init(id: "closeRight", title: "Close Tabs to the Right",        category: .file, synonyms: ["close trailing tabs"], action: CommandActions.closeTabsToRight),
            .init(id: "nextTab",    title: "Next Tab",                       category: .file, shortcutHint: "⇧⌘]", synonyms: ["select next tab", "tab forward"], action: CommandActions.nextTab),
            .init(id: "prevTab",    title: "Previous Tab",                   category: .file, shortcutHint: "⇧⌘[", synonyms: ["select previous tab", "tab back"], action: CommandActions.previousTab),
            .init(id: "openInTab",  title: "Open File in New Tab…",          category: .file, shortcutHint: DeviceIdiom.supportsMultipleWindows ? nil : "⌘O", synonyms: ["open document in new tab", "open file", "load file", "force tab"], action: CommandActions.presentFileBrowserInNewTab, isEnabled: { true }),
            .init(id: "openInWin",  title: "Open File in New Window…",       category: .file, shortcutHint: "⌘O",   synonyms: ["open document in new window", "open file", "load file", "force window"], action: CommandActions.presentFileBrowserInNewWindow, isEnabled: { DeviceIdiom.supportsMultipleWindows }),
            .init(id: "shareText", title: "Share Text…", category: .file, action: CommandActions.shareText),
            .init(id: "shareFile", title: "Share File…", category: .file, action: CommandActions.shareFile),
            .init(id: "print", title: "Print…", category: .file, shortcutHint: "⌘⇧P", action: CommandActions.printDocument),
            .init(id: "saveFile",   title: "Save",                           category: .file, shortcutHint: "⌘S",   synonyms: ["write file"],                       action: CommandActions.saveFile),
            .init(id: "saveAs",     title: "Save As…",                       category: .file, shortcutHint: "⇧⌘S",  synonyms: ["save copy", "duplicate file"],     action: CommandActions.saveFileAs),
            .init(id: "revert",     title: "Revert to Saved",                category: .file, synonyms: ["reload from disk", "discard changes"], action: CommandActions.revertToSaved),
            .init(id: "revs",       title: "Show Revisions…",                category: .file, shortcutHint: "⌥⌘H",  synonyms: ["history", "versions", "time machine", "undo to disk"], action: CommandActions.presentRevisions),
            .init(id: "prefs",      title: "Settings…",                      category: .app,  shortcutHint: "⌘,",   synonyms: ["preferences", "options", "config", "settings", "edit transforms"], action: CommandActions.presentPreferences,    isEnabled: { true }),
            .init(id: "palette",    title: "Command Palette…",               category: .app,  shortcutHint: "⌘P",   synonyms: ["all commands", "fuzzy commands"],  action: CommandActions.presentCommandPalette, isEnabled: { true })
        ]

        // MARK: Search

        commands += [
            .init(id: "find",       title: "Find…",                          category: .search, shortcutHint: "⌘F",   synonyms: ["search"], action: CommandActions.presentFindNavigator),
            .init(id: "findRepl", title: "Find & Replace…", category: .search,
                  synonyms: ["replace text", "replace all"], action: CommandActions.presentFindAndReplace),
            .init(id: "findFast",   title: "Find Incrementally",             category: .search, shortcutHint: "⌥⌘F",  synonyms: ["quick find", "find bar", "incremental search", "live search"], action: CommandActions.presentSystemFindBar),
            .init(id: "multiFile",  title: "Multi-File Search…",             category: .search, shortcutHint: "⇧⌘F",  synonyms: ["search in folder", "grep folder", "find in files", "search across files"], action: CommandActions.presentMultiFileSearch, isEnabled: { true }),
            .init(id: "findFirst",  title: "Find First",                     category: .search, synonyms: ["first match", "jump to first match", "find from start"], action: CommandActions.findFirst),
            .init(id: "findNext",   title: "Find Next",                      category: .search, action: CommandActions.findNext),
            .init(id: "findPrev",   title: "Find Previous",                  category: .search, action: CommandActions.findPrevious),
            .init(id: "findNextSel", title: "Find Next Occurrence of Selection",     category: .search, action: CommandActions.findNextOccurrenceOfSelection),
            .init(id: "findPrevSel", title: "Find Previous Occurrence of Selection", category: .search, action: CommandActions.findPreviousOccurrenceOfSelection),
            .init(id: "replSel",    title: "Replace All in Selection",       category: .search, synonyms: ["replace within selection", "scoped replace all"], action: CommandActions.replaceAllInSelection),
            .init(id: "replEnd",    title: "Replace to End",                 category: .search, synonyms: ["replace from cursor", "replace from here"], action: CommandActions.replaceToEnd),
            .init(id: "gotoLine",   title: "Go to Line…",                    category: .search, shortcutHint: "⌘L",   action: { CommandActions.presentSheet(.goToLine) }),
            .init(id: "gotoBracket", title: "Go to Matching Bracket",        category: .search, shortcutHint: "⌃⌘B", action: CommandActions.goToMatchingBracket),
            .init(id: "posBack",    title: "Back",                           category: .navigate, shortcutHint: "⌃⌘←", action: CommandActions.positionBack),
            .init(id: "posFwd",     title: "Forward",                        category: .navigate, shortcutHint: "⌃⌘→", action: CommandActions.positionForward)
        ]

        commands += [
            .init(id: "undo", title: "Undo", category: .edit, shortcutHint: "⌘Z", action: CommandActions.undo,
                  isEnabled: { CommandActions.actions?.undoManager?.canUndo == true }),
            .init(id: "redo", title: "Redo", category: .edit, shortcutHint: "⇧⌘Z", action: CommandActions.redo,
                  isEnabled: { CommandActions.actions?.undoManager?.canRedo == true }),
            .init(id: "cut", title: "Cut", category: .edit, shortcutHint: "⌘X", action: CommandActions.cutSelection,
                  isEnabled: { (CommandActions.actions?.selectedRange.length ?? 0) > 0 }),
            .init(id: "copy", title: "Copy", category: .edit, shortcutHint: "⌘C", action: CommandActions.copySelection,
                  isEnabled: { (CommandActions.actions?.selectedRange.length ?? 0) > 0 }),
            .init(id: "paste", title: "Paste", category: .edit, shortcutHint: "⌘V", action: CommandActions.paste),
            .init(id: "selectAll", title: "Select All", category: .selection, shortcutHint: "⌘A", action: { CommandActions.actions?.selectAll() })
        ]

        // MARK: Selection / line ops

        commands += [
            .init(id: "selWord",        title: "Select Word",                category: .selection, action: CommandActions.selectCurrentWord),
            .init(id: "selLine",        title: "Select Line",                category: .selection, action: CommandActions.selectCurrentLine),
            .init(id: "selLinesContaining", title: "Select Lines Containing…", category: .selection, action: { CommandActions.presentSheet(.selectLinesContaining) }),
            .init(id: "smartHome",      title: "Smart Move to Line Start",   category: .edit,      synonyms: ["home", "beginning of line", "bol"], action: CommandActions.smartMoveToLineStart),
            .init(id: "transpose",      title: "Transpose Characters",       category: .edit, shortcutHint: "⌃T", synonyms: ["swap chars"], action: CommandActions.transposeCharacters),
            .init(id: "delEOL",         title: "Delete to End of Line",      category: .edit, shortcutHint: "⌃K", synonyms: ["kill line", "erase to end"], action: CommandActions.deleteToEndOfLine),
            .init(id: "delWordBack",    title: "Delete Word Backward",       category: .edit, shortcutHint: "⌥⌫", synonyms: ["erase word", "backward kill word"], action: CommandActions.deleteWordBackward),
            .init(id: "delWordFwd",     title: "Delete Word Forward",        category: .edit, shortcutHint: "⌥⌦", synonyms: ["forward kill word"], action: CommandActions.deleteWordForward),
            .init(id: "comment", title: "Toggle Line Comment", category: .edit, shortcutHint: "⌘/",
                  action: CommandActions.toggleLineComment, isEnabled: {
                      guard let state = CommandActions.state, state.textView != nil else { return false }
                      return !LanguageRegistry.lineComment(for: state.languageIdentifier).isEmpty
                  }),
            .init(id: "indent",     title: "Indent Selection",    category: .edit,      shortcutHint: "⌘]",  synonyms: ["shift right", "tab"], action: CommandActions.indentSelection),
            .init(id: "outdent",    title: "Outdent Selection",   category: .edit,      shortcutHint: "⌘[",  synonyms: ["shift left", "unindent", "dedent"], action: CommandActions.outdentSelection),
            .init(id: "mdListDash",   title: "Convert to Bullet List (- )", category: .format, synonyms: ["markdown list dash", "dash list", "to bullets"], action: CommandActions.convertToBulletListDash),
            .init(id: "mdListStar",   title: "Convert to Bullet List (* )", category: .format, synonyms: ["markdown list star", "asterisk list"],          action: CommandActions.convertToBulletListStar),
            .init(id: "mdListNum",    title: "Convert to Numbered List",    category: .format, synonyms: ["markdown ordered list", "numbered list", "1."], action: CommandActions.convertToNumberedList),
            .init(id: "outline",      title: "Show Outline",                 category: .view, shortcutHint: "⌃⌘S", synonyms: ["sidebar", "show sidebar", "toggle sidebar", "headings", "toc", "table of contents", "structure", "outline sidebar", "navigation panel"], action: CommandActions.showOutline),
            .init(id: "wordCount", title: "Word Count…", category: .inspect,
                  synonyms: ["statistics", "character count", "selection count"], action: {
                      let owner = CommandActions.session?.activeTab.state ?? CommandActions.state
                      owner?.inspectorTab = .file
                      owner?.inspectorOpen = true
                  }),
            .init(id: "fileInfo",     title: "Show File Information",        category: .view, shortcutHint: "⌥⌘I", synonyms: ["file info", "inspector", "metadata", "details", "outline panel"], action: CommandActions.toggleInspector),
            .init(id: "mdPreview",    title: "Markdown Preview…",           category: .markdown, shortcutHint: "⌥⌘P", synonyms: ["render", "html preview"], action: CommandActions.presentMarkdownPreview),
            .init(id: "reflow",       title: "Reflow Paragraph (80 cols)",  category: .format,   synonyms: ["hard wrap", "rewrap", "paragraph fill", "fill"], action: { CommandActions.reflowParagraph(column: 80) }),
            .init(id: "processLines", title: "Process Lines Containing…",   category: .text, synonyms: ["filter lines", "extract lines", "keep matching", "delete matching"], action: CommandActions.presentProcessLines),
            .init(id: "canonize",     title: "Canonize / Text Merge…",      category: .text, synonyms: ["batch find replace", "lookup table", "table replace"], action: CommandActions.presentCanonize),
            .init(id: "copyBookmarks", title: "Copy Bookmarked Lines",      category: .bookmark, synonyms: ["yank bookmarks", "extract bookmarks"], action: CommandActions.copyBookmarkedLines),
            .init(id: "cutBookmarks", title: "Cut Bookmarked Lines",        category: .bookmark, synonyms: ["yank bookmarks", "remove bookmarks"], action: CommandActions.cutBookmarkedLines),
            .init(id: "keepBookmarks", title: "Keep Only Bookmarked Lines", category: .bookmark, synonyms: ["filter to bookmarks", "isolate bookmarks"], action: CommandActions.keepBookmarkedLinesOnly),
            .init(id: "delBookmarks", title: "Delete Bookmarked Lines",     category: .bookmark, synonyms: ["remove bookmarked"], action: CommandActions.removeBookmarkedLines),
            .init(id: "invBookmarks", title: "Invert Bookmarks",            category: .bookmark, synonyms: ["flip bookmarks", "toggle bookmarks"], action: CommandActions.invertBookmarks),
            .init(id: "foldSel",      title: "Fold Selection",              category: .view, shortcutHint: "⌃⌘H", synonyms: ["fold lines", "collapse selection", "hide selection"], action: CommandActions.foldSelection),
            .init(id: "splitView",    title: "Cycle Split View",            category: .view, shortcutHint: "⌥⌘E", synonyms: ["split editor", "split pane", "two panes", "side by side", "vertical split", "horizontal split", "toggle split"], action: CommandActions.cycleSplitView),
            .init(id: "mdTable",      title: "Insert Markdown Table…",      category: .markdown, shortcutHint: "⌃⌘T", synonyms: ["markdown table", "table inserter"], action: CommandActions.presentMarkdownTable),
            .init(id: "mdFootOrg",    title: "Organize Footnotes…",         category: .markdown, synonyms: ["renumber footnotes", "sort footnotes", "footnote cleanup"], action: { CommandActions.presentSheet(.organizeFootnotes) }),
            .init(id: "openCurNewWin", title: "Open Current File in New Window", category: .file, synonyms: ["split", "side by side", "second window", "duplicate window"], action: CommandActions.openCurrentDocumentInNewWindow),
            .init(id: "moveUp",     title: "Move Line Up",        category: .edit,      shortcutHint: "⌥↑",  synonyms: ["swap with previous line"], action: CommandActions.moveLineUp),
            .init(id: "moveDown",   title: "Move Line Down",      category: .edit,      shortcutHint: "⌥↓",  synonyms: ["swap with next line"], action: CommandActions.moveLineDown),
            .init(id: "dupLine",    title: "Duplicate Line",      category: .edit,      shortcutHint: "⇧⌘D", synonyms: ["copy line", "clone line"], action: CommandActions.duplicateLine),
            .init(id: "delLine",    title: "Delete Line",         category: .edit,      shortcutHint: "⇧⌘K", synonyms: ["kill line", "erase line", "remove line"], action: CommandActions.deleteLine)
        ]

        // MARK: Text — sort / unique / trim

        commands += [
            .init(id: "sortLines",  title: "Sort Lines…",            category: .text, action: CommandActions.sortLines),
            .init(id: "revLines",   title: "Reverse Lines",          category: .text, action: CommandActions.reverseLines),
            .init(id: "uniqLines",  title: "Unique Lines",           category: .text, action: CommandActions.uniqueLines),
            .init(id: "trim",       title: "Trim Trailing Whitespace", category: .text, action: CommandActions.trimTrailingWhitespace),
            .init(id: "revSel",     title: "Reverse Selection",      category: .text, action: CommandActions.reverseSelection),
            .init(id: "removeLB",   title: "Remove Linebreaks",      category: .text,
                  synonyms: ["unwrap", "join lines", "remove line breaks", "remove newlines"],
                  action: CommandActions.removeLinebreaks),
            .init(id: "addLB",      title: "Add Linebreaks",         category: .text,
                  synonyms: ["wrap", "word wrap", "hard wrap", "add line breaks"],
                  action: CommandActions.addLinebreaks),
            .init(id: "eduQuotes",  title: "Educate Quotes",         category: .text,
                  synonyms: ["smart quotes", "typographer quotes", "curly quotes"],
                  action: CommandActions.educateQuotes),
            .init(id: "strQuotes",  title: "Straighten Quotes",      category: .text,
                  synonyms: ["dumb quotes", "ascii quotes", "remove curly quotes"],
                  action: CommandActions.straightenQuotes),
            .init(id: "tabs2sp",    title: "Convert Tabs to Spaces", category: .text,
                  synonyms: ["expand tabs", "untabify"],
                  action: CommandActions.tabsToSpaces),
            .init(id: "sp2tabs",    title: "Convert Spaces to Tabs", category: .text,
                  synonyms: ["tabify", "collapse indent"],
                  action: CommandActions.spacesToTabs),
            .init(id: "normSpaces", title: "Normalize Spaces",       category: .text,
                  synonyms: ["collapse whitespace", "single space"],
                  action: CommandActions.normalizeSpaces),
            .init(id: "normLE",     title: "Normalize Line Endings", category: .text,
                  synonyms: ["fix line endings", "convert line endings", "unify line endings"],
                  action: CommandActions.normalizeLineEndingsToDocument),
            .init(id: "zapGremlin", title: "Zap Gremlins…",          category: .text,
                  synonyms: ["strip control characters", "clean weird unicode", "remove invisible characters", "zap"],
                  action: CommandActions.presentZapGremlins),
            .init(id: "stripDia",   title: "Strip Diacritics",       category: .text,
                  synonyms: ["remove accents", "fold accents", "ascii fold"],
                  action: CommandActions.stripDiacritics),
            .init(id: "interpEsc",  title: "Interpret Escape Sequences", category: .text,
                  synonyms: ["decode escapes", "expand backslash escapes"],
                  action: CommandActions.interpretEscapeSequences),
            .init(id: "escSpecial", title: "Escape Special Characters", category: .text,
                  synonyms: ["encode escapes", "backslash escape"],
                  action: CommandActions.escapeSpecialCharacters),
            .init(id: "toAscii",    title: "Convert to ASCII",       category: .text,
                  synonyms: ["transliterate", "ascii only", "strip non ascii"],
                  action: CommandActions.convertToASCII),
            .init(id: "addLineNum", title: "Add Line Numbers",       category: .text,
                  synonyms: ["number lines", "prefix line numbers"],
                  action: CommandActions.addLineNumbers),
            .init(id: "delLineNum", title: "Remove Line Numbers",    category: .text,
                  synonyms: ["strip line numbers", "unnumber"],
                  action: CommandActions.removeLineNumbers),
            .init(id: "rmBlank",    title: "Remove Blank Lines",     category: .text,
                  synonyms: ["delete empty lines", "compact lines"],
                  action: CommandActions.removeBlankLines),
            .init(id: "incQuote",   title: "Increase Quote Level",   category: .text,
                  synonyms: ["add quote level", "indent quote", "more quote"],
                  action: CommandActions.increaseQuoteLevel),
            .init(id: "decQuote",   title: "Decrease Quote Level",   category: .text,
                  synonyms: ["remove quote level", "unindent quote", "less quote"],
                  action: CommandActions.decreaseQuoteLevel),
            .init(id: "stripQuote", title: "Strip Quotes",           category: .text,
                  synonyms: ["unquote", "remove leading quote", "remove > prefix"],
                  action: CommandActions.stripQuoteLevel),
            .init(id: "prefSuf",    title: "Prefix / Suffix Lines…", category: .text,
                  synonyms: ["prefix lines", "suffix lines", "wrap each line"],
                  action: CommandActions.presentPrefixSuffixLines)
        ]

        // MARK: Insert

        commands += [
            .init(id: "insLipsum",  title: "Insert Lorem Ipsum…",    category: .insert,
                  synonyms: ["placeholder text", "dummy text", "filler"],
                  action: CommandActions.presentInsertLoremIpsum),
            .init(id: "insFile",    title: "Insert File Contents…",  category: .insert,
                  synonyms: ["include file", "paste file"],
                  action: CommandActions.presentInsertFileContents),
            .init(id: "insFolder",  title: "Insert Folder Listing…", category: .insert,
                  synonyms: ["directory listing", "tree", "ls"],
                  action: CommandActions.presentInsertFolderListing),
        ]

        // MARK: Snippets / Clipboard

        commands += [
            .init(id: "copyAll",    title: "Copy All",                  category: .edit,
                  synonyms: ["copy document", "copy entire document", "copy whole file", "clipboard"],
                  action: { CommandActions.copyAll() },
                  isEnabled: { AppStateBus.shared.scenes.currentSession?.activeTab.kind == .editor }),
            .init(id: "snipSave",   title: "Save Selection as Snippet", category: .snippets,
                  synonyms: ["add snippet", "create snippet"],
                  action: CommandActions.saveSelectionAsSnippet,
                  isEnabled: { (AppStateBus.shared.scenes.currentEditor?.selectedRange.length ?? 0) > 0 }),
            .init(id: "clipHist",   title: "Clipboard History…",     category: .edit,
                  shortcutHint: "⇧⌘V",
                  synonyms: ["clipboard", "paste history", "paste menu", "past pastes", "past clipboard"],
                  action: CommandActions.presentClipboardHistory,
                  isEnabled: { true })
        ]

        for slot in SnippetsStore.shared.slots {
            let id = slot.id
            commands.append(.init(
                id: "snipSlot\(id)",
                title: "Insert \(slot.displayName)",
                category: .snippets,
                shortcutHint: SnippetsStore.shortcutHint(for: id),
                synonyms: ["snippet \(id)", slot.name],
                action: { CommandActions.insertSnippet(slotID: id) },
                isEnabled: { SnippetsStore.shared.slot(id: id)?.isConfigured ?? false }
            ))
        }

        for slot in JSTransformStore.shared.slots {
            let id = slot.id
            commands.append(.init(
                id: "jsSlot\(id)",
                title: "Run \(slot.displayName)",
                category: .tools,
                shortcutHint: "⌃⌥\(id == 10 ? "0" : "\(id)")",
                synonyms: ["transform \(id)", "javascript \(id)", slot.name],
                action: { CommandActions.runJSTransform(slotID: id) },
                isEnabled: { JSTransformStore.shared.slot(id: id)?.isConfigured ?? false }
            ))
        }

        // MARK: Markdown wrappers + headings + structural inserts

        commands += [
            .init(id: "mdBold",     title: "Bold (Markdown **…**)",  category: .markdown,
                  shortcutHint: "⌘B", synonyms: ["strong", "bold markdown"],
                  action: CommandActions.markdownBold),
            .init(id: "mdItalic",   title: "Italic (Markdown *…*)",  category: .markdown,
                  shortcutHint: "⌘I", synonyms: ["emphasis", "italic markdown"],
                  action: CommandActions.markdownItalic),
            .init(id: "mdCode",     title: "Inline Code (Markdown `…`)", category: .markdown,
                  shortcutHint: "⌥⌘C", synonyms: ["code span", "monospace"],
                  action: CommandActions.markdownCode),
            .init(id: "mdStrike",   title: "Strikethrough (Markdown ~~…~~)", category: .markdown,
                  shortcutHint: "⇧⌘X", synonyms: ["strike", "del", "crossed out"],
                  action: CommandActions.markdownStrike),
            .init(id: "mdH1",       title: "Heading 1",              category: .markdown,
                  shortcutHint: "⌃⌘1", synonyms: ["h1", "title"],
                  action: { CommandActions.markdownHeader(level: 1) }),
            .init(id: "mdH2",       title: "Heading 2",              category: .markdown,
                  shortcutHint: "⌃⌘2", synonyms: ["h2"],
                  action: { CommandActions.markdownHeader(level: 2) }),
            .init(id: "mdH3",       title: "Heading 3",              category: .markdown,
                  shortcutHint: "⌃⌘3", synonyms: ["h3"],
                  action: { CommandActions.markdownHeader(level: 3) }),
            .init(id: "mdH4",       title: "Heading 4",              category: .markdown,
                  shortcutHint: "⌃⌘4", synonyms: ["h4"],
                  action: { CommandActions.markdownHeader(level: 4) }),
            .init(id: "mdH5",       title: "Heading 5",              category: .markdown,
                  shortcutHint: "⌃⌘5", synonyms: ["h5"],
                  action: { CommandActions.markdownHeader(level: 5) }),
            .init(id: "mdH6",       title: "Heading 6",              category: .markdown,
                  shortcutHint: "⌃⌘6", synonyms: ["h6"],
                  action: { CommandActions.markdownHeader(level: 6) }),
            .init(id: "mdQuote",    title: "Blockquote (Markdown >)", category: .markdown,
                  shortcutHint: "⇧⌘'", synonyms: ["quote", "block quote"],
                  action: CommandActions.markdownBlockquote),
            .init(id: "mdRule",     title: "Horizontal Rule (Markdown ---)", category: .markdown,
                  shortcutHint: "⇧⌘-", synonyms: ["divider", "hr", "line break"],
                  action: CommandActions.markdownHorizontalRule),
            .init(id: "mdLink",     title: "Link… (Markdown [text](url))", category: .markdown,
                  shortcutHint: "⌘K", synonyms: ["hyperlink", "url", "anchor"],
                  action: CommandActions.markdownLink),
            .init(id: "mdImage",    title: "Image… (Markdown ![alt](url))", category: .markdown,
                  shortcutHint: "⌥⌘K", synonyms: ["picture", "img"],
                  action: CommandActions.markdownImage),
            .init(id: "mdFootnote", title: "Insert Footnote",        category: .markdown,
                  shortcutHint: "⌥⌘N", synonyms: ["footnote ref", "[^1]"],
                  action: CommandActions.markdownFootnote)
        ]

        // MARK: Surround Selection presets

        commands += [
            .init(id: "srBold",   title: "Surround with Bold **…**",      category: .text,
                  synonyms: ["wrap bold", "make bold", "strong"],
                  action: { CommandActions.surroundSelection(prefix: "**", suffix: "**") }),
            .init(id: "srItalic", title: "Surround with Italic _…_",      category: .text,
                  synonyms: ["wrap italic", "make italic", "emphasis"],
                  action: { CommandActions.surroundSelection(prefix: "_",  suffix: "_") }),
            .init(id: "srParens", title: "Surround with Parentheses ( )", category: .text,
                  synonyms: ["wrap parens", "wrap parentheses", "round brackets"],
                  action: { CommandActions.surroundSelection(prefix: "(",  suffix: ")") }),
            .init(id: "srBracks", title: "Surround with Brackets [ ]",    category: .text,
                  synonyms: ["wrap brackets", "square brackets"],
                  action: { CommandActions.surroundSelection(prefix: "[",  suffix: "]") }),
            .init(id: "srBraces", title: "Surround with Braces { }",      category: .text,
                  synonyms: ["wrap braces", "curly brackets"],
                  action: { CommandActions.surroundSelection(prefix: "{",  suffix: "}") }),
            .init(id: "srAngles", title: "Surround with Angles < >",      category: .text,
                  synonyms: ["wrap angles", "angle brackets", "tags"],
                  action: { CommandActions.surroundSelection(prefix: "<",  suffix: ">") }),
            .init(id: "srDQuote", title: "Surround with Double Quotes \"\"", category: .text,
                  synonyms: ["wrap double quotes", "quote"],
                  action: { CommandActions.surroundSelection(prefix: "\"", suffix: "\"") }),
            .init(id: "srSQuote", title: "Surround with Single Quotes ''",  category: .text,
                  synonyms: ["wrap single quotes", "apostrophes"],
                  action: { CommandActions.surroundSelection(prefix: "'",  suffix: "'") }),
            .init(id: "srTick",   title: "Surround with Backticks ` `",     category: .text,
                  synonyms: ["wrap backticks", "code"],
                  action: { CommandActions.surroundSelection(prefix: "`",  suffix: "`") })
        ]

        // MARK: Miscellaneous

        commands += [
            .init(id: "joinLines",   title: "Join Lines",            category: .edit,
                  shortcutHint: "⌃J",
                  synonyms: ["merge lines", "concatenate lines", "remove line break"],
                  action: CommandActions.joinLines),
            .init(id: "manageSnippets", title: "Manage Snippets…", category: .snippets,
                  synonyms: ["edit snippets", "add snippet", "delete snippet", "new snippet"],
                  action: CommandActions.presentSnippetsManager,
                  isEnabled: { true }),
            .init(id: "manageTransforms", title: "Manage Transforms…", category: .tools,
                  synonyms: ["edit transforms", "javascript transforms", "js transforms"],
                  action: CommandActions.presentPreferences,
                  isEnabled: { true })
        ]

        // MARK: Navigate

        commands += [
            .init(id: "centerLn",   title: "Center Line",            category: .navigate,
                  synonyms: ["scroll to cursor", "recenter"],
                  action: CommandActions.centerLine)
        ]

        // MARK: Case

        commands += [
            .init(id: "upper",      title: "UPPERCASE",   category: .convertCase, action: CommandActions.uppercase),
            .init(id: "lower",      title: "lowercase",   category: .convertCase, action: CommandActions.lowercase),
            .init(id: "cap",        title: "Capitalized", category: .convertCase, action: CommandActions.capitalize),
            .init(id: "title",      title: "Title Case",  category: .convertCase, action: CommandActions.titleCase),
            .init(id: "snake",      title: "snake_case",  category: .convertCase, action: CommandActions.snakeCase),
            .init(id: "kebab",      title: "kebab-case",  category: .convertCase, action: CommandActions.kebabCase),
            .init(id: "camel",      title: "camelCase",   category: .convertCase, action: CommandActions.camelCase),
            .init(id: "pascal",     title: "PascalCase",  category: .convertCase, action: CommandActions.pascalCase)
        ]

        // MARK: Normalize / encode

        commands += [
            .init(id: "nfc",        title: "Normalize NFC",  category: .unicode,  synonyms: ["precompose unicode", "compose"], action: CommandActions.normalizeNFC),
            .init(id: "nfd",        title: "Normalize NFD",  category: .unicode,  synonyms: ["decompose unicode", "decompose"], action: CommandActions.normalizeNFD),
            .init(id: "nfkc",       title: "Normalize NFKC", category: .unicode,  synonyms: ["compatibility composed"], action: CommandActions.normalizeNFKC),
            .init(id: "nfkd",       title: "Normalize NFKD", category: .unicode,  synonyms: ["compatibility decomposed"], action: CommandActions.normalizeNFKD),
            .init(id: "urlEnc",     title: "URL Encode",     category: .encoding, action: CommandActions.urlEncode),
            .init(id: "urlDec",     title: "URL Decode",     category: .encoding, action: CommandActions.urlDecode),
            .init(id: "b64Enc",     title: "Base64 Encode",  category: .encoding, action: CommandActions.base64Encode),
            .init(id: "b64Dec",     title: "Base64 Decode",  category: .encoding, action: CommandActions.base64Decode)
        ]

        // MARK: Insert

        commands += [
            .init(id: "insDateTime", title: "Insert Date & Time", category: .insert, action: CommandActions.insertDateTime),
            .init(id: "insDate",     title: "Insert Date",        category: .insert, action: CommandActions.insertDate),
            .init(id: "insTime",     title: "Insert Time",        category: .insert, action: CommandActions.insertTime),
            .init(id: "insTab",      title: "Insert Tab",         category: .insert, action: CommandActions.insertTab),
            .init(id: "insNewline",  title: "Insert Newline",     category: .insert, action: CommandActions.insertNewline)
        ]

        // MARK: Sheets

        commands += [
            .init(id: "charInsp",  title: "Character Inspector…",        category: .inspect, shortcutHint: "⌃⌘I", action: { CommandActions.presentSheet(.characterInspector) }),
            .init(id: "encPicker", title: "Text Encoding…",              category: .format,  action: { CommandActions.presentSheet(.encodingPicker) }),
            .init(id: "lePicker",  title: "Line Endings…",               category: .format,  action: { CommandActions.presentSheet(.lineEndingPicker) }),
            .init(id: "langPicker", title: "Syntax Language…",           category: .format,  action: { CommandActions.presentSheet(.languagePicker) })
        ]

        // MARK: View — font size

        commands += [
            .init(id: "fontBigger", title: "Bigger Font",     category: .view, shortcutHint: "⌘+", action: CommandActions.increaseFontSize),
            .init(id: "fontSmall",  title: "Smaller Font",    category: .view, shortcutHint: "⌘-", action: CommandActions.decreaseFontSize),
            .init(id: "fontReset",  title: "Reset Font Size", category: .view, shortcutHint: "⌘0", action: CommandActions.resetFontSize)
        ]

        // MARK: View — toggles

        commands += [
            .init(id: "toggleLN",   title: "Toggle Show Line Numbers",                category: .view, shortcutHint: "⇧⌘L", synonyms: ["line numbers", "gutter numbers"],             action: CommandActions.toggleShowLineNumbers,         isEnabled: { true }),
            .init(id: "toggleWrap", title: "Toggle Wrap Lines",                       category: .view, shortcutHint: "⌥⌘W", synonyms: ["soft wrap", "word wrap"],                     action: CommandActions.toggleWrapLines,                isEnabled: { true }),
            .init(id: "toggleInv",  title: "Toggle Show Invisibles",                  category: .view, shortcutHint: "⇧⌘I", synonyms: ["show whitespace", "show hidden characters"],  action: CommandActions.toggleShowInvisibles,           isEnabled: { true }),
            .init(id: "togglePG",   title: "Toggle Show Page Guide",                  category: .view, synonyms: ["margin guide", "ruler line", "column guide"],                       action: CommandActions.toggleShowPageGuide,            isEnabled: { true }),
            .init(id: "toggleSB",   title: "Toggle Show Status Bar",                  category: .view, synonyms: ["hide status bar"],                                                 action: CommandActions.toggleShowStatusBar,            isEnabled: { true }),
            .init(id: "toggleTB",   title: "Toggle Show Toolbar",                     category: .view, synonyms: ["hide toolbar", "toggle pill"],                                    action: CommandActions.toggleShowToolbar,              isEnabled: { true }),
            .init(id: "toggleLive", title: "Toggle Highlight All Occurrences",        category: .view, synonyms: ["live match highlight", "highlight selection"],                    action: CommandActions.toggleLiveMatchHighlight,       isEnabled: { true }),
            .init(id: "toggleCL",   title: "Toggle Highlight Current Line",           category: .view, synonyms: ["current line highlight"],                                          action: CommandActions.toggleHighlightCurrentLine,     isEnabled: { true }),
            .init(id: "toggleBK",   title: "Toggle Highlight Matching Brackets",      category: .view, synonyms: ["match brackets", "matching parens"],                              action: CommandActions.toggleHighlightMatchingBrackets, isEnabled: { true }),
            .init(id: "toggleCH",   title: "Toggle Show Change History in Gutter",   category: .view, synonyms: ["change bars", "modified lines", "diff bars", "unsaved changes gutter"], action: CommandActions.toggleShowChangeHistoryGutter,  isEnabled: { true })
        ]

        // MARK: Folding

        commands += [
            .init(id: "foldCur",    title: "Fold at Cursor", category: .fold, shortcutHint: "⌃⌘F", synonyms: ["collapse here", "fold section"], action: CommandActions.toggleFoldAtCursor),
            .init(id: "foldAll",    title: "Fold All",       category: .fold, shortcutHint: "⌥⌘[", synonyms: ["collapse all"],                  action: CommandActions.foldAll),
            .init(id: "unfoldAll",  title: "Unfold All",     category: .fold, shortcutHint: "⌥⌘]", synonyms: ["expand all", "uncollapse all"], action: CommandActions.unfoldAll),
            .init(id: "clearFolds", title: "Clear Manual Fold Points", category: .fold, synonyms: ["remove fold selection markers", "reset manual folds", "drop ad-hoc folds"], action: CommandActions.clearManualFolds)
        ]

        // MARK: Languages (each as a command)

        for language in LanguageRegistry.all {
            commands.append(.init(
                id: "lang.\(language.identifier)",
                title: "Set Syntax: \(language.displayName)",
                category: .language,
                action: { CommandActions.setLanguage(language.identifier) }
            ))
        }

        // MARK: Line endings (each as a command)

        for lineEnding in LineEnding.allCases {
            commands.append(.init(
                id: "le.\(lineEnding.label)",
                title: "Set Line Ending: \(lineEnding.label) (\(lineEnding.description))",
                category: .lineEndings,
                action: { CommandActions.applyLineEnding(lineEnding) }
            ))
        }

        // MARK: Speech

        commands += [
            .init(id: "speak",      title: "Speak Selection",   category: .speech,
                  synonyms: ["read aloud", "tts", "say"],       action: CommandActions.speakSelection),
            .init(id: "stopSpeak",  title: "Stop Speaking",     category: .speech,
                  synonyms: ["shut up", "silence"],             action: CommandActions.stopSpeaking)
        ]

        // MARK: Spell check

        commands += [
            .init(id: "spellSheet",    title: "Check Spelling…",              category: .spelling, synonyms: ["spell check", "walk through spelling", "spelling dialog", "word spell check"], action: CommandActions.presentSpellCheckSheet),
            .init(id: "spellCheckAll", title: "Highlight All Misspellings",   category: .spelling, synonyms: ["spell check document", "highlight misspellings", "audit spelling", "manual spell check"], action: CommandActions.highlightAllMisspellings),
            .init(id: "spellClear",    title: "Clear Spelling Marks",         category: .spelling, synonyms: ["remove spelling highlights", "clear misspelling highlights"], action: CommandActions.clearMisspellingHighlights),
            .init(id: "spellNext",     title: "Find Next Misspelling",        category: .spelling, synonyms: ["next typo"], action: CommandActions.jumpToNextMisspelling),
            .init(id: "spellLearn",    title: "Learn Spelling of Word",       category: .spelling, synonyms: ["add to dictionary", "remember word"], action: CommandActions.learnSelectedWord),
            .init(id: "spellIgnore",   title: "Ignore Spelling for Word",     category: .spelling, synonyms: ["skip word", "ignore this word"], action: CommandActions.ignoreSelectedWord),
            .init(id: "spellLive",     title: "Toggle Live Spell Check",      category: .spelling, synonyms: ["check spelling while typing", "spelling underline"], action: CommandActions.toggleSpellCheckLive)
        ]

        // MARK: Bookmarks
        //
        // Sunk to the end so the palette's empty-query list isn't
        // led by 20 numbered entries.

        for slot in 0..<10 {
            commands.append(.init(id: "bkSet.\(slot)",   title: "Set Bookmark \(slot)",     category: .bookmark, shortcutHint: "⌃⇧\(slot)", action: { CommandActions.setBookmark(slot) }))
            commands.append(.init(id: "bkJump.\(slot)",  title: "Jump to Bookmark \(slot)", category: .bookmark, shortcutHint: "⌃\(slot)", action: { CommandActions.jumpToBookmark(slot) }))
        }

        return commands
    }
}

/// Subsequence fuzzy match: every character of `query` must appear
/// in `target` in order (case-insensitive). Returns a relevance score;
/// higher is better. Score components: matches at word starts,
/// consecutive matches, and a length tiebreaker.
enum FuzzyMatcher {

    /// Per-hit weights for the score. Kept here as named constants
    /// rather than scattered through the loop so the relative ranking
    /// is legible.
    private enum Weight {
        static let perMatch        = 10
        static let wordBoundary    = 8
        static let consecutive     = 5
        static let titleBonus      = 1000
        static let synonymBonus    = 300
        static let categoryBonus   = 150
        static let descriptionBonus = 50
    }

    /// Score `query` against a pre-lowercased target. Returns `nil`
    /// when the query characters can't all be found in order.
    /// `target` is `[Character]` so callers can pre-build the array
    /// once at registry-build time and reuse it across keystrokes.
    static func match(_ query: [Character], in target: [Character]) -> Int? {
        guard !query.isEmpty else { return 1 }
        var qi = 0
        var score = 0
        var lastMatchPos = -2
        for idx in target.indices {
            let char = target[idx]
            let prev = idx > 0 ? target[idx - 1] : nil
            let isBoundary = (idx == 0) || (prev.map { !$0.isLetter && !$0.isNumber } ?? true)
            if qi < query.count, query[qi] == char {
                score += Weight.perMatch
                if isBoundary { score += Weight.wordBoundary }
                if idx == lastMatchPos + 1 { score += Weight.consecutive }
                lastMatchPos = idx
                qi += 1
            }
        }
        guard qi == query.count else { return nil }
        score -= target.count / 10
        return score
    }

    /// Score a command against `query`, taking the best of its title,
    /// synonyms, category, and description. Title hits get the highest
    /// weight, then synonyms, then category, then description — so a
    /// typo-tolerant match on the literal title still ranks above an
    /// exact match buried in a long help blurb.
    static func bestScore(_ query: String, against command: EditorCommandSpec) -> Int? {
        guard !query.isEmpty else { return 1 }
        let q = Array(query.lowercased())
        var best: Int?

        if let s = match(q, in: command.titleChars) {
            best = max(best ?? .min, s + Weight.titleBonus)
        }
        for synonymChars in command.synonymChars {
            if let s = match(q, in: synonymChars) {
                best = max(best ?? .min, s + Weight.synonymBonus)
            }
        }
        if let s = match(q, in: command.categoryChars) {
            best = max(best ?? .min, s + Weight.categoryBonus)
        }
        if let descriptionChars = command.descriptionChars,
           let s = match(q, in: descriptionChars) {
            best = max(best ?? .min, s + Weight.descriptionBonus)
        }
        return best
    }
}
