import Foundation

/// Drives `.sheet(item:)` on the active editor scene via
/// `AppStateBus.shared.presentation.presentedSheet`.
enum EditorSheet: Identifiable {
    case encodingPicker
    case lineEndingPicker
    case languagePicker
    case characterInspector
    case sortLines
    case goToLine
    case selectLinesContaining
    case findReplace
    case zapGremlins
    case revisions
    case commandPalette
    case fileBrowser
    case multiFileSearch
    case preferences
    case prefixSuffixLines
    case insertLoremIpsum
    case snippetsManager
    case clipboardHistory
    case templatePicker
    case tabSwitcher
    case processLines
    case canonize
    case characterPanel
    case markdownTable
    /// iPhone fallback — iPad opens a real scene via `openWindow`;
    /// iPhone is single-window so this sheet is the only way the
    /// preview actually appears.
    case markdownPreview
    case organizeFootnotes
    /// Word-style walk-through: shows the next misspelled word with
    /// suggestions, lets the user Change / Ignore / Learn one at a
    /// time. Available regardless of the live spell-check toggle.
    case spellCheck

    var id: String {
        switch self {
        case .encodingPicker:        return "encoding"
        case .lineEndingPicker:      return "lineEnding"
        case .languagePicker:        return "language"
        case .characterInspector:    return "character"
        case .sortLines:             return "sort"
        case .goToLine:              return "goToLine"
        case .selectLinesContaining: return "selectLines"
        case .findReplace:           return "findReplace"
        case .zapGremlins:           return "zapGremlins"
        case .revisions:             return "revisions"
        case .commandPalette:        return "commandPalette"
        case .fileBrowser:           return "fileBrowser"
        case .multiFileSearch:       return "multiFileSearch"
        case .preferences:           return "preferences"
        case .prefixSuffixLines:     return "prefixSuffix"
        case .insertLoremIpsum:      return "lipsum"
        case .snippetsManager:       return "snippetsManager"
        case .clipboardHistory:      return "clipboardHistory"
        case .templatePicker:        return "templatePicker"
        case .tabSwitcher:           return "tabSwitcher"
        case .processLines:          return "processLines"
        case .canonize:              return "canonize"
        case .characterPanel:        return "characterPanel"
        case .markdownTable:         return "markdownTable"
        case .markdownPreview:       return "markdownPreview"
        case .organizeFootnotes:     return "organizeFootnotes"
        case .spellCheck:            return "spellCheck"
        }
    }
}
