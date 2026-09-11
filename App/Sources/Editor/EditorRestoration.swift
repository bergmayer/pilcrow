import Foundation
import UIKit

/// Selection and scroll position belong to each pane, even when two panes edit
/// the same buffer. Optional layout metadata keeps older sessions readable.
struct EditorViewport: Codable, Equatable, Sendable {
    let selection: NSRange
    let x: Double
    let y: Double

    @MainActor init(state: EditorState) {
        selection = state.textView?.selectedRange ?? state.selectedRange
        let offset = state.textView?.contentOffset
        x = offset.map { Double($0.x) } ?? state.viewport?.x ?? 0
        y = offset.map { Double($0.y) } ?? state.viewport?.y ?? 0
    }

    @MainActor func restore(to state: EditorState) {
        state.viewport = self
        state.pendingViewport = self
        state.selectedRange = selection
        state.textView?.setNeedsLayout()
    }
}

struct EditorLayoutSnapshot: Codable, Sendable {
    let primary: EditorViewport
    let secondary: EditorViewport?
    let verticalSplit: Bool
    let splitFraction: Double

    @MainActor init(tab: TabModel) {
        primary = EditorViewport(state: tab.state)
        secondary = tab.state.splitOpen ? EditorViewport(state: tab.secondaryState ?? tab.state) : nil
        verticalSplit = tab.state.splitOrientation == .vertical
        splitFraction = tab.state.splitFraction
    }

    @MainActor func restore(to tab: TabModel) {
        primary.restore(to: tab.state)
        tab.state.splitOrientation = verticalSplit ? .vertical : .horizontal
        tab.state.splitFraction = min(0.9, max(0.1, splitFraction.isFinite ? splitFraction : 0.5))
        tab.state.splitOpen = secondary != nil
        if let secondary { secondary.restore(to: tab.ensureSecondaryState()) }
    }
}
