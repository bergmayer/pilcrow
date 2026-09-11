import Foundation

/// `.fileBrowser` hosts a UIDocumentBrowserViewController inline;
/// a pick transitions the tab back to `.editor` with the file loaded.
/// `.launcher` is the start page for a new tab or window, or an emptied window. Choosing
/// a document source replaces it with `.editor` in the same tab.
enum TabKind {
    case editor
    case fileBrowser
    case launcher
}

/// Equatable by identity so SwiftUI can match rows in the tab bar.
@MainActor
@Observable
final class TabModel: Identifiable {
    let id = UUID()
    let document: PlainTextDocument
    let state: EditorState
    /// Pinned tabs sort left, render as compact chips, and survive
    /// "Close Other Tabs".
    var isPinned: Bool = false
    var kind: TabKind = .editor
    /// Per-tab so split state isn't shared between tabs — each pane
    /// keeps its own cursor / scroll across split toggles.
    var secondaryState: EditorState?

    init(kind: TabKind = .editor) {
        self.document = PlainTextDocument()
        self.state = EditorState()
        self.kind = kind
    }

    /// Start an untitled document from a launcher choice or template.
    /// Seeded text needs recovery even if the user never types a key.
    func startDocument(with text: String = "") {
        document.text = text
        document.fileURL = nil
        document.isDirty = !text.isEmpty
        state.text = text
        state.fileURL = nil
        state.savedBaselineText = ""
        kind = .editor
        state.requestEditorFocus()
        if document.isDirty { document.autoSave() }
    }

    func owns(_ editor: EditorState?) -> Bool {
        guard let editor else { return false }
        return state === editor || secondaryState === editor
    }

    /// Read the live buffer for untitled work: its observable text snapshot
    /// can lag the first keystroke or deletion. `hasText` avoids copying it.
    var needsCloseConfirmation: Bool {
        if document.fileURL != nil { return document.isDirty }
        _ = document.bufferRevision
        return state.textView?.hasText ?? !document.text.isEmpty
    }

    /// Seeds the split pane with the same view settings as the
    /// primary so both panes start identical.
    func ensureSecondaryState() -> EditorState {
        if let existing = secondaryState { return existing }
        let fresh = EditorState()
        fresh.text = state.text
        fresh.fileEncoding = state.fileEncoding
        fresh.lineEnding = state.lineEnding
        fresh.fileURL = state.fileURL
        fresh.languageIdentifier = state.languageIdentifier
        // Copy the override slots, not the computed accessors — those
        // setters write the global preference when no override exists,
        // silently promoting a per-window override to a global pref.
        fresh.themeOverride = state.themeOverride
        fresh.fontOverride = state.fontOverride
        fresh.fontSizeOverride = state.fontSizeOverride
        fresh.showLineNumbers = state.showLineNumbers
        fresh.wrapLines = state.wrapLines
        fresh.savedBaselineText = state.savedBaselineText
        // Bidirectional sibling links so each coordinator can find
        // the other pane's text view directly — pushing deltas
        // through a shared observable would re-render every observer.
        state.siblingState = fresh
        fresh.siblingState = state
        secondaryState = fresh
        return fresh
    }
}

extension TabModel: Equatable {
    nonisolated static func == (lhs: TabModel, rhs: TabModel) -> Bool {
        lhs === rhs
    }
}
