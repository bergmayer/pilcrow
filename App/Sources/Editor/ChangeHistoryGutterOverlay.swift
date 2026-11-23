import UIKit
import EditorEngine

/// Compares current and saved lines by row to draw change markers.
final class ChangeHistoryGutterOverlay: UIView {

    weak var host: EditorEngine.TextView?

    private var baselineText: String?
    private var currentText: String?
    private var baseline: [String] = []
    private var current: [String] = []

    func update(baseline saved: String, current text: String) {
        guard baselineText != saved || currentText != text else { return }
        guard text.utf16.count <= Timing.changeHistoryGutterLengthLimit,
              saved.utf16.count <= Timing.changeHistoryGutterLengthLimit else {
            clear()
            return
        }
        if baselineText != saved {
            baselineText = saved
            baseline = TextMetrics.lines(in: saved)
        }
        if currentText != text {
            currentText = text
            current = TextMetrics.lines(in: text)
        }
        setNeedsLayout()
    }

    func clear() {
        guard currentText != nil else { return }
        baselineText = nil
        currentText = nil
        baseline = []
        current = []
        setNeedsLayout()
    }

    private static let stripWidth: CGFloat = 4

    init(host: EditorEngine.TextView) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host else { return }
        let cs = host.contentSize
        // Sit at `x == gutterWidth`, in the `textContainerInset.left`
        // margin. Inside the gutter is unreachable: the engine calls
        // `bringSubviewToFront(gutterContainerView)` in its own
        // layoutSubviews and would cover any sibling we parked there.
        frame = CGRect(x: host.gutterWidth, y: 0, width: Self.stripWidth, height: cs.height)
        rebuild()
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        guard let host else { return }
        guard !baseline.isEmpty || !current.isEmpty else { return }

        // For each current line, classify against the matching
        // baseline index: same text = no bar, different = modified,
        // past baseline range = added.
        let maxIdx = current.count
        var i = 0
        let bCount = baseline.count
        while i < maxIdx {
            let baselineLine: String? = i < bCount ? baseline[i] : nil
            let kind: BarKind?
            if let baselineLine {
                kind = baselineLine == current[i] ? nil : .modified
            } else {
                kind = .added
            }
            if let kind {
                addBar(forLine: i, kind: kind, host: host)
            }
            i += 1
        }
        // Anchor the deletion wedge to the last existing row — there
        // is no row at the deleted lines themselves.
        if bCount > current.count {
            let anchorLine = max(0, current.count - 1)
            addBar(forLine: anchorLine, kind: .deleted, host: host)
        }
    }

    private enum BarKind {
        case added, modified, deleted
        var color: UIColor {
            switch self {
            case .added:    return UIColor.systemGreen.withAlphaComponent(0.7)
            case .modified: return UIColor.systemYellow.withAlphaComponent(0.75)
            case .deleted:  return UIColor.systemRed.withAlphaComponent(0.7)
            }
        }
    }

    private func addBar(forLine line: Int, kind: BarKind, host: EditorEngine.TextView) {
        guard let rect = host.caretRect(atLine: line),
              rect.height > 0, rect.height.isFinite, rect.minY.isFinite else { return }
        let bar = UIView(frame: CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height))
        bar.backgroundColor = kind.color
        bar.layer.cornerRadius = bounds.width / 2
        addSubview(bar)
    }
}
