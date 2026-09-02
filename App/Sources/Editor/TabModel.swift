import Foundation

/// `.fileBrowser` hosts a UIDocumentBrowserViewController inline;
/// a pick transitions the tab back to `.editor` with the file loaded.
/// `.launcher` is retained for compatibility with legacy/restored UI
/// state. Ordinary new windows and tabs now start as blank `.editor`
/// tabs; templates and recovery have explicit entry points.
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
    /// "Close Other Tabs" — mirrors Safari.
    var isPinned: Bool = false
    var kind: TabKind = .editor
    /// Per-tab so split state isn't shared between tabs — each pane
    /// keeps its own cursor / scroll across split toggles.
    var secondaryState: EditorState?

    init() {
        self.document = PlainTextDocument()
        self.state = EditorState()
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
