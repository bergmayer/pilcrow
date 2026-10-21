import SwiftUI
import UIKit

/// Single source of truth for menu keyboard shortcuts. Keys are
/// named after the action, not the chord — a future remap touches
/// one line per command. Not centralized: SwiftUI roles like
/// `.cancelAction`, and dynamic keys built from indices (tab number,
/// bookmark slot, JS transform slot).
@MainActor
enum AppShortcut {

    // MARK: App
    static let preferences      = KeyboardShortcut(",")
    /// Primary shortcut shown in the menu. A second binding adds ⌃P as
    /// an alias — see `EditorCommands` where both are wired.
    static let commandPalette   = KeyboardShortcut("p")

    // MARK: File
    static let newWindow        = KeyboardShortcut("n")
    static let newTab           = KeyboardShortcut("t")
    static let save             = KeyboardShortcut("s")
    static let saveAs           = KeyboardShortcut("s", modifiers: [.command, .shift])
    static let showRevisions    = KeyboardShortcut("h", modifiers: [.command, .option])

    // MARK: Edit
    static let clipboardHistory = KeyboardShortcut("v", modifiers: [.command, .shift])
    static let transposeChars   = KeyboardShortcut("t", modifiers: .control)
    static let deleteToEOL      = KeyboardShortcut("k", modifiers: .control)
    static let deleteWordBack   = KeyboardShortcut(.delete, modifiers: .option)
    static let deleteWordFwd    = KeyboardShortcut(.deleteForward, modifiers: .option)
    static let joinLines        = KeyboardShortcut("j", modifiers: .control)

    // MARK: View
    static let showOutline      = KeyboardShortcut("s", modifiers: [.command, .control])
    static let biggerFont       = KeyboardShortcut("+")
    static let smallerFont      = KeyboardShortcut("-")
    static let resetFontSize    = KeyboardShortcut("0")
    static let showLineNumbers  = KeyboardShortcut("l", modifiers: [.command, .shift])
    static let wrapLines        = KeyboardShortcut("w", modifiers: [.command, .option])
    static let showInvisibles   = KeyboardShortcut("i", modifiers: [.command, .shift])
    /// Xcode parity (⌃⌘F); ⌥⌘F is Find and Replace.
    static let foldAtCursor     = KeyboardShortcut("f", modifiers: [.command, .control])
    static let foldSelectionBlock = KeyboardShortcut("h", modifiers: [.command, .control])
    static let foldAll          = KeyboardShortcut("[", modifiers: [.command, .option])
    static let unfoldAll        = KeyboardShortcut("]", modifiers: [.command, .option])
    static let cycleSplitView   = KeyboardShortcut("e", modifiers: [.command, .option])
    static let showFileInfo     = KeyboardShortcut("i", modifiers: [.command, .option])
    static let characterInspector = KeyboardShortcut("i", modifiers: [.command, .control])

    // MARK: Text
    static let duplicateLine    = KeyboardShortcut("d", modifiers: [.command, .shift])
    static let deleteLine       = KeyboardShortcut("k", modifiers: [.command, .shift])
    static let moveLineUp       = KeyboardShortcut(.upArrow, modifiers: .option)
    static let moveLineDown     = KeyboardShortcut(.downArrow, modifiers: .option)
    static let indentSelection  = KeyboardShortcut("]")
    static let outdentSelection = KeyboardShortcut("[")

    // MARK: Markdown
    static let markdownBold      = KeyboardShortcut("b")
    static let markdownItalic    = KeyboardShortcut("i")
    /// ⌥⌘C — ⌘` is iPadOS Cycle Through Windows in multi-window apps.
    static let markdownCode      = KeyboardShortcut("c", modifiers: [.command, .option])
    static let markdownStrike    = KeyboardShortcut("x", modifiers: [.command, .shift])
    static let markdownBlockquote = KeyboardShortcut("'", modifiers: [.command, .shift])
    static let markdownHRule     = KeyboardShortcut("-", modifiers: [.command, .shift])
    static let markdownLink      = KeyboardShortcut("k")
    static let markdownImage     = KeyboardShortcut("k", modifiers: [.command, .option])
    /// ⌥⌘N — ⇧⌘0 collides with Default Zoom, ⌃⌘F with Fold at Cursor.
    static let markdownFootnote  = KeyboardShortcut("n", modifiers: [.command, .option])
    static let markdownTable     = KeyboardShortcut("t", modifiers: [.command, .control])
    static let markdownPreview   = KeyboardShortcut("p", modifiers: [.command, .option])
    static let markdownHeading1  = KeyboardShortcut("1", modifiers: [.command, .control])
    static let markdownHeading2  = KeyboardShortcut("2", modifiers: [.command, .control])
    static let markdownHeading3  = KeyboardShortcut("3", modifiers: [.command, .control])
    static let markdownHeading4  = KeyboardShortcut("4", modifiers: [.command, .control])
    static let markdownHeading5  = KeyboardShortcut("5", modifiers: [.command, .control])
    static let markdownHeading6  = KeyboardShortcut("6", modifiers: [.command, .control])

    // MARK: Search
    static let find              = KeyboardShortcut("f")
    static let multiFileSearch   = KeyboardShortcut("f", modifiers: [.command, .shift])
    static let goToLine          = KeyboardShortcut("l")
    /// ⌃⌘B — ⇧⌘\ is taken by Show All Tabs.
    static let goToMatchingBracket = KeyboardShortcut("b", modifiers: [.command, .control])
    static let positionBack      = KeyboardShortcut(.leftArrow, modifiers: [.command, .control])
    static let positionForward   = KeyboardShortcut(.rightArrow, modifiers: [.command, .control])

    // MARK: Tabs / Window
    static let showAllTabs       = KeyboardShortcut("\\", modifiers: [.command, .shift])
    static let closeTab          = KeyboardShortcut("w")
    static let closeWindow       = KeyboardShortcut("w", modifiers: [.command, .shift])
    static let reopenLastClosed  = KeyboardShortcut("t", modifiers: [.command, .shift])
    static let nextTab           = KeyboardShortcut("]", modifiers: [.command, .shift])
    static let previousTab       = KeyboardShortcut("[", modifiers: [.command, .shift])
}

/// Registry shortcut hints use the same modifier glyphs as the menus.
/// Normalize them once when interpreting a software-keyboard chord.
struct EditorKeyChord: Equatable {
    let key: String
    let modifiers: UIKeyModifierFlags

    init(key: String, modifiers: UIKeyModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    init?(hint: String) {
        var key = ""
        var modifiers: UIKeyModifierFlags = []
        for character in hint {
            switch character {
            case "⌘": modifiers.insert(.command)
            case "⌃": modifiers.insert(.control)
            case "⌥": modifiers.insert(.alternate)
            case "⇧": modifiers.insert(.shift)
            case " ": continue
            default: key.append(character)
            }
        }
        guard key.count == 1 else { return nil }
        self.init(key: key, modifiers: modifiers)
    }
}
