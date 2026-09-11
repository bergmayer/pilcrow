import SwiftUI
import UIKit
import FileEncoding
import LineEnding
import LineSort

/// iPadOS menu wiring. Every Button routes through `CommandActions`
/// so the palette shares the same code.
struct EditorCommands: Commands {

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.openWindow) private var openWindow
    @State private var snippetsStore = SnippetsStore.shared
    @State private var jsTransformStore = JSTransformStore.shared
    @State private var recentFilesStore = RecentFilesStore.shared
    @FocusedValue(\.focusedSession) private var focusedSession: EditorSession?

    private var editorState: EditorState? {
        guard let focusedSession else { return bus.scenes.currentEditor }
        return focusedSession.activeTab.owns(bus.scenes.currentEditor)
            ? bus.scenes.currentEditor : focusedSession.activeTab.state
    }
    private var isEnabled: Bool { editorState != nil }

    /// iPad Stage Manager / Split View can leave the bus's
    /// `currentEditor` lagging real focus; re-sync before every
    /// action so commands land in the visible window.
    private func claimFocus() {
        guard let session = focusedSession else { return }
        AppStateBus.shared.scenes.claimFocus(session: session)
    }

    private func presentSheet(_ sheet: EditorSheet) {
        claimFocus()
        bus.presentation.present(sheet, owner: editorState)
    }

    private func focused(_ action: @escaping @MainActor () -> Void) -> () -> Void {
        {
            claimFocus()
            action()
        }
    }

    private func focused(_ action: () -> Void) {
        claimFocus()
        action()
    }

    var body: some Commands {

        // System text-formatting claims ⌘B / ⌘I and would drop our
        // Markdown menu via `_UIMenuBuilderError`.
        CommandGroup(replacing: .textFormatting) { }

        // MARK: App — Preferences, Command Palette

        // Grouped: body is at the 10-child cap.
        //
        // Icons on every item: iPadOS injects iconned items (Settings,
        // About) into the app menu, so leaving ours bare would look
        // inconsistent. Same rule applies to every other menu below.
        Group {
            CommandGroup(replacing: .appSettings) {
                Button(action: { openWindow(id: SceneID.preferences.rawValue) }) {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(AppShortcut.preferences)
            }
            CommandGroup(after: .appInfo) {
                Button(action: { presentSheet(.commandPalette) }) {
                    Label("Command Palette…", systemImage: "command")
                }
                .keyboardShortcut(AppShortcut.commandPalette)
                // ⌃P alias is wired in-window via PaletteShortcutAlias
                // (see EditorScene) rather than as a second menu entry,
                // so the menu shows one canonical row.
            }
        }

        // MARK: File — New (new scene) / Open / Save / Save As

        CommandGroup(replacing: .newItem) {
            if DeviceIdiom.supportsMultipleWindows {
                Button(action: { openWindow(id: SceneID.editor.rawValue, value: EditorRoute.newDocument()) }) {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                }
                .keyboardShortcut(AppShortcut.newWindow)
            }
            // No `.disabled(...)`: SwiftUI evaluates the expression
            // at menu-build time; a transient nil session during a
            // scene swap would grey the item indefinitely.
            Button(action: {
                if let session = focusedSession ?? AppStateBus.shared.scenes.currentSession {
                    session.newTab()
                } else {
                    openWindow(id: SceneID.editor.rawValue, value: EditorRoute.newDocument())
                }
            }) {
                Label("New Tab", systemImage: "rectangle.stack.badge.plus")
            }
            .keyboardShortcut(AppShortcut.newTab)
            Button(action: focused(CommandActions.newFromTemplate)) {
                Label("New from Template…", systemImage: "doc.badge.plus")
            }
            // Unshortcut'd: `LSSupportsOpeningDocumentsInPlace = YES`
            // makes iPadOS auto-inject its own ⌘O "Open…" at the
            // system level (action `open:`); binding ours to the
            // same chord triggers `_UIMenuBuilderError` and silently
            // drops the entire `.newItem` replacement, taking New
            // Window and New Tab with it.
            Button(action: {
                claimFocus()
                if DeviceIdiom.supportsMultipleWindows {
                    CommandActions.presentFileBrowserInNewWindow()
                } else {
                    CommandActions.presentFileBrowserInNewTab()
                }
            }) {
                Label(
                    DeviceIdiom.supportsMultipleWindows ? "Open…" : "Open in New Tab…",
                    systemImage: "folder"
                )
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Share Text…", action: focused(CommandActions.shareText)).disabled(!isEnabled)
            Button("Share File…", action: focused(CommandActions.shareFile)).disabled(!isEnabled)
            Button("Print…", action: focused(CommandActions.printDocument))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!isEnabled)
            Divider()
            Button(action: focused(CommandActions.saveFile)) {
                Label("Save", systemImage: "tray.and.arrow.down")
            }
            .keyboardShortcut(AppShortcut.save)
            .disabled(!isEnabled)
            Button(action: { focused { AppStateBus.shared.pickers.pending = .saveAs } }) {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut(AppShortcut.saveAs)
            .disabled(!isEnabled)
            Divider()
            Button(action: { focused { AppStateBus.shared.presentation.revertRequestCount += 1 } }) {
                Label("Revert to Saved", systemImage: "arrow.uturn.backward")
            }
            .disabled(!isEnabled)
            Button(action: { presentSheet(.revisions) }) {
                Label("Show Revisions…", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut(AppShortcut.showRevisions)
            .disabled(!isEnabled)
            Divider()
            Button(action: focused(CommandActions.speakSelection)) {
                Label("Speak Selection", systemImage: "speaker.wave.2")
            }
            .disabled(!isEnabled)
        }

        // MARK: Edit — selection submenu + character-level edits

        CommandGroup(after: .pasteboard) {
            Divider()

            Button(action: { presentSheet(.clipboardHistory) }) {
                Label("Clipboard History…", systemImage: "list.clipboard")
            }
            .keyboardShortcut(AppShortcut.clipboardHistory)

            Divider()

            Menu {
                Button(action: focused(CommandActions.selectCurrentWord)) {
                    Label("Select Word", systemImage: "character.cursor.ibeam")
                }
                Button(action: focused(CommandActions.selectCurrentLine)) {
                    Label("Select Line", systemImage: "text.cursor")
                }
                Button(action: { presentSheet(.selectLinesContaining) }) {
                    Label("Select Lines Containing…", systemImage: "line.horizontal.3.decrease.circle")
                }
                Divider()
                Button(action: focused(CommandActions.smartMoveToLineStart)) {
                    Label("Smart Move to Line Start", systemImage: "arrow.left.to.line")
                }
            } label: {
                Label("Selection", systemImage: "selection.pin.in.out")
            }
            .disabled(!isEnabled)

            Divider()

            Button(action: focused(CommandActions.transposeCharacters)) {
                Label("Transpose Characters", systemImage: "arrow.left.arrow.right")
            }
            .keyboardShortcut(AppShortcut.transposeChars)
            .disabled(!isEnabled)
            Button(action: focused(CommandActions.deleteToEndOfLine)) {
                Label("Delete to End of Line", systemImage: "delete.right")
            }
            .keyboardShortcut(AppShortcut.deleteToEOL)
            .disabled(!isEnabled)
            Button(action: focused(CommandActions.deleteWordBackward)) {
                Label("Delete Word Backward", systemImage: "delete.left")
            }
            .keyboardShortcut(AppShortcut.deleteWordBack)
            .disabled(!isEnabled)
            Button(action: focused(CommandActions.deleteWordForward)) {
                Label("Delete Word Forward", systemImage: "delete.right")
            }
            .keyboardShortcut(AppShortcut.deleteWordFwd)
            .disabled(!isEnabled)
            Button(action: focused(CommandActions.joinLines)) {
                Label("Join Lines", systemImage: "rectangle.compress.vertical")
            }
            .keyboardShortcut(AppShortcut.joinLines)
            .disabled(!isEnabled)

            Divider()

            Menu {
                Button(action: { presentSheet(.spellCheck) }) {
                    Label("Check Spelling…", systemImage: "checkmark.circle")
                }
                Divider()
                Button(action: focused(CommandActions.jumpToNextMisspelling)) {
                    Label("Find Next Misspelling", systemImage: "arrow.right.circle")
                }
                Button(action: focused(CommandActions.learnSelectedWord)) {
                    Label("Learn Spelling of Word", systemImage: "book")
                }
                Button(action: focused(CommandActions.ignoreSelectedWord)) {
                    Label("Ignore Spelling for Word", systemImage: "eye.slash")
                }
                Divider()
                Button(action: focused(CommandActions.highlightAllMisspellings)) {
                    Label("Highlight All Misspellings", systemImage: "highlighter")
                }
                Button(action: focused(CommandActions.clearMisspellingHighlights)) {
                    Label("Clear Spelling Marks", systemImage: "eraser")
                }
                Divider()
                Button(action: focused(CommandActions.toggleSpellCheckLive)) {
                    Label("Toggle Live Spell Check", systemImage: "textformat.abc.dottedunderline")
                }
            } label: {
                Label("Spelling", systemImage: "abc")
            }
            .disabled(!isEnabled)
        }

        // MARK: Search
        CommandMenu("Search") {
            findSubmenuContent
        }

        // MARK: View — append to iPadOS's auto-injected View menu.
        //
        // `CommandMenu("View")` would collide with the system title
        // and lose. `CommandGroup(replacing: .toolbar)` buries items
        // inside a Toolbar submenu. `CommandGroup(after: .sidebar)`
        // lands at the View menu's top level, which is where the
        // user looks.
        //
        // System Show Sidebar drives UIKit's sidebar API; our
        // outline reads `state.sidebarOpen`, so we replace.
        CommandGroup(replacing: .sidebar) {
            Button(action: focused(CommandActions.showOutline)) {
                Label("Show Outline", systemImage: "sidebar.left")
            }
            .keyboardShortcut(AppShortcut.showOutline)
            .disabled(!isEnabled)
        }
        CommandGroup(after: .sidebar) {
            viewMenuFontItems
            Divider()
            viewMenuToggleItems
            Divider()
            viewMenuFoldItems
            Divider()
            viewMenuTailItems
        }

        // MARK: Text — line operations + content transforms

        CommandMenu("Text") {
            Group {
                Menu("Surround Selection") {
                    Button("Bold **…**")       { focused { CommandActions.surroundSelection(prefix: "**", suffix: "**") } }
                    Button("Italic _…_")       { focused { CommandActions.surroundSelection(prefix: "_",  suffix: "_") } }
                    Divider()
                    Button("Parentheses ( )") { focused { CommandActions.surroundSelection(prefix: "(",  suffix: ")") } }
                    Button("Brackets [ ]")    { focused { CommandActions.surroundSelection(prefix: "[",  suffix: "]") } }
                    Button("Braces { }")      { focused { CommandActions.surroundSelection(prefix: "{",  suffix: "}") } }
                    Button("Angles < >")      { focused { CommandActions.surroundSelection(prefix: "<",  suffix: ">") } }
                    Divider()
                    Button("Double Quotes \"\"") { focused { CommandActions.surroundSelection(prefix: "\"", suffix: "\"") } }
                    Button("Single Quotes ''")   { focused { CommandActions.surroundSelection(prefix: "'",  suffix: "'") } }
                    Button("Backticks ``")       { focused { CommandActions.surroundSelection(prefix: "`",  suffix: "`") } }
                }

                Divider()

                Menu("Lines") {
                    Button("Move Line Up", action: focused(CommandActions.moveLineUp))
                        .keyboardShortcut(AppShortcut.moveLineUp)
                    Button("Move Line Down", action: focused(CommandActions.moveLineDown))
                        .keyboardShortcut(AppShortcut.moveLineDown)
                    Button("Duplicate Line", action: focused(CommandActions.duplicateLine))
                        .keyboardShortcut(AppShortcut.duplicateLine)
                    Button("Delete Line", action: focused(CommandActions.deleteLine))
                        .keyboardShortcut(AppShortcut.deleteLine)
                    Divider()
                    Button("Sort Lines…", action: focused(CommandActions.sortLines))
                    Button("Reverse Lines", action: focused(CommandActions.reverseLines))
                    Button("Unique Lines", action: focused(CommandActions.uniqueLines))
                    Button("Remove Blank Lines", action: focused(CommandActions.removeBlankLines))
                    Divider()
                    Button("Add Linebreaks", action: focused(CommandActions.addLinebreaks))
                    Button("Remove Linebreaks", action: focused(CommandActions.removeLinebreaks))
                    Divider()
                    Button("Add Line Numbers", action: focused(CommandActions.addLineNumbers))
                    Button("Remove Line Numbers", action: focused(CommandActions.removeLineNumbers))
                    Button("Prefix / Suffix Lines…", action: focused(CommandActions.presentPrefixSuffixLines))
                    Divider()
                    Button("Process Lines Containing…", action: focused(CommandActions.presentProcessLines))
                }

                Menu("Transform") {
                    Button("UPPERCASE", action: focused(CommandActions.uppercase))
                    Button("lowercase", action: focused(CommandActions.lowercase))
                    Button("Capitalized", action: focused(CommandActions.capitalize))
                    Button("Title Case", action: focused(CommandActions.titleCase))
                    Divider()
                    Button("snake_case", action: focused(CommandActions.snakeCase))
                    Button("kebab-case", action: focused(CommandActions.kebabCase))
                    Button("camelCase", action: focused(CommandActions.camelCase))
                    Button("PascalCase", action: focused(CommandActions.pascalCase))
                    Divider()
                    Menu("Normalize Unicode") {
                        Button("NFC — Canonical Composed", action: focused(CommandActions.normalizeNFC))
                        Button("NFD — Canonical Decomposed", action: focused(CommandActions.normalizeNFD))
                        Button("NFKC — Compatibility Composed", action: focused(CommandActions.normalizeNFKC))
                        Button("NFKD — Compatibility Decomposed", action: focused(CommandActions.normalizeNFKD))
                    }
                    Menu("Encode / Decode") {
                        Button("URL Encode", action: focused(CommandActions.urlEncode))
                        Button("URL Decode", action: focused(CommandActions.urlDecode))
                        Divider()
                        Button("Base64 Encode", action: focused(CommandActions.base64Encode))
                        Button("Base64 Decode", action: focused(CommandActions.base64Decode))
                    }
                    Divider()
                    Button("Reverse Selection", action: focused(CommandActions.reverseSelection))
                }

                Menu("Cleanup") {
                    Menu("Whitespace") {
                        Button("Trim Trailing Whitespace", action: focused(CommandActions.trimTrailingWhitespace))
                        Divider()
                        Button("Normalize Spaces", action: focused(CommandActions.normalizeSpaces))
                        Button("Convert Tabs to Spaces", action: focused(CommandActions.tabsToSpaces))
                        Button("Convert Spaces to Tabs", action: focused(CommandActions.spacesToTabs))
                        Button("Normalize Line Endings", action: focused(CommandActions.normalizeLineEndingsToDocument))
                    }
                    Menu("Quotes & Escapes") {
                        Button("Educate Quotes", action: focused(CommandActions.educateQuotes))
                        Button("Straighten Quotes", action: focused(CommandActions.straightenQuotes))
                        Divider()
                        Button("Interpret Escape Sequences", action: focused(CommandActions.interpretEscapeSequences))
                        Button("Escape Special Characters", action: focused(CommandActions.escapeSpecialCharacters))
                    }
                    Divider()
                    Button("Zap Gremlins…", action: focused(CommandActions.presentZapGremlins))
                    Button("Strip Diacritics", action: focused(CommandActions.stripDiacritics))
                    Button("Convert to ASCII", action: focused(CommandActions.convertToASCII))
                    Divider()
                    Button("Canonize…", action: focused(CommandActions.presentCanonize))
                }

                Divider()

                Menu("Insert") {
                    Button("Date & Time", action: focused(CommandActions.insertDateTime))
                    Button("Date", action: focused(CommandActions.insertDate))
                    Button("Time", action: focused(CommandActions.insertTime))
                    Divider()
                    Button("Tab", action: focused(CommandActions.insertTab))
                    Button("Newline", action: focused(CommandActions.insertNewline))
                    Divider()
                    Button("File Contents…", action: focused(CommandActions.presentInsertFileContents))
                    Button("Folder Listing…", action: focused(CommandActions.presentInsertFolderListing))
                    Button("Lorem Ipsum…", action: focused(CommandActions.presentInsertLoremIpsum))
                }

                Menu("Snippets") {
                    snippetItems
                }

                Menu("JavaScript Transforms") {
                    jsTransformItems
                }

                Menu("Markdown") { markdownSubmenuContent }
            }
            .disabled(!isEnabled)
        }

        // MARK: Tabs (attached to the system Window menu)

        CommandGroup(after: .windowArrangement) {
            Button(action: focused(CommandActions.showTabSwitcher)) {
                Label("Show All Tabs", systemImage: "rectangle.grid.2x2")
            }
            .keyboardShortcut(AppShortcut.showAllTabs)
            Button(action: focused(CommandActions.closeActiveTab)) {
                Label("Close Tab", systemImage: "xmark.square")
            }
            .keyboardShortcut(AppShortcut.closeTab)
            if DeviceIdiom.supportsMultipleWindows {
                Button(action: focused { CommandActions.closeWindow() }) {
                    Label("Close Window", systemImage: "macwindow")
                }
                .keyboardShortcut(AppShortcut.closeWindow)
                Button(action: focused { CommandActions.saveAllAndCloseWindow() }) {
                    Label("Save All and Close Window", systemImage: "square.and.arrow.down")
                }
            }
            Button(action: focused(CommandActions.reopenLastClosedTab)) {
                Label("Reopen Last Closed Tab", systemImage: "arrow.uturn.backward.square")
            }
            .keyboardShortcut(AppShortcut.reopenLastClosed)
            Divider()
            Button(action: focused(CommandActions.nextTab)) {
                Label("Next Tab", systemImage: "arrow.right.square")
            }
            .keyboardShortcut(AppShortcut.nextTab)
            Button(action: focused(CommandActions.previousTab)) {
                Label("Previous Tab", systemImage: "arrow.left.square")
            }
            .keyboardShortcut(AppShortcut.previousTab)
            Divider()
            Button(action: focused(CommandActions.pinCurrentTab)) {
                Label("Pin / Unpin Tab", systemImage: "pin")
            }
            Button(action: focused(CommandActions.closeOtherTabs)) {
                Label("Close Other Tabs", systemImage: "rectangle.stack.badge.minus")
            }
            Button(action: focused(CommandActions.closeTabsToRight)) {
                Label("Close Tabs to the Right", systemImage: "arrow.right.to.line")
            }
            Divider()
            Menu {
                Button { focused { CommandActions.selectTab(at: 1) } } label: {
                    Label("Tab 1", systemImage: "1.square")
                }.keyboardShortcut("1")
                Button { focused { CommandActions.selectTab(at: 2) } } label: {
                    Label("Tab 2", systemImage: "2.square")
                }.keyboardShortcut("2")
                Button { focused { CommandActions.selectTab(at: 3) } } label: {
                    Label("Tab 3", systemImage: "3.square")
                }.keyboardShortcut("3")
                Button { focused { CommandActions.selectTab(at: 4) } } label: {
                    Label("Tab 4", systemImage: "4.square")
                }.keyboardShortcut("4")
                Button { focused { CommandActions.selectTab(at: 5) } } label: {
                    Label("Tab 5", systemImage: "5.square")
                }.keyboardShortcut("5")
                Button { focused { CommandActions.selectTab(at: 6) } } label: {
                    Label("Tab 6", systemImage: "6.square")
                }.keyboardShortcut("6")
                Button { focused { CommandActions.selectTab(at: 7) } } label: {
                    Label("Tab 7", systemImage: "7.square")
                }.keyboardShortcut("7")
                Button { focused { CommandActions.selectTab(at: 8) } } label: {
                    Label("Tab 8", systemImage: "8.square")
                }.keyboardShortcut("8")
                Button { focused { CommandActions.selectTab(at: 9) } } label: {
                    Label("Last Tab", systemImage: "9.square")
                }.keyboardShortcut("9")
            } label: {
                Label("Jump to Tab", systemImage: "arrow.right.to.line.circle")
            }
        }
    }

    // MARK: - Submenus

    @ViewBuilder
    private var formatSubmenuContent: some View {
        Group {
            Button("Toggle Line Comment", action: focused(CommandActions.toggleLineComment))
                .keyboardShortcut("/", modifiers: .command)
                .disabled(LanguageRegistry.lineComment(for: editorState?.languageIdentifier ?? .plain).isEmpty)
            Menu("File Encoding")        { encodingMenuItems }
            Menu("Reopen with Encoding") { reopenWithEncodingMenuItems }
            Menu("Line Endings")         { lineEndingMenuItems }

            Divider()

            Menu("Syntax Style") { syntaxLanguageMenuItems }

            Divider()

            Menu("Indent") { indentMenuItems }
            Button("Indent Selection", action: focused(CommandActions.indentSelection))
                .keyboardShortcut(AppShortcut.indentSelection)
            Button("Outdent Selection", action: focused(CommandActions.outdentSelection))
                .keyboardShortcut(AppShortcut.outdentSelection)
        }
        Divider()
        Group {
            Menu("Convert to List") {
                // Distinct titles from the Markdown ▸ List submenu —
                // UIKit derives UIAction identifiers from the title,
                // and duplicates make iPadOS drop the whole owning
                // menu via `_UIMenuBuilderError`.
                Button("Format as Dash List", action: focused(CommandActions.convertToBulletListDash))
                Button("Format as Asterisk List", action: focused(CommandActions.convertToBulletListStar))
                Button("Format as Numbered List", action: focused(CommandActions.convertToNumberedList))
            }

        }
    }

    @ViewBuilder
    private var viewMenuFontItems: some View {
        Button(action: focused(CommandActions.increaseFontSize)) {
            Label("Bigger Font", systemImage: "plus.magnifyingglass")
        }
        .keyboardShortcut(AppShortcut.biggerFont)
        .disabled(!isEnabled)
        Button(action: focused(CommandActions.decreaseFontSize)) {
            Label("Smaller Font", systemImage: "minus.magnifyingglass")
        }
        .keyboardShortcut(AppShortcut.smallerFont)
        .disabled(!isEnabled)
        Button(action: focused(CommandActions.resetFontSize)) {
            Label("Reset Font Size", systemImage: "textformat.size")
        }
        .keyboardShortcut(AppShortcut.resetFontSize)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuToggleItems: some View {
        Toggle(isOn: bindingFor(\.showLineNumbers, defaultsKey: AppPreferenceKey.showLineNumbers)) {
            Label("Show Line Numbers", systemImage: "list.number")
        }
        .keyboardShortcut(AppShortcut.showLineNumbers)
        .disabled(!isEnabled)
        Toggle(isOn: bindingFor(\.wrapLines, defaultsKey: AppPreferenceKey.wrapLines)) {
            Label("Wrap Lines", systemImage: "arrow.turn.down.left")
        }
        .keyboardShortcut(AppShortcut.wrapLines)
        .disabled(!isEnabled)
        Toggle(isOn: bindingFor(\.showInvisibles, defaultsKey: AppPreferenceKey.showInvisibles)) {
            Label("Show Invisibles", systemImage: "eye")
        }
        .keyboardShortcut(AppShortcut.showInvisibles)
        .disabled(!isEnabled)
        Toggle(isOn: bindingFor(\.showPageGuide, defaultsKey: AppPreferenceKey.showPageGuide)) {
            Label("Show Page Guide", systemImage: "ruler")
        }
        .disabled(!isEnabled)
        Toggle(isOn: bindingFor(\.showStatusBar, defaultsKey: AppPreferenceKey.showStatusBar)) {
            Label("Show Status Bar", systemImage: "rectangle.bottomthird.inset.filled")
        }
        .disabled(!isEnabled)
        Toggle(isOn: bindingFor(\.showToolbar, defaultsKey: AppPreferenceKey.showToolbar)) {
            Label("Show Toolbar", systemImage: "rectangle.topthird.inset.filled")
        }
        .disabled(!isEnabled)
        Toggle(isOn: bindingFor(\.liveMatchHighlight, defaultsKey: AppPreferenceKey.liveMatchHighlight)) {
            Label("Highlight All Occurrences of Selection", systemImage: "highlighter")
        }
        .disabled(!isEnabled)
        Toggle(isOn: bindingFor(\.showChangeHistoryGutter, defaultsKey: AppPreferenceKey.showChangeHistoryGutter)) {
            Label("Show Change History in Gutter", systemImage: "clock")
        }
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuFoldItems: some View {
        Button(action: focused(CommandActions.toggleFoldAtCursor)) {
            Label("Fold at Cursor", systemImage: "chevron.down.square")
        }
        .keyboardShortcut(AppShortcut.foldAtCursor)
        .disabled(!isEnabled)
        Button(action: focused(CommandActions.foldSelection)) {
            Label("Fold Selection", systemImage: "rectangle.compress.vertical")
        }
        .keyboardShortcut(AppShortcut.foldSelectionBlock)
        .disabled(!isEnabled)
        Button(action: focused(CommandActions.foldAll)) {
            Label("Fold All", systemImage: "arrow.down.to.line.compact")
        }
        .keyboardShortcut(AppShortcut.foldAll)
        .disabled(!isEnabled)
        Button(action: focused(CommandActions.unfoldAll)) {
            Label("Unfold All", systemImage: "arrow.up.to.line.compact")
        }
        .keyboardShortcut(AppShortcut.unfoldAll)
        .disabled(!isEnabled)
        Button(action: focused(CommandActions.clearManualFolds)) {
            Label("Clear Manual Fold Points", systemImage: "trash")
        }
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuTailItems: some View {
        Button(action: focused(CommandActions.cycleSplitView)) {
            Label("Cycle Split View", systemImage: "rectangle.split.2x1")
        }
        .keyboardShortcut(AppShortcut.cycleSplitView)
        .disabled(!isEnabled)
        Divider()
        Button(action: focused(CommandActions.toggleInspector)) {
            Label("Show File Information", systemImage: "info.circle")
        }
        .keyboardShortcut(AppShortcut.showFileInfo)
        .disabled(!isEnabled)
        Button(action: focused { presentSheet(.characterInspector) }) {
            Label("Character Inspector…", systemImage: "character.magnify")
        }
        .keyboardShortcut(AppShortcut.characterInspector)
        .disabled(!isEnabled)
        Divider()
        Menu {
            bookmarkMenuItems
        } label: {
            Label("Bookmarks", systemImage: "bookmark")
        }
        .disabled(!isEnabled)
        Divider()
        Menu {
            formatSubmenuContent
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var markdownSubmenuContent: some View {
        Group {
            Button("Bold", action: focused(CommandActions.markdownBold))
                .keyboardShortcut(AppShortcut.markdownBold)
            Button("Italic", action: focused(CommandActions.markdownItalic))
                .keyboardShortcut(AppShortcut.markdownItalic)
            Button("Inline Code", action: focused(CommandActions.markdownCode))
                .keyboardShortcut(AppShortcut.markdownCode)
            Button("Strikethrough", action: focused(CommandActions.markdownStrike))
                .keyboardShortcut(AppShortcut.markdownStrike)
            Divider()
            Menu("Heading") {
                Button("Heading 1") { focused { CommandActions.markdownHeader(level: 1) } }
                    .keyboardShortcut(AppShortcut.markdownHeading1)
                Button("Heading 2") { focused { CommandActions.markdownHeader(level: 2) } }
                    .keyboardShortcut(AppShortcut.markdownHeading2)
                Button("Heading 3") { focused { CommandActions.markdownHeader(level: 3) } }
                    .keyboardShortcut(AppShortcut.markdownHeading3)
                Button("Heading 4") { focused { CommandActions.markdownHeader(level: 4) } }
                    .keyboardShortcut(AppShortcut.markdownHeading4)
                Button("Heading 5") { focused { CommandActions.markdownHeader(level: 5) } }
                    .keyboardShortcut(AppShortcut.markdownHeading5)
                Button("Heading 6") { focused { CommandActions.markdownHeader(level: 6) } }
                    .keyboardShortcut(AppShortcut.markdownHeading6)
            }
            Menu("List") {
                Button("Bullet List (- )", action: focused(CommandActions.convertToBulletListDash))
                Button("Bullet List (* )", action: focused(CommandActions.convertToBulletListStar))
                Button("Numbered List", action: focused(CommandActions.convertToNumberedList))
            }
        }
        Divider()
        Group {
            Button("Blockquote", action: focused(CommandActions.markdownBlockquote))
                .keyboardShortcut(AppShortcut.markdownBlockquote)
            Button("Horizontal Rule", action: focused(CommandActions.markdownHorizontalRule))
                .keyboardShortcut(AppShortcut.markdownHRule)
            Button("Link…", action: focused(CommandActions.markdownLink))
                .keyboardShortcut(AppShortcut.markdownLink)
            Button("Image…", action: focused(CommandActions.markdownImage))
                .keyboardShortcut(AppShortcut.markdownImage)
            Button("Footnote", action: focused(CommandActions.markdownFootnote))
                .keyboardShortcut(AppShortcut.markdownFootnote)
            Button("Organize Footnotes…") { presentSheet(.organizeFootnotes) }
            Button("Insert Table…", action: focused(CommandActions.presentMarkdownTable))
                .keyboardShortcut(AppShortcut.markdownTable)
            Divider()
            Button("Preview…", action: focused(CommandActions.presentMarkdownPreview))
                .keyboardShortcut(AppShortcut.markdownPreview)
        }
    }

    @ViewBuilder
    private var findSubmenuContent: some View {
        Group {
            Button("Find…") {
                // Mirror presentSheet's claimFocus so the seed
                // selection comes from the focused editor.
                focused {
                    CommandActions.seedFindFromSelection()
                    presentSheet(.findReplace)
                }
            }
            .keyboardShortcut(AppShortcut.find)
            .disabled(!isEnabled)
            Button("Find & Replace…", action: focused(CommandActions.presentFindAndReplace))
                .disabled(!isEnabled)
            Button("Multi-File Search…", action: focused(CommandActions.presentMultiFileSearch))
                .keyboardShortcut(AppShortcut.multiFileSearch)
        }

        Divider()

        Group {
            Button("Go to Line…") { presentSheet(.goToLine) }
                .keyboardShortcut(AppShortcut.goToLine)
            Button("Go to Matching Bracket", action: focused(CommandActions.goToMatchingBracket))
                .keyboardShortcut(AppShortcut.goToMatchingBracket)
            Button("Center Line", action: focused(CommandActions.centerLine))
        }
        .disabled(!isEnabled)

        Divider()

        Group {
            Button("Back", action: focused(CommandActions.positionBack))
                .keyboardShortcut(AppShortcut.positionBack)
            Button("Forward", action: focused(CommandActions.positionForward))
                .keyboardShortcut(AppShortcut.positionForward)
        }
        .disabled(!isEnabled)
    }

    /// Inactive slots stay visible (disabled) so users see which
    /// chords are available.
    @ViewBuilder
    private var jsTransformItems: some View {
        let slots = jsTransformStore.slots
        ForEach(slots) { slot in
            Button(slot.displayName) {
                focused { CommandActions.runJSTransform(slotID: slot.id) }
            }
            .keyboardShortcut(slotShortcutKey(for: slot.id), modifiers: [.control, .option])
            .disabled(!slot.isConfigured)
        }
        Divider()
        Button("Manage Transforms…", action: focused(CommandActions.presentPreferences))
    }

    /// Ten fixed slots, ⌥⌘1-9 + ⌥⌘0; mirrors `jsTransformItems`.
    @ViewBuilder
    private var snippetItems: some View {
        let slots = snippetsStore.slots
        ForEach(slots) { slot in
            Button(slot.displayName) {
                focused { CommandActions.insertSnippet(slotID: slot.id) }
            }
            .keyboardShortcut(slotShortcutKey(for: slot.id), modifiers: [.command, .option])
            .disabled(!slot.isConfigured)
        }
        Divider()
        Button("Save Selection as Snippet",
               action: focused(CommandActions.saveSelectionAsSnippet))
            .disabled((editorState?.selectedRange.length ?? 0) == 0)
        Button("Manage Snippets…",
               action: focused(CommandActions.presentSnippetsManager))
    }

    /// Slot 10 → "0", matching the tab-jump scheme.
    private func slotShortcutKey(for id: Int) -> KeyEquivalent {
        switch id {
        case 10: return "0"
        default: return KeyEquivalent(Character("\(id)"))
        }
    }

    // MARK: - Submenu builders

    @ViewBuilder
    private var encodingMenuItems: some View {
        ForEach(commonEncodings, id: \.self) { encoding in
            Button {
                focused { CommandActions.setEncoding(encoding) }
            } label: {
                if editorState?.fileEncoding == encoding {
                    Label(encoding.localizedName, systemImage: "checkmark")
                } else {
                    Text(encoding.localizedName)
                }
            }
        }
        Divider()
        Button("More Encodings…") { presentSheet(.encodingPicker) }
    }

    @ViewBuilder
    private var reopenWithEncodingMenuItems: some View {
        ForEach(commonEncodings, id: \.self) { encoding in
            Button(encoding.localizedName) {
                focused { CommandActions.reinterpretWithEncoding(encoding) }
            }
        }
    }

    @ViewBuilder
    private var lineEndingMenuItems: some View {
        ForEach(LineEnding.allCases, id: \.self) { lineEnding in
            Button {
                focused { CommandActions.applyLineEnding(lineEnding) }
            } label: {
                let title = "\(lineEnding.label) (\(lineEnding.description))"
                if editorState?.lineEnding == lineEnding {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }

    @ViewBuilder
    private var syntaxLanguageMenuItems: some View {
        ForEach(LanguageRegistry.all, id: \.identifier) { language in
            Button {
                focused { CommandActions.setLanguage(language.identifier) }
            } label: {
                if editorState?.languageIdentifier == language.identifier {
                    Label(language.displayName, systemImage: "checkmark")
                } else {
                    Text(language.displayName)
                }
            }
        }
    }

    @ViewBuilder
    private var openRecentMenuItems: some View {
        let recents = recentFilesStore.urls
        if recents.isEmpty {
            Text("No Recent Files").disabled(true)
        } else {
            ForEach(recents, id: \.self) { url in
                Button(url.lastPathComponent) {
                    CommandActions.routeOpenURL(url)
                }
            }
            Divider()
            Button("Clear Menu") { recentFilesStore.clear() }
        }
    }

    @ViewBuilder
    private var bookmarkMenuItems: some View {
        // ⌃⇧/⌃ digits: ⇧⌘0 collides with system Default Zoom and
        // ⇧⌘3/4 with screenshots (a conflict silently drops the whole
        // CommandGroup), and bare ⌥digit shadows Option-digit
        // characters on international layouts.
        Menu("Set Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.setBookmark(slot) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: [.control, .shift])
            }
        }
        Menu("Jump to Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.jumpToBookmark(slot) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .control)
            }
        }
        Menu("Clear Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.clearBookmark(slot) }
                }
            }
        }
        Divider()
        Button("Copy Bookmarked Lines", action: focused(CommandActions.copyBookmarkedLines))
        Button("Cut Bookmarked Lines", action: focused(CommandActions.cutBookmarkedLines))
        Button("Keep Only Bookmarked Lines", action: focused(CommandActions.keepBookmarkedLinesOnly))
        Button("Delete Bookmarked Lines", action: focused(CommandActions.removeBookmarkedLines))
        Divider()
        Button("Invert Bookmarks", action: focused(CommandActions.invertBookmarks))
    }

    @ViewBuilder
    private var indentMenuItems: some View {
        Button {
            focused { CommandActions.setIndentUsesTabs(false) }
        } label: {
            if editorState?.usesTabs == false {
                Label("Use Spaces", systemImage: "checkmark")
            } else {
                Text("Use Spaces")
            }
        }
        Button {
            focused { CommandActions.setIndentUsesTabs(true) }
        } label: {
            if editorState?.usesTabs == true {
                Label("Use Tabs", systemImage: "checkmark")
            } else {
                Text("Use Tabs")
            }
        }
        Divider()
        ForEach([2, 3, 4, 6, 8], id: \.self) { width in
            Button {
                focused { CommandActions.setIndentWidth(width) }
            } label: {
                if editorState?.indentWidth == width {
                    Label("Width: \(width)", systemImage: "checkmark")
                } else {
                    Text("Width: \(width)")
                }
            }
        }
    }

    private var commonEncodings: [FileEncoding] {
        [
            FileEncoding(encoding: .utf8),
            FileEncoding(encoding: .utf8, withUTF8BOM: true),
            FileEncoding(encoding: .utf16),
            FileEncoding(encoding: .utf16LittleEndian),
            FileEncoding(encoding: .utf16BigEndian),
            FileEncoding(encoding: .windowsCP1252),
            FileEncoding(encoding: .isoLatin1),
            FileEncoding(encoding: .macOSRoman),
            FileEncoding(encoding: .shiftJIS),
            FileEncoding(encoding: .japaneseEUC)
        ]
    }

    /// `defaultsKey` writes back to UserDefaults so the change
    /// survives relaunch. Falls back to the stored pref
    /// on cold launch — without that, the toggle would visually lie
    /// about whether the pref is on.
    private func bindingFor(
        _ keyPath: ReferenceWritableKeyPath<EditorState, Bool>,
        defaultsKey: String? = nil
    ) -> Binding<Bool> {
        Binding(
            get: {
                if let state = editorState { return state[keyPath: keyPath] }
                if let defaultsKey { return UserDefaults.standard.bool(forKey: defaultsKey) }
                return false
            },
            set: { newValue in
                editorState?[keyPath: keyPath] = newValue
                if let defaultsKey {
                    UserDefaults.standard.set(newValue, forKey: defaultsKey)
                }
            }
        )
    }
}
