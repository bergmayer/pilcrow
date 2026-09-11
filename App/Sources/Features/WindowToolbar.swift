import SwiftUI

// `ToolbarSlot`, `toolbarSymbol`, and `ToolbarConfig` live in
// ToolbarConfig.swift. `ToolbarSymbolPicker` lives in its own file.
// `ToolbarSlotEditor` + `iconPickerRow` live in ToolbarSlotEditor.swift.

// MARK: - Toolbar view

/// Title + a horizontal pill of SF Symbol buttons on the same line,
/// collapsing what would otherwise be two stacked rows (system nav
/// bar + custom toolbar). Overflow folds into a trailing `+` menu.
struct WindowToolbar: View {

    /// Nil on the start screen or file browser, where there is no
    /// document title to rename or save yet.
    let title: String?
    let subtitle: String
    /// Claims focus on the bus before any toolbar action fires, so
    /// a stale `currentEditor` doesn't land sheets / pickers in the
    /// wrong window.
    let onInteraction: (() -> Void)?

    @State private var config = ToolbarConfig.shared
    @State private var editing: EditingSlot?

    /// Glyph size; touch target is bigger (see `ToolbarSlotButton`).
    static let buttonSize: CGFloat = 30
    /// iPad HIG minimum — 44×44 pt would also be valid; 38 reads
    /// better in the pill at our point size.
    static let touchTarget: CGFloat = 38
    private static let buttonSpacing: CGFloat = 2
    private static let pillInsetH: CGFloat = 6
    private static let pillInsetV: CGFloat = 4
    private static let outerPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 6
    /// Keeps the last visible item from butting against the `+`.
    private static let overflowSlot: CGFloat = touchTarget + buttonSpacing

    let onToggleSidebar: () -> Void

    init(
        title: String?, subtitle: String, onInteraction: (() -> Void)? = nil,
        onToggleSidebar: @escaping () -> Void = { CommandActions.toggleSidebar() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onInteraction = onInteraction
        self.onToggleSidebar = onToggleSidebar
    }

    var body: some View {
        GeometryReader { proxy in
            // iPad scene chrome (●●● stoplight) takes the top-left
            // — ~60 pt + breathing room so the title isn't behind it.
            let stoplightInset: CGFloat = 70
            // Mirror inset for the centered pill: 2× this keeps the
            // pill symmetric around the midpoint without crashing
            // into the undo + palette cluster.
            let trailingZone = Self.touchTarget * 2 + Self.buttonSpacing + Self.outerPadding
            // 600 = iPhone Plus landscape. Below that the centered
            // pill would overlap the title (it claims 60% of width
            // and the title's flex zone goes negative), so collapse
            // every slot into the overflow.
            let compact = proxy.size.width < 600
            if compact {
                compactBody(stoplightInset: stoplightInset)
            } else {
                regularBody(proxy: proxy,
                            stoplightInset: stoplightInset,
                            trailingZone: trailingZone)
            }
        }
        .frame(height: Self.touchTarget + Self.pillInsetV * 2 + Self.verticalPadding * 2)
        .sheet(item: $editing) { editing in
            ToolbarSlotEditor(slotIndex: editing.index, initial: editing.slot)
        }
    }

    /// Centered pill flanked by title + trailing controls.
    @ViewBuilder
    private func regularBody(
        proxy: GeometryProxy,
        stoplightInset: CGFloat,
        trailingZone: CGFloat
    ) -> some View {
        let estimatedPill = min(
            CGFloat(config.slots.count + 1) * (Self.touchTarget + Self.buttonSpacing) + Self.pillInsetH * 2,
            proxy.size.width * 0.6,
            max(0, proxy.size.width - 2 * (stoplightInset + trailingZone))
        )
        let titleAvailable = max(60, (proxy.size.width - estimatedPill) / 2 - stoplightInset - 12)
        let fitCount = visibleCount(forPillInteriorWidth: estimatedPill - Self.pillInsetH * 2)
        let visible = Array(config.slots.prefix(fitCount))
        let overflow = Array(config.slots.dropFirst(fitCount))
        ZStack(alignment: .center) {
            HStack(spacing: 8) {
                sidebarButton
                    .padding(.leading, stoplightInset)
                titleBlock
                    .frame(maxWidth: max(60, titleAvailable - Self.touchTarget - 8),
                           alignment: .leading)
                Spacer(minLength: 0)
            }
            pill(visible: visible, overflow: overflow)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                trailingControls
                    .padding(.trailing, Self.outerPadding)
            }
        }
        .padding(.vertical, Self.verticalPadding)
    }

    /// Narrow / Split-View / Stage-Manager-skinny — drops the pill;
    /// every slot folds into a single trailing-edge overflow menu.
    @ViewBuilder
    private func compactBody(stoplightInset: CGFloat) -> some View {
        // Narrow floating windows still have native window controls. Keep
        // their inset and move the sidebar action into the overflow so the
        // document title has room beside Undo, Redo, and the palette.
        HStack(spacing: 6) {
            titleBlock
                .layoutPriority(1)
            Spacer(minLength: 0)
            compactOverflowMenu
            trailingControls
                .padding(.trailing, Self.outerPadding)
        }
        .padding(.leading, stoplightInset)
        .padding(.vertical, Self.verticalPadding)
    }

    @ViewBuilder
    private var compactOverflowMenu: some View {
        Menu {
            Button {
                onInteraction?()
                onToggleSidebar()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            Divider()
            ForEach(Array(config.slots.enumerated()), id: \.element.id) { _, slot in
                if let cmd = CommandRegistry.lookup(id: slot.commandId) {
                    Button {
                        onInteraction?()
                        if cmd.isEnabled() { cmd.action() }
                    } label: {
                        Label(cmd.title, systemImage: slot.symbol.isEmpty ? "questionmark" : slot.symbol)
                    }
                    .disabled(!cmd.isEnabled())
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: Self.touchTarget, height: Self.touchTarget)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("More toolbar actions")
    }

    /// Tap / context-menu / inline-rename behaviour is shared with
    /// the iPhone nav-bar principal item via `EditableTitleView`.
    @ViewBuilder
    private var titleBlock: some View {
        if let title {
            EditableTitleView(
                title: title,
                subtitle: subtitle,
                titleFont: .system(size: Self.buttonSize * 0.45, weight: .semibold),
                subtitleFont: .caption,
                maxRenameWidth: 280,
                // Same per-window focus claim as the toolbar buttons —
                // without this, title-tap Save As lands in whichever
                // window `currentEditor` happens to point at.
                onInteraction: onInteraction
            )
            .accessibilityIdentifier("window-document-title")
        } else {
            Text("Pilcrow")
                .font(.system(size: Self.buttonSize * 0.45, weight: .semibold))
        }
    }

    @ViewBuilder
    private var sidebarButton: some View {
        bareButton(symbol: "sidebar.left", help: "Toggle Sidebar") {
            onToggleSidebar()
        }
    }

    /// Undo and Command Palette stay available beside the custom tools.
    /// New Tab and Tab Overview live together in the persistent tab strip.
    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: Self.buttonSpacing) {
            bareButton(symbol: "arrow.uturn.backward", help: "Undo") {
                CommandActions.undo()
            }
            bareButton(symbol: "arrow.uturn.forward", help: "Redo") {
                CommandActions.redo()
            }
            bareButton(symbol: "command.square", help: "Command Palette") {
                CommandActions.presentCommandPalette()
            }
        }
    }

    @ViewBuilder
    private func bareButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            // Claim focus first so the action's sheet/window lands
            // on this scene and not whichever was last in scenePhase.
            onInteraction?()
            action()
        }) {
            Image(systemName: symbol)
                .font(.system(size: Self.buttonSize * 0.5, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: Self.touchTarget, height: Self.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func pill(visible: [ToolbarSlot], overflow: [ToolbarSlot]) -> some View {
        HStack(spacing: Self.buttonSpacing) {
            ForEach(visible) { slot in
                ToolbarSlotButton(
                    slot: slot,
                    command: CommandRegistry.lookup(id: slot.commandId),
                    onLongPress: { editSlot(slot) },
                    onInteraction: onInteraction
                )
            }
            if !overflow.isEmpty {
                overflowMenu(items: overflow)
            }
        }
        .padding(.horizontal, Self.pillInsetH)
        .padding(.vertical, Self.pillInsetV)
        .background(.bar, in: .capsule)
        .overlay(
            Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    /// Reserves space for the `+` button only when the slots
    /// actually overflow; otherwise returns the full count so the
    /// `+` doesn't render.
    private func visibleCount(forPillInteriorWidth interior: CGFloat) -> Int {
        let total = config.slots.count
        guard total > 0, interior > 0 else { return 0 }
        let perItem = Self.touchTarget + Self.buttonSpacing
        let allFit = CGFloat(total) * perItem - Self.buttonSpacing
        if allFit <= interior { return total }
        let usable = interior - Self.overflowSlot
        let count = max(0, Int(floor((usable + Self.buttonSpacing) / perItem)))
        return min(count, total)
    }

    @ViewBuilder
    private func overflowMenu(items: [ToolbarSlot]) -> some View {
        Menu {
            ForEach(items) { slot in
                if let cmd = CommandRegistry.lookup(id: slot.commandId) {
                    Button {
                        onInteraction?()
                        if cmd.isEnabled() { cmd.action() }
                    } label: {
                        Label(cmd.title, systemImage: slot.symbol.isEmpty ? "questionmark" : slot.symbol)
                    }
                    .disabled(!cmd.isEnabled())
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Self.buttonSize * 0.45, weight: .regular))
                .frame(width: Self.touchTarget, height: Self.touchTarget)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
    }

    private func editSlot(_ slot: ToolbarSlot) {
        guard let index = config.slots.firstIndex(where: { $0.id == slot.id }) else { return }
        editing = EditingSlot(index: index, slot: slot)
    }

    private struct EditingSlot: Identifiable {
        let index: Int
        let slot: ToolbarSlot
        var id: String { "\(index)|\(slot.id)" }
    }
}

private struct ToolbarSlotButton: View {

    let slot: ToolbarSlot
    let command: EditorCommandSpec?
    let onLongPress: () -> Void
    let onInteraction: (() -> Void)?

    private var isEnabled: Bool { command?.isEnabled() ?? false }
    private var symbolName: String { slot.symbol.isEmpty ? "questionmark.square.dashed" : slot.symbol }

    /// A long press that opened the slot editor also delivers the
    /// Button action on finger release — consume that one tap.
    @State private var longPressFired = false

    var body: some View {
        Button {
            if longPressFired {
                longPressFired = false
                return
            }
            onInteraction?()
            if let cmd = command, cmd.isEnabled() { cmd.action() }
        } label: {
            toolbarSymbol(symbolName, size: WindowToolbar.buttonSize * 0.5)
                .frame(width: WindowToolbar.touchTarget, height: WindowToolbar.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .help(command?.title ?? slot.commandId)
        .accessibilityLabel(command?.title ?? slot.commandId)
        // Long-press opens the per-slot editor. Settings ▸ Toolbar
        // is the canonical customization UI.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                longPressFired = true
                onLongPress()
            }
        )
    }
}

// `ToolbarSymbolLibrary` + `ToolbarSymbolPicker` live in
// ToolbarSymbolPicker.swift. `iconPickerRow` + `ToolbarSlotEditor`
// live in ToolbarSlotEditor.swift.
