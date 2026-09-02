// swiftlint:disable file_length
import CoreGraphics
import CoreText
import UIKit

typealias LineFragmentTree = RedBlackTree<LineFragmentNodeID, Int, LineFragmentNodeData>

protocol LineControllerDelegate: AnyObject {
    func lineSyntaxHighlighter(for lineController: LineController) -> LineSyntaxHighlighter?
    func lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(_ lineController: LineController)
    /// Apply post-highlight attribute decoration to a line's attributed
    /// string. Called after the language-mode highlighter has run, so the
    /// callee can layer on extra attributes (foreground color, font,
    /// underline) without fighting tree-sitter.
    /// - Parameters:
    ///   - attributedString: The line's mutable attributed string. Attribute
    ///     changes mutate it in place.
    ///   - lineLocation: Absolute UTF-16 offset where the line starts in
    ///     the document. Use this to translate document-relative ranges
    ///     (e.g. from the app's own regex scan) into local ranges.
    ///   - lineLength: Length of the line's content in UTF-16 units
    ///     (excluding the line terminator).
    func lineControllerDecorate(
        attributedString: NSMutableAttributedString,
        lineLocation: Int,
        lineLength: Int
    )
}

extension LineControllerDelegate {
    func lineControllerDecorate(
        attributedString: NSMutableAttributedString,
        lineLocation: Int,
        lineLength: Int
    ) {}
}

final class LineController {
    private enum TypesetAmount {
        case inRect(CGRect)
        case toLocation(Int)
    }

    weak var delegate: LineControllerDelegate?
    let line: DocumentLineNode
    var lineFragmentHeightMultiplier: CGFloat = 1 {
        didSet {
            if lineFragmentHeightMultiplier != oldValue {
                typesetter.lineFragmentHeightMultiplier = lineFragmentHeightMultiplier
            }
        }
    }
    var theme: Theme = DefaultTheme() {
        didSet {
            syntaxHighlighter?.theme = theme
            applyThemeToAllLineFragmentControllers()
        }
    }
    var estimatedLineFragmentHeight: CGFloat = 15
    var tabWidth: CGFloat = 10
    var constrainingWidth: CGFloat {
        get {
            typesetter.constrainingWidth
        }
        set {
            guard abs(typesetter.constrainingWidth - newValue) > CGFloat.ulpOfOne else { return }
            typesetter.constrainingWidth = newValue
            // Existing Core Text fragments encode the width at which they
            // were created. Reusing them at a new width clips source ranges
            // while still advancing past those ranges.
            isLineFragmentCacheInvalid = true
            isTypesetterInvalid = true
            _lineHeight = nil
        }
    }
    var lineWidth: CGFloat {
        ceil(typesetter.maximumLineWidth)
    }
    var lineHeight: CGFloat {
        // Folded lines contribute zero vertical space — the line still
        // exists in the document but disappears from layout.
        if line.data.isHidden { return 0 }
        if let lineHeight = _lineHeight {
            return lineHeight
        } else if typesetter.lineFragments.isEmpty {
            let lineHeight = estimatedLineFragmentHeight * lineFragmentHeightMultiplier
            _lineHeight = lineHeight
            return lineHeight
        } else {
            let knownLineFragmentHeight = typesetter.lineFragments.reduce(0) { $0 + $1.scaledSize.height }
            let remainingNumberOfLineFragments = typesetter.bestGuessNumberOfLineFragments - typesetter.lineFragments.count
            let lineFragmentHeight = estimatedLineFragmentHeight * lineFragmentHeightMultiplier
            let remainingLineFragmentHeight = CGFloat(remainingNumberOfLineFragments) * lineFragmentHeight
            let lineHeight = knownLineFragmentHeight + remainingLineFragmentHeight
            _lineHeight = lineHeight
            return lineHeight
        }
    }
    var kern: CGFloat = 0 {
        didSet {
            if kern != oldValue {
                isDefaultAttributesInvalid = true
            }
        }
    }
    var lineBreakMode: LineBreakMode {
        get {
            typesetter.lineBreakMode
        }
        set {
            typesetter.lineBreakMode = newValue
        }
    }
    var numberOfLineFragments: Int {
        typesetter.lineFragments.count
    }
    var isFinishedTypesetting: Bool {
        typesetter.isFinishedTypesetting
    }
    private(set) var attributedString: NSMutableAttributedString?

    private let stringView: StringView
    private let invisibleCharacterConfiguration: InvisibleCharacterConfiguration
    private let highlightService: HighlightService
    private let typesetter: LineTypesetter
    private var cachedSyntaxHighlighter: LineSyntaxHighlighter?
    private var lineFragmentControllers: [LineFragmentID: LineFragmentController] = [:]
    private var isLineFragmentCacheInvalid = true
    private var isStringInvalid = true
    private var isDefaultAttributesInvalid = true
    private var isSyntaxHighlightingInvalid = true
    private var isTypesetterInvalid = true
    private var _lineHeight: CGFloat?
    private var lineFragmentTree: LineFragmentTree
    private var syntaxHighlighter: LineSyntaxHighlighter? {
        if let cachedSyntaxHighlighter = cachedSyntaxHighlighter {
            return cachedSyntaxHighlighter
        } else if let syntaxHighlighter = delegate?.lineSyntaxHighlighter(for: self) {
            syntaxHighlighter.theme = theme
            cachedSyntaxHighlighter = syntaxHighlighter
            return syntaxHighlighter
        } else {
            return nil
        }
    }

    init(line: DocumentLineNode,
         stringView: StringView,
         invisibleCharacterConfiguration: InvisibleCharacterConfiguration,
         highlightService: HighlightService) {
        self.line = line
        self.stringView = stringView
        self.invisibleCharacterConfiguration = invisibleCharacterConfiguration
        self.highlightService = highlightService
        self.typesetter = LineTypesetter(lineID: line.id.rawValue)
        let rootLineFragmentNodeData = LineFragmentNodeData(lineFragment: nil)
        self.lineFragmentTree = LineFragmentTree(minimumValue: 0, rootValue: 0, rootData: rootLineFragmentNodeData)
    }

    func prepareToDisplayString(in rect: CGRect, syntaxHighlightAsynchronously: Bool) {
        prepareToDisplayString(.inRect(rect), syntaxHighlightAsynchronously: syntaxHighlightAsynchronously)
    }

    func prepareToDisplayString(toLocation location: Int, syntaxHighlightAsynchronously: Bool) {
        prepareToDisplayString(.toLocation(location), syntaxHighlightAsynchronously: syntaxHighlightAsynchronously)
    }

    func cancelSyntaxHighlighting() {
        syntaxHighlighter?.cancel()
    }

    func invalidateEverything() {
        isLineFragmentCacheInvalid = true
        isStringInvalid = true
        isTypesetterInvalid = true
        isDefaultAttributesInvalid = true
        isSyntaxHighlightingInvalid = true
        _lineHeight = nil
    }

    func invalidateSyntaxHighlighter() {
        cachedSyntaxHighlighter = nil
    }

    func invalidateSyntaxHighlighting() {
        isTypesetterInvalid = true
        isDefaultAttributesInvalid = true
        isSyntaxHighlightingInvalid = true
        _lineHeight = nil
    }

    func lineFragmentControllers(in rect: CGRect) -> [LineFragmentController] {
        let lineYPosition = line.yPosition
        let localMinY = rect.minY - lineYPosition
        let localMaxY = rect.maxY - lineYPosition
        let query = LineFragmentFrameQuery(range: localMinY ... localMaxY)
        return lineFragmentControllers(matching: query)
    }

    func lineFragmentNode(containingCharacterAt location: Int) -> LineFragmentNode? {
        guard location >= 0, location <= lineFragmentTree.nodeTotalValue else { return nil }
        return lineFragmentTree.node(containingLocation: location)
    }

    func needsTypesetting(to location: Int) -> Bool {
        isTypesetterInvalid || typesetter.typesetLength < location
    }

    func lineFragmentNode(atIndex index: Int) -> LineFragmentNode {
        lineFragmentTree.node(atIndex: index)
    }

    func setNeedsDisplayOnLineFragmentViews() {
        for (_, lineFragmentController) in lineFragmentControllers {
            lineFragmentController.lineFragmentView?.setNeedsDisplay()
        }
    }

    func setMarkedTextOnLineFragments(_ range: NSRange?) {
        for (_, lineFragmentController) in lineFragmentControllers {
            let lineFragment = lineFragmentController.lineFragment
            if let range = range, range.overlaps(lineFragment.visibleRange) {
                lineFragmentController.markedRange = range
            } else {
                lineFragmentController.markedRange = nil
            }
        }
    }
}

private extension LineController {
    private func prepareToDisplayString(_ typesetAmount: TypesetAmount, syntaxHighlightAsynchronously: Bool) {
        prepareString(syntaxHighlightAsynchronously: syntaxHighlightAsynchronously)
        typesetLineFragments(typesetAmount)
    }

    private func prepareString(syntaxHighlightAsynchronously: Bool) {
        syntaxHighlighter?.cancel()
        clearLineFragmentControllersIfNecessary()
        updateStringIfNecessary()
        updateDefaultAttributesIfNecessary()
        updateSyntaxHighlightingIfNecessary(async: syntaxHighlightAsynchronously)
        // Always run the post-highlight decorator, even when no syntax
        // highlighter exists or it can't highlight yet (plain text mode,
        // or tree-sitter while it's still parsing the document). Without
        // this the app-layer markdown highlighter never fires on initial
        // display and never fires at all for plain text.
        if let attributedString = attributedString {
            applyPostHighlightDecoration(to: attributedString)
        }
        updateTypesetterIfNecessary()
    }

    private func typesetLineFragments(_ typesetAmount: TypesetAmount) {
        let newLineFragments: [LineFragment]
        switch typesetAmount {
        case .inRect(let rect):
            newLineFragments = typesetter.typesetLineFragments(in: rect)
        case .toLocation(let location):
            // When typesetting to a location we'll typeset an additional line fragment to ensure that we can display the text surrounding that location.
            newLineFragments = typesetter.typesetLineFragments(toLocation: location, additionalLineFragmentCount: 1)
        }
        updateLineHeight(for: newLineFragments)
    }

    private func clearLineFragmentControllersIfNecessary() {
        if isLineFragmentCacheInvalid {
            lineFragmentControllers.removeAll(keepingCapacity: true)
            isLineFragmentCacheInvalid = false
        }
    }

    private func updateStringIfNecessary() {
        if isStringInvalid {
            let range = NSRange(location: line.location, length: line.data.totalLength)
            if let string = stringView.substring(in: range) {
                attributedString = NSMutableAttributedString(string: string)
            } else {
                attributedString = nil
            }
            isStringInvalid = false
            isDefaultAttributesInvalid = true
            isSyntaxHighlightingInvalid = true
            isTypesetterInvalid = true
        }
    }

    private func updateDefaultAttributesIfNecessary() {
        if isDefaultAttributesInvalid {
            if let input = createLineSyntaxHighlightInput() {
                let defaultStringAttributes = DefaultStringAttributes(
                    textColor: theme.textColor,
                    font: theme.font,
                    kern: kern,
                    tabWidth: tabWidth
                )
                defaultStringAttributes.apply(to: input.attributedString)
            }
            isDefaultAttributesInvalid = false
            isSyntaxHighlightingInvalid = true
            isTypesetterInvalid = true
        }
    }

    private func updateTypesetterIfNecessary() {
        if isTypesetterInvalid {
            lineFragmentTree.reset(rootValue: 0, rootData: LineFragmentNodeData(lineFragment: nil))
            typesetter.reset()
            if let attributedString = attributedString {
                typesetter.prepareToTypeset(attributedString)
            }
            isTypesetterInvalid = false
        }
    }

    private func updateSyntaxHighlightingIfNecessary(async: Bool) {
        guard isSyntaxHighlightingInvalid else {
            return
        }
        guard let syntaxHighlighter = syntaxHighlighter else {
            return
        }
        guard syntaxHighlighter.canHighlight else {
            isSyntaxHighlightingInvalid = false
            return
        }
        guard let input = createLineSyntaxHighlightInput() else {
            isSyntaxHighlightingInvalid = false
            return
        }
        if async {
            syntaxHighlighter.syntaxHighlight(input) { [weak self] result in
                if case .success = result, let self = self {
                    self.applyPostHighlightDecoration(to: input.attributedString)
                    let oldWidth = self.lineWidth
                    self.isSyntaxHighlightingInvalid = false
                    self.isTypesetterInvalid = true
                    self.redisplayLineFragments()
                    if abs(self.lineWidth - oldWidth) > CGFloat.ulpOfOne {
                        self.delegate?.lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(self)
                    }
                }
            }
        } else {
            syntaxHighlighter.cancel()
            syntaxHighlighter.syntaxHighlight(input)
            applyPostHighlightDecoration(to: input.attributedString)
            isSyntaxHighlightingInvalid = false
            isTypesetterInvalid = true
        }
    }

    private func applyPostHighlightDecoration(to attributedString: NSMutableAttributedString) {
        delegate?.lineControllerDecorate(
            attributedString: attributedString,
            lineLocation: line.location,
            lineLength: line.data.length
        )
    }

    private func updateLineHeight(for lineFragments: [LineFragment]) {
        var previousNode: LineFragmentNode?
        for lineFragment in lineFragments {
            let length = lineFragment.range.length
            let data = LineFragmentNodeData(lineFragment: lineFragment)
            if lineFragment.index < lineFragmentTree.nodeTotalCount {
                let node = lineFragmentTree.node(atIndex: lineFragment.index)
                let heightDifference = abs(lineFragment.baseSize.height - node.data.lineFragmentHeight)
                if heightDifference > CGFloat.ulpOfOne {
                    _lineHeight = nil
                }
                node.value = length
                node.data.lineFragment = lineFragment
                node.updateTotalLineFragmentHeight()
                lineFragmentTree.updateAfterChangingChildren(of: node)
                previousNode = node
            } else if let thisPreviousNode = previousNode {
                let newNode = lineFragmentTree.insertNode(value: length, data: data, after: thisPreviousNode)
                newNode.updateTotalLineFragmentHeight()
                previousNode = newNode
                _lineHeight = nil
            } else {
                let thisPreviousNode = lineFragmentTree.node(atIndex: lineFragment.index - 1)
                let newNode = lineFragmentTree.insertNode(value: length, data: data, after: thisPreviousNode)
                newNode.updateTotalLineFragmentHeight()
                previousNode = newNode
                _lineHeight = nil
            }
        }
    }

    private func createLineSyntaxHighlightInput() -> LineSyntaxHighlighterInput? {
        if let attributedString = attributedString {
            let byteRange = line.data.totalByteRange
            return LineSyntaxHighlighterInput(attributedString: attributedString, byteRange: byteRange)
        } else {
            return nil
        }
    }

    private func lineFragmentController(for lineFragment: LineFragment) -> LineFragmentController {
        if let lineFragmentController = lineFragmentControllers[lineFragment.id] {
            lineFragmentController.lineFragment = lineFragment
            return lineFragmentController
        } else {
            let lineFragmentController = LineFragmentController(
                lineFragment: lineFragment,
                invisibleCharacterConfiguration: invisibleCharacterConfiguration
            )
            lineFragmentController.delegate = self
            lineFragmentControllers[lineFragment.id] = lineFragmentController
            applyTheme(to: lineFragmentController)
            return lineFragmentController
        }
    }

    private func redisplayLineFragments() {
        let typesetLength = typesetter.typesetLength
        _lineHeight = nil
        updateTypesetterIfNecessary()
        let newLineFragments = typesetter.typesetLineFragments(toLocation: typesetLength)
        updateLineHeight(for: newLineFragments)
        reapplyLineFragmentToLineFragmentControllers()
        setNeedsDisplayOnLineFragmentViews()
    }

    private func reapplyLineFragmentToLineFragmentControllers() {
        for (_, lineFragmentController) in lineFragmentControllers {
            let lineFragmentID = lineFragmentController.lineFragment.id
            if let lineFragment = typesetter.lineFragment(withID: lineFragmentID) {
                lineFragmentController.lineFragment = lineFragment
            }
        }
    }

    private func lineFragmentControllers<T: RedBlackTreeSearchQuery>(matching query: T)
    -> [LineFragmentController] where T.NodeID == LineFragmentNodeID, T.NodeValue == Int, T.NodeData == LineFragmentNodeData {
        let queryResult = lineFragmentTree.search(using: query)
        return queryResult.compactMap { match in
            if let lineFragment = match.node.data.lineFragment {
                return lineFragmentController(for: lineFragment)
            } else {
                return nil
            }
        }
    }

    private func applyThemeToAllLineFragmentControllers() {
        for (_, lineFragmentController) in lineFragmentControllers {
            applyTheme(to: lineFragmentController)
        }
    }

    private func applyTheme(to lineFragmentController: LineFragmentController) {
        lineFragmentController.markedTextBackgroundColor = theme.markedTextBackgroundColor
        lineFragmentController.markedTextBackgroundCornerRadius = theme.markedTextBackgroundCornerRadius
    }

    private func lineFragment(closestTo point: CGPoint) -> LineFragment? {
        var closestLineFragment = typesetter.lineFragments.last
        for lineFragment in typesetter.lineFragments {
            let lineMaxY = lineFragment.yPosition + lineFragment.scaledSize.height
            if point.y <= lineMaxY {
                closestLineFragment = lineFragment
                break
            }
        }
        return closestLineFragment
    }
}

// MARK: - UITextInput
extension LineController {
    func caretRect(atIndex lineLocalLocation: Int) -> CGRect {
        for lineFragment in typesetter.lineFragments {
            if let caretLocation = lineFragment.caretLocation(forLineLocalLocation: lineLocalLocation) {
                let xPosition = CTLineGetOffsetForStringIndex(lineFragment.line, caretLocation, nil)
                let yPosition = lineFragment.yPosition + (lineFragment.scaledSize.height - lineFragment.baseSize.height) / 2
                return CGRect(x: xPosition, y: yPosition, width: Caret.width, height: lineFragment.baseSize.height)
            }
        }
        let yPosition = (estimatedLineFragmentHeight * lineFragmentHeightMultiplier - estimatedLineFragmentHeight) / 2
        return CGRect(x: 0, y: yPosition, width: Caret.width, height: estimatedLineFragmentHeight)
    }

    func firstRect(for lineLocalRange: NSRange) -> CGRect {
        for lineFragment in typesetter.lineFragments {
            if let caretRange = lineFragment.caretRange(forLineLocalRange: lineLocalRange) {
                let finalIndex = min(lineFragment.visibleRange.upperBound, caretRange.upperBound)
                let xStart = CTLineGetOffsetForStringIndex(lineFragment.line, caretRange.location, nil)
                let xEnd = CTLineGetOffsetForStringIndex(lineFragment.line, finalIndex, nil)
                let yPosition = lineFragment.yPosition + (lineFragment.scaledSize.height - lineFragment.baseSize.height) / 2
                return CGRect(x: xStart, y: yPosition, width: xEnd - xStart, height: lineFragment.baseSize.height)
            }
        }
        return CGRect(x: 0, y: 0, width: 0, height: estimatedLineFragmentHeight * lineFragmentHeightMultiplier)
    }

    func closestIndex(to point: CGPoint) -> Int {
        guard let closestLineFragment = lineFragment(closestTo: point) else {
            return line.location
        }
        let localLocation = min(CTLineGetStringIndexForPosition(closestLineFragment.line, point), line.data.length)
        return line.location + localLocation
    }
}

// MARK: - LineFragmentControllerDelegate
extension LineController: LineFragmentControllerDelegate {
    func string(in controller: LineFragmentController) -> String? {
        let lineFragment = controller.lineFragment
        let range = NSRange(location: line.location + lineFragment.visibleRange.location, length: lineFragment.visibleRange.length)
        return stringView.substring(in: range)
    }
}
