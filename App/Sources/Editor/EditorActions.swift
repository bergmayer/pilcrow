import EditorEngine
import UIKit

/// App-owned editor view. A concrete type is sufficient: Pilcrow has one
/// editor engine and no alternate conformers or protocol-based test doubles.
/// Per-document editor state belongs here instead of in process-wide statics.
@MainActor
final class PilcrowTextView: EditorEngine.TextView {
    var restoreOnLayout: EditorViewport?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let viewport = restoreOnLayout, window != nil, bounds.height > 0 else { return }
        restoreOnLayout = nil
        setSelection(viewport.selection)
        let minX = -adjustedContentInset.left
        let minY = -adjustedContentInset.top
        let maxX = max(minX, contentSize.width - bounds.width + adjustedContentInset.right)
        let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let x = viewport.x.isFinite ? viewport.x : minX
        let y = viewport.y.isFinite ? viewport.y : minY
        setContentOffset(CGPoint(x: min(maxX, max(minX, x)), y: min(maxY, max(minY, y))), animated: false)
    }

    var ignoredSpellingWords: Set<String> = []
}
