import UIKit
import EditorEngine
import GameController

/// iPhone uses a per-textView `inputAccessoryView`; iPad uses the
/// keyboard's own QuickType strip via `inputAssistantItem` (an
/// `inputAccessoryView` on iPad bleeds across windows in Stage
/// Manager). Hardware-keyboard attach clears both, observed via
/// `GameController`.
@MainActor
enum KeyboardAccessoryBar {

    static func install(on textView: EditorEngine.TextView) {
        Self.refresh(textView)
        Self.attachHardwareKeyboardObserver(for: textView)
    }

    private static func refresh(_ textView: EditorEngine.TextView) {
        #if DEBUG
        let hasHardwareKeyboard = GCKeyboard.coalesced != nil && !ProcessInfo.processInfo.arguments.contains("--ui-test-software-keyboard")
        #else
        let hasHardwareKeyboard = GCKeyboard.coalesced != nil
        #endif
        let assistant = textView.inputAssistantItem

        if hasHardwareKeyboard {
            // Hardware-keyboard mode → no soft keyboard, no accessory.
            textView.inputAccessoryView = nil
            // An empty UIBarButtonItemGroup is not a valid shortcut
            // container on current iOS releases and makes UIKit repeatedly
            // try to install a handler for an item at index zero. Clear the
            // public arrays instead and let the assistant hide its shortcuts.
            assistant.leadingBarButtonGroups = []
            assistant.trailingBarButtonGroups = []
            assistant.allowsHidingShortcuts = true
            detachIPadObserver(from: textView)
            return
        }

        if DeviceIdiom.isPhone {
            if !(textView.inputAccessoryView is EditorAccessoryView) {
                textView.inputAccessoryView = EditorAccessoryView(host: textView)
            }
            assistant.leadingBarButtonGroups = []
            assistant.trailingBarButtonGroups = []
            assistant.allowsHidingShortcuts = true
            detachIPadObserver(from: textView)
        } else {
            textView.inputAccessoryView = nil
            assistant.allowsHidingShortcuts = true
            let observer = IPadAccessoryObserver(host: textView)
            assistant.leadingBarButtonGroups = [
                UIBarButtonItemGroup(barButtonItems: observer.leadingItems, representativeItem: nil)
            ]
            assistant.trailingBarButtonGroups = [
                UIBarButtonItemGroup(barButtonItems: observer.trailingItems, representativeItem: nil)
            ]
            attachIPadObserver(observer, to: textView)
        }
    }

    private static func attachHardwareKeyboardObserver(for textView: EditorEngine.TextView) {
        let holder = KeyboardObserverHolder { [weak textView] in
            guard let textView else { return }
            Self.refresh(textView)
        }
        objc_setAssociatedObject(textView, &observerKey, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

}

private nonisolated(unsafe) var observerKey: UInt8 = 0
private nonisolated(unsafe) var ipadObserverKey: UInt8 = 0

@MainActor
private func attachIPadObserver(_ observer: IPadAccessoryObserver, to textView: EditorEngine.TextView) {
    objc_setAssociatedObject(textView, &ipadObserverKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@MainActor
private func detachIPadObserver(from textView: EditorEngine.TextView) {
    objc_setAssociatedObject(textView, &ipadObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Retained on the text view via objc-associated object; tint
/// mirroring runs on a 100ms polling timer.
@MainActor
private final class IPadAccessoryObserver {

    weak var host: EditorEngine.TextView?
    let leadingItems: [UIBarButtonItem]
    let trailingItems: [UIBarButtonItem]
    private weak var controlItem: UIBarButtonItem?
    private weak var optionItem: UIBarButtonItem?
    private weak var commandItem: UIBarButtonItem?
    /// `nonisolated(unsafe)` so the nonisolated deinit can release
    /// the timer. Timer isn't Sendable but we mutate only on main.
    /// it from the main actor (init / DispatchQueue.main from deinit).
    nonisolated(unsafe) private var timer: Timer?

    init(host: EditorEngine.TextView) {
        self.host = host

        let control = Self.barItem(symbol: "control", accessibility: "Control") { [weak host] _ in
            Self.toggleModifier(\.armedAccessoryControl, host: host)
        }
        let option = Self.barItem(symbol: "option", accessibility: "Option") { [weak host] _ in
            Self.toggleModifier(\.armedAccessoryOption, host: host)
        }
        let command = Self.barItem(symbol: "command", accessibility: "Command") { [weak host] _ in
            Self.toggleModifier(\.armedAccessoryCommand, host: host)
        }

        let lineStart = Self.barItem(symbol: "arrow.left.to.line", accessibility: "Start of Line") { [weak host] _ in
            CaretMover.moveToLineStart(in: host)
        }
        let lineEnd = Self.barItem(symbol: "arrow.right.to.line", accessibility: "End of Line") { [weak host] _ in
            CaretMover.moveToLineEnd(in: host)
        }
        let docStart = Self.barItem(symbol: "arrow.up.to.line", accessibility: "Start of Document") { [weak host] _ in
            CaretMover.moveToDocumentStart(in: host)
        }
        let docEnd = Self.barItem(symbol: "arrow.down.to.line", accessibility: "End of Document") { [weak host] _ in
            CaretMover.moveToDocumentEnd(in: host)
        }

        // iPad keyboard ships its own dismiss key (bottom-right);
        // no chevron-down needed here.
        self.leadingItems = [lineStart, lineEnd, docStart, docEnd]
        let spaceWidth: CGFloat = 18
        let s1 = UIBarButtonItem(systemItem: .fixedSpace); s1.width = spaceWidth
        let s2 = UIBarButtonItem(systemItem: .fixedSpace); s2.width = spaceWidth
        self.trailingItems = [control, s1, option, s2, command]
        self.controlItem = control
        self.optionItem = option
        self.commandItem = command

        refreshModifierVisuals()
        // Polls the engine for armed-flag clears; observation
        // channel doesn't exist for the engine's consume step.
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshModifierVisuals() }
        }
        t.tolerance = 0.04
        self.timer = t
    }

    deinit {
        // Timer must invalidate on the thread that scheduled it.
        let captured = timer
        DispatchQueue.main.async { captured?.invalidate() }
    }

    private func refreshModifierVisuals() {
        guard let state = host?.editorState else { return }
        controlItem?.tintColor = state.armedAccessoryControl ? .systemBlue : nil
        optionItem?.tintColor = state.armedAccessoryOption ? .systemBlue : nil
        commandItem?.tintColor = state.armedAccessoryCommand ? .systemBlue : nil
    }

    private static func barItem(
        symbol: String,
        accessibility: String,
        handler: @escaping (UIAction) -> Void
    ) -> UIBarButtonItem {
        let action = UIAction(title: accessibility, image: UIImage(systemName: symbol), handler: handler)
        let bar = UIBarButtonItem(primaryAction: action)
        bar.accessibilityLabel = accessibility
        return bar
    }

    private static func toggleModifier(
        _ keyPath: ReferenceWritableKeyPath<EditorState, Bool>,
        host: EditorEngine.TextView?
    ) {
        guard let state = host?.editorState else { return }
        state[keyPath: keyPath].toggle()
    }


}

private final class KeyboardObserverHolder: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    init(_ refresh: @escaping @MainActor () -> Void) {
        let center = NotificationCenter.default
        let connect = center.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { _ in Task { @MainActor in refresh() } }
        let disconnect = center.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { _ in Task { @MainActor in refresh() } }
        tokens = [connect, disconnect]
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }
}

// MARK: - Caret movement helpers

@MainActor
enum CaretMover {
    static func move(in textView: EditorEngine.TextView?, by offset: Int) {
        guard let textView else { return }
        let length = (textView.text as NSString).length
        let cursor = textView.selectedRange.location + offset
        let clamped = max(0, min(length, cursor))
        textView.selectedRange = NSRange(location: clamped, length: 0)
    }

    static func moveToLineStart(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        let nsText = textView.text as NSString
        let line = nsText.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        textView.selectedRange = NSRange(location: line.location, length: 0)
    }

    static func moveToLineEnd(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        let nsText = textView.text as NSString
        let line = nsText.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        var endOfLine = line.location + line.length
        if endOfLine > line.location {
            let lastChar = nsText.substring(with: NSRange(location: endOfLine - 1, length: 1))
            if lastChar == "\n" || lastChar == "\r" { endOfLine -= 1 }
        }
        textView.selectedRange = NSRange(location: endOfLine, length: 0)
    }

    static func moveToDocumentStart(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        textView.selectedRange = NSRange(location: 0, length: 0)
    }

    static func moveToDocumentEnd(in textView: EditorEngine.TextView?) {
        guard let textView else { return }
        let length = (textView.text as NSString).length
        textView.selectedRange = NSRange(location: length, length: 0)
    }

    static func moveCursor(in textView: EditorEngine.TextView?, byLines lineDelta: Int) {
        guard let textView, lineDelta != 0 else { return }
        for _ in 0..<abs(lineDelta) {
            moveOneLine(in: textView, downward: lineDelta > 0)
        }
    }

    private static func moveOneLine(in textView: EditorEngine.TextView, downward: Bool) {
        let nsText = textView.text as NSString
        let cursor = textView.selectedRange.location
        let currentLine = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let column = cursor - currentLine.location

        if downward {
            let nextStart = currentLine.location + currentLine.length
            guard nextStart < nsText.length else {
                textView.selectedRange = NSRange(location: nsText.length, length: 0)
                return
            }
            let nextLine = nsText.lineRange(for: NSRange(location: nextStart, length: 0))
            let nextLen = max(0, nextLine.length - 1)
            let target = nextLine.location + min(column, nextLen)
            textView.selectedRange = NSRange(location: min(target, nsText.length), length: 0)
        } else {
            guard currentLine.location > 0 else {
                textView.selectedRange = NSRange(location: 0, length: 0)
                return
            }
            let prevLine = nsText.lineRange(for: NSRange(location: currentLine.location - 1, length: 0))
            let prevLen = max(0, prevLine.length - 1)
            let target = prevLine.location + min(column, prevLen)
            textView.selectedRange = NSRange(location: target, length: 0)
        }
    }

    /// Skips whitespace then the next word, matching ⌥← / ⌥→.
    static func moveWord(in textView: EditorEngine.TextView?, forward: Bool) {
        guard let textView else { return }
        let nsText = textView.text as NSString
        let length = nsText.length
        guard length > 0 else { return }
        let cursor = textView.selectedRange.location
        let idx = forward
            ? nextWordEnd(in: nsText, from: cursor)
            : previousWordStart(in: nsText, from: cursor)
        textView.selectedRange = NSRange(location: idx, length: 0)
    }

    private static func nextWordEnd(in text: NSString, from location: Int) -> Int {
        var location = location
        while location < text.length, !isWordCharacter(text.character(at: location)) {
            location += 1
        }
        while location < text.length, isWordCharacter(text.character(at: location)) {
            location += 1
        }
        return location
    }

    private static func previousWordStart(in text: NSString, from location: Int) -> Int {
        var location = location
        while location > 0, !isWordCharacter(text.character(at: location - 1)) {
            location -= 1
        }
        while location > 0, isWordCharacter(text.character(at: location - 1)) {
            location -= 1
        }
        return location
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        (character >= 0x30 && character <= 0x39)
            || (character >= 0x41 && character <= 0x5A)
            || (character >= 0x61 && character <= 0x7A)
            || character == 0x5F
    }
}

// MARK: - Armed modifier dispatch

@MainActor
enum AccessoryKeyboard {

    /// Sticky modifiers are consumed before dispatch, since actions such as
    /// Paste can re-enter the text-input delegate.
    static func handleArmedKey(_ text: String, state: EditorState) -> Bool {
        guard let engine = state.textView else { return false }
        var modifiers: UIKeyModifierFlags = []
        if state.armedAccessoryCommand { modifiers.insert(.command) }
        if state.armedAccessoryControl { modifiers.insert(.control) }
        if state.armedAccessoryOption { modifiers.insert(.alternate) }
        guard !modifiers.isEmpty else { return false }
        state.armedAccessoryCommand = false
        state.armedAccessoryControl = false
        state.armedAccessoryOption = false

        if text != text.lowercased() { modifiers.insert(.shift) }
        let chord = EditorKeyChord(key: text, modifiers: modifiers)
        CommandActions.perform(for: state) {
            if let command = command(for: chord) {
                if command.isEnabled() { command.action() }
            } else if (modifiers == .command && text == ";") || (modifiers == .control && text.lowercased() == "p") {
                CommandActions.presentCommandPalette()
            } else if modifiers == .control {
                _ = handleControlKey(text.lowercased(), engine: engine)
            } else if modifiers == .alternate {
                _ = handleOptionKey(text.lowercased(), engine: engine)
            }
        }
        // An unassigned or disabled shortcut must not insert its letter.
        return true
    }

    static func command(for chord: EditorKeyChord) -> EditorCommandSpec? {
        func match(_ chord: EditorKeyChord) -> EditorCommandSpec? {
            CommandRegistry.all().first { command in
                command.shortcutHint.flatMap(EditorKeyChord.init(hint:)) == chord
            }
        }
        if let command = match(chord) { return command }
        let shiftedPunctuation = ["\"": "'", "_": "-", "{": "[", "}": "]", "|": "\\", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"]
        if let base = shiftedPunctuation[chord.key],
           let command = match(EditorKeyChord(key: base, modifiers: chord.modifiers.union(.shift))) {
            return command
        }
        // Auto-capitalization can uppercase the soft key without changing
        // the intended shortcut. Prefer an explicit Shift binding first.
        if chord.modifiers.contains(.shift) {
            return match(EditorKeyChord(key: chord.key, modifiers: chord.modifiers.subtracting(.shift)))
        }
        return nil
    }

    private static func handleControlKey(_ lower: String, engine: PilcrowTextView?) -> Bool {
        if handleControlEditingKey(lower) {
            return true
        }
        return handleControlNavigationKey(lower, engine: engine)
    }

    private static func handleControlEditingKey(_ lower: String) -> Bool {
        switch lower {
        case "k": CommandActions.deleteToEndOfLine();       return true
        case "t": CommandActions.transposeCharacters();     return true
        case "j": CommandActions.joinLines();               return true
        case "d": CommandActions.deleteWordForward();       return true
        case "h": CommandActions.deleteWordBackward();      return true
        default:  return false
        }
    }

    private static func handleControlNavigationKey(
        _ lower: String,
        engine: PilcrowTextView?
    ) -> Bool {
        switch lower {
        case "a": CommandActions.smartMoveToLineStart();    return true
        case "e": CaretMover.moveToLineEnd(in: engine);     return true
        case "f": CaretMover.move(in: engine, by: 1);       return true
        case "b": CaretMover.move(in: engine, by: -1);      return true
        case "n": CaretMover.moveCursor(in: engine, byLines: 1);  return true
        case "p": CaretMover.moveCursor(in: engine, byLines: -1); return true
        default:  return false
        }
    }

    private static func handleOptionKey(_ lower: String, engine: PilcrowTextView?) -> Bool {
        switch lower {
        case "b":
            CaretMover.moveWord(in: engine, forward: false)
            return true
        case "f":
            CaretMover.moveWord(in: engine, forward: true)
            return true
        case "h":
            CommandActions.deleteWordBackward()
            return true
        case "d":
            CommandActions.deleteWordForward()
            return true
        default:
            return false
        }
    }
}

// MARK: - Accessory view (iPhone)

@MainActor
final class EditorAccessoryView: UIInputView {

    weak var host: EditorEngine.TextView?

    private let row = AccessoryRow()
    private weak var controlButton: AccessoryButton?
    private weak var commandButton: AccessoryButton?
    private weak var optionButton: AccessoryButton?
    /// `nonisolated(unsafe)` so the nonisolated deinit can release
    /// the timer; mirrors `IPadAccessoryObserver`. Without the
    /// invalidate, the run loop retains a 10 Hz timer per closed
    /// editor forever.
    nonisolated(unsafe) private var stateTimer: Timer?

    private static let rowHeight: CGFloat = 44

    init(host: EditorEngine.TextView) {
        self.host = host
        // `.default` style + an explicit background colour gives a
        // flush fit against the keyboard. `.keyboard` style adds a
        // blur material with internal padding that introduces a
        // ~20 pt gap above the keys. Width is 0 here — the
        // `.flexibleWidth` autoresizing mask below stretches us to
        // the keyboard's frame at install time, so the seed value
        // doesn't matter.
        super.init(frame: CGRect(x: 0, y: 0,
                                 width: 0,
                                 height: Self.rowHeight),
                   inputViewStyle: .default)
        backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.secondarySystemBackground
                : UIColor(white: 0.82, alpha: 1.0)
        }
        autoresizingMask = [.flexibleWidth]
        row.setButtons(makeButtons())
        layout()
        refreshModifierVisuals()
        startStateObserver()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // Timer must invalidate on the thread that scheduled it.
        let captured = stateTimer
        DispatchQueue.main.async { captured?.invalidate() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.rowHeight)
    }

    private func layout() {
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        ])
    }

    private func makeButtons() -> [AccessoryButton] {
        var buttons: [AccessoryButton] = []

        // Sticky modifier cluster (⌃ ⌥ ⌘): tap arms; consumed by the
        // next key on the iOS keyboard. Modifiers can be combined.
        // Shift isn't a button — the iOS
        // keyboard's own shift handles capitalization and the
        // engine reads the resulting case to detect ⌘⇧ shortcuts.
        // IMPORTANT: hold each button in a local `let` before writing
        // to the `weak` ivar — otherwise the autoreleased return
        // value dies before the array append and the weak ref nils
        // out, crashing the next force-unwrap.
        let control = modifierButton(symbol: "control",
                                     label: "Control",
                                     keyPath: \.armedAccessoryControl)
        controlButton = control
        buttons.append(control)

        let option = modifierButton(symbol: "option",
                                    label: "Option",
                                    keyPath: \.armedAccessoryOption)
        optionButton = option
        buttons.append(option)

        let command = modifierButton(symbol: "command",
                                     label: "Command",
                                     keyPath: \.armedAccessoryCommand)
        commandButton = command
        buttons.append(command)

        // Line / document cursor jumps
        buttons.append(button(symbol: "arrow.left.to.line", label: "Start of Line") { [weak self] in
            CaretMover.moveToLineStart(in: self?.host)
        })
        buttons.append(button(symbol: "arrow.right.to.line", label: "End of Line") { [weak self] in
            CaretMover.moveToLineEnd(in: self?.host)
        })
        buttons.append(button(symbol: "arrow.up.to.line", label: "Start of Document") { [weak self] in
            CaretMover.moveToDocumentStart(in: self?.host)
        })
        buttons.append(button(symbol: "arrow.down.to.line", label: "End of Document") { [weak self] in
            CaretMover.moveToDocumentEnd(in: self?.host)
        })

        // Dismiss keyboard at the tail.
        buttons.append(button(symbol: "chevron.down", label: "Hide Keyboard") { [weak self] in
            self?.host?.resignFirstResponder()
        })

        return buttons
    }

    /// Modifiers can be combined, then clear after the next key.
    private func modifierButton(
        symbol: String,
        label: String,
        keyPath: ReferenceWritableKeyPath<EditorState, Bool>
    ) -> AccessoryButton {
        button(symbol: symbol, label: label) { [weak self] in
            guard let self, let state = self.host?.editorState else { return }
            state[keyPath: keyPath].toggle()
            self.refreshModifierVisuals()
        }
    }

    private func refreshModifierVisuals() {
        let state = host?.editorState
        controlButton?.isToggled = state?.armedAccessoryControl ?? false
        commandButton?.isToggled = state?.armedAccessoryCommand ?? false
        optionButton?.isToggled  = state?.armedAccessoryOption ?? false
    }

    /// Polls so the engine clearing the armed flags (after consuming
    /// a key) refreshes the button visuals. CADisplayLink is overkill
    /// for a 100 ms cadence.
    private func startStateObserver() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshModifierVisuals() }
        }
        timer.tolerance = 0.04
        stateTimer = timer
    }

    // MARK: Button factory

    private func button(symbol: String,
                        label: String,
                        action: @escaping () -> Void) -> AccessoryButton {
        let btn = AccessoryButton()
        btn.configure(symbol: symbol, accessibility: label)
        btn.tapAction = action
        return btn
    }
}

// MARK: - Row

@MainActor
private final class AccessoryRow: UIView {

    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceHorizontal = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.isLayoutMarginsRelativeArrangement = true
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.layoutIfNeeded()
        let horizontalInset = max(0, (scroll.bounds.width - stack.bounds.width) / 2)
        if scroll.contentInset.left != horizontalInset {
            scroll.contentInset = UIEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
            scroll.contentOffset = CGPoint(x: -horizontalInset, y: 0)
        }
    }

    func setButtons(_ buttons: [AccessoryButton]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for btn in buttons { stack.addArrangedSubview(btn) }
    }
}

// MARK: - Button

@MainActor
final class AccessoryButton: UIControl {

    private let symbolView = UIImageView()
    var tapAction: (() -> Void)?

    var isToggled: Bool = false {
        didSet { updateAppearance() }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .label
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 17, weight: .regular
        )
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, accessibility: String) {
        symbolView.image = UIImage(systemName: symbol)
        accessibilityLabel = accessibility
        isAccessibilityElement = true
    }

    private func updateAppearance() {
        accessibilityTraits = isToggled ? [.button, .selected] : .button
        backgroundColor = isToggled
            ? UIColor.tintColor.withAlphaComponent(0.35)
            : UIColor.label.withAlphaComponent(0.06)
    }

    override var isHighlighted: Bool {
        didSet {
            if isHighlighted {
                backgroundColor = UIColor.label.withAlphaComponent(0.18)
            } else {
                updateAppearance()
            }
        }
    }

    @objc private func handleTap() {
        tapAction?()
    }
}

// MARK: - Helpers

private extension EditorEngine.TextView {
    /// Reach back to the `EditorState` the host owns. The accessory
    /// needs it to toggle armed modifiers.
    var editorState: EditorState? {
        AppStateBus.shared.scenes.allOpenSessions
            .flatMap(\.tabs)
            .first(where: { $0.state.textView === self })?
            .state
    }
}
