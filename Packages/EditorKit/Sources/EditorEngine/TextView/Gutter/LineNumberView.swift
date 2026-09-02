import UIKit

/// Indicator state for the fold triangle next to a line number.
enum FoldIndicatorState {
    case expanded   // ▼  body visible
    case collapsed  // ▶︎ body folded
}

final class LineNumberView: UIView, ReusableView {
    var textColor: UIColor {
        get { titleLabel.textColor }
        set { titleLabel.textColor = newValue }
    }
    var font: UIFont {
        get { titleLabel.font }
        set {
            titleLabel.font = newValue
            foldIndicatorLabel.font = newValue
        }
    }
    var text: String? {
        get { titleLabel.text }
        set { titleLabel.text = newValue }
    }

    /// Set non-nil when this line begins a fold; the indicator triangle is
    /// drawn just left of the line number. Tapping the indicator invokes
    /// `onFoldTap` if set.
    var foldIndicator: FoldIndicatorState? {
        didSet {
            switch foldIndicator {
            case .none:
                foldIndicatorLabel.isHidden = true
            case .expanded:
                foldIndicatorLabel.isHidden = false
                foldIndicatorLabel.text = "▼"
                foldIndicatorLabel.textColor = textColor.withAlphaComponent(0.55)
            case .collapsed:
                foldIndicatorLabel.isHidden = false
                foldIndicatorLabel.text = "▶︎"
                foldIndicatorLabel.textColor = textColor
            }
            setNeedsLayout()
        }
    }

    /// Closure invoked when the user taps the indicator triangle.
    var onFoldTap: (() -> Void)?

    /// pt reserved at the right edge for the fold-indicator triangle. The
    /// digits always lay out in the leftmost `bounds.width - reservation`
    /// area, so they don't truncate when a triangle is added.
    var foldIndicatorReservation: CGFloat = 14 {
        didSet { setNeedsLayout() }
    }

    private let titleLabel: UILabel = {
        let this = UILabel()
        this.textAlignment = .right
        return this
    }()

    private let foldIndicatorLabel: UILabel = {
        let this = UILabel()
        this.textAlignment = .center
        this.isHidden = true
        this.isUserInteractionEnabled = true
        return this
    }()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        addSubview(titleLabel)
        addSubview(foldIndicatorLabel)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFoldTap))
        foldIndicatorLabel.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Only claim hits that actually land on the fold triangle's tappable
    /// area. Everything else in the line-number column (the digits themselves,
    /// blank space when there's no fold) falls through to the text view so
    /// caret/selection still work near the gutter.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard foldIndicator != nil,
              !foldIndicatorLabel.isHidden,
              foldIndicatorLabel.frame.contains(point) else { return nil }
        return foldIndicatorLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = titleLabel.intrinsicContentSize
        // The indicator column is always reserved (even when no triangle is
        // shown) so the line-number digits get a constant width and never
        // truncate. The visible triangle sits at the right edge; the
        // tappable region extends sideways past it to meet the HIG 44pt
        // minimum without enlarging the visible glyph.
        let triangleVisualWidth = foldIndicatorReservation
        let tapPadding: CGFloat = (foldIndicator == nil) ? 0 : 30
        let titleWidth = bounds.width - triangleVisualWidth
        titleLabel.frame = CGRect(x: 0, y: 0, width: titleWidth, height: size.height)
        foldIndicatorLabel.frame = CGRect(
            x: titleWidth - tapPadding,
            y: max(0, (bounds.height - 44) / 2),
            width: triangleVisualWidth + tapPadding * 2,
            height: max(44, size.height)
        )
    }

    @objc private func handleFoldTap() {
        onFoldTap?()
    }
}
