import SwiftUI
import UniformTypeIdentifiers

/// Two presentations of the same window's tabs: a horizontal strip or a
/// document list. Both share selection, close, pin, drag, and creation actions.
struct TabBarView: View {
    @Bindable var session: EditorSession
    var appearance: DocumentTabAppearance = .tabBar
    var onSelection: (() -> Void)?

    /// Leading inset that keeps the leftmost tab clear of iPad's
    /// stoplight (close / minimize / resize) chrome at the top-left
    /// of the window. Matches the inset `WindowToolbar` uses.
    private let stoplightInset: CGFloat = 70
    private let stripHeight: CGFloat = 50

    var body: some View {
        Group {
            if appearance == .sidebar {
                documentList
            } else {
                horizontalBar
            }
        }
        .dropDestination(for: String.self) { items, _ -> Bool in
            return session.acceptTabDrop(items)
        }
    }

    private var documentList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open Documents")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("\(session.tabs.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(session.tabs) { tab in
                            draggablePill(for: tab)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: session.selectedTabID, initial: true) { _, id in
                    scroll.scrollTo(id)
                }
            }
            Divider()
            HStack {
                plusButton
                Spacer()
                showAllTabsButton
            }
            .padding(.horizontal, 6)
        }
        .background(Color(.secondarySystemBackground))
        .accessibilityIdentifier("document-sidebar")
    }

    private var horizontalBar: some View {
        ZStack(alignment: .bottom) {
            Color(.secondarySystemBackground)
            // The active tab is opaque and reaches the bottom edge, hiding
            // this rule beneath itself. The visible rule under every other
            // tab makes the selected tab read as an opening into the content
            // surface rather than one more detached pill.
            Rectangle()
                .fill(Color(.separator).opacity(0.55))
                .frame(height: 0.5)
            tabStrip
                .padding(.leading, stoplightInset)
                .padding(.trailing, 8)
                .padding(.top, 6)
        }
        .frame(height: stripHeight)

    }

    @ViewBuilder
    private var tabStrip: some View {
        GeometryReader { geometry in
            let pinnedCount = session.tabs.count(where: \.isPinned)
            let flexibleCount = max(1, session.tabs.count - pinnedCount)
            let availableWidth =
                geometry.size.width - 96 - CGFloat(pinnedCount * 44)
                - CGFloat(max(0, session.tabs.count - 1) * 3)
            let tabWidth = max(120, availableWidth / CGFloat(flexibleCount))
            HStack(alignment: .bottom, spacing: 4) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(session.tabs) { tab in
                                draggablePill(for: tab)
                                    .frame(width: tab.isPinned ? 44 : tabWidth)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { scroll.scrollTo(session.selectedTabID) }
                    .onChange(of: session.selectedTabID) { _, id in
                        withAnimation { scroll.scrollTo(id) }
                    }
                }
                plusButton
                showAllTabsButton
            }
        }
    }

    @ViewBuilder
    private func draggablePill(for tab: TabModel) -> some View {
        TabPillView(
            tab: tab,
            isActive: tab.id == session.selectedTabID,
            appearance: appearance,
            onSelect: {
                AppStateBus.shared.scenes.claimFocus(session: session)
                session.selectedTabID = tab.id
                onSelection?()
            },
            onClose:  { CommandActions.requestCloseTab(tab.id, in: session) },
            onPin:    { session.togglePinned(tab.id) }
        )
        .id(tab.id)
        .draggable(tab.id.uuidString) {
            TabDragPreview(label: tabLabel(tab))
        }
        .dropDestination(for: String.self) { items, _ -> Bool in
            return session.acceptTabDrop(items, onto: tab.id)
        }
    }

    @ViewBuilder
    private var plusButton: some View {
        // Tap → new tab. Long-press → recently-closed list.
        // Implemented as a Menu with a `primaryAction` tap
        // handler so both gestures work without extra plumbing.
        Menu {
            Button {
                AppStateBus.shared.scenes.claimFocus(session: session)
                onSelection?()
                CommandActions.newFromTemplate()
            } label: {
                Label("New from Template…", systemImage: "doc.badge.plus")
            }
            Divider()
            if session.recentlyClosed.isEmpty {
                Text("No Recently Closed Tabs")
            } else {
                Section("Recently Closed") {
                    ForEach(session.recentlyClosed) { record in
                        Button {
                            AppStateBus.shared.scenes.claimFocus(session: session)
                            CommandActions.reopenClosedTab(record)
                            onSelection?()
                        } label: {
                            Label(record.displayName, systemImage: record.fileURL == nil ? "doc.text" : "doc")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(.secondary)
        } primaryAction: {
            // Route through CommandActions so +, Cmd-T, and the menus all
            // use the same to-the-right insertion rule and blank editor.
            AppStateBus.shared.scenes.claimFocus(session: session)
            CommandActions.newTab()
            onSelection?()
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("New Tab")
        .help("New Tab")
    }

    @ViewBuilder
    private var showAllTabsButton: some View {
        Button {
            AppStateBus.shared.scenes.claimFocus(session: session)
            CommandActions.showTabSwitcher()
            onSelection?()
        } label: {
            Image(systemName: "square.on.square")
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("Tab Overview")
        .accessibilityLabel("Tab Overview")
        // Long-press surfaces the multi-tab management menu. Same
        // entries as the iPhone status-bar overview button.
        .contextMenu { TabOverviewContextMenu(session: session) }
    }

    private func tabLabel(_ tab: TabModel) -> String {
        tab.document.fileURL?.lastPathComponent ?? "Untitled"
    }
}

// MARK: - Drag preview

private struct TabDragPreview: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: .capsule)
    }
}

// MARK: - Pill

private struct TabPillView: View {
    @Bindable var tab: TabModel
    let isActive: Bool
    let appearance: DocumentTabAppearance
    let onSelect: () -> Void
    let onClose: () -> Void
    let onPin: () -> Void

    var body: some View {
        Group {
            if appearance == .sidebar {
                HStack(spacing: 0) {
                    Button(action: onSelect) {
                        Label(label, systemImage: tab.isPinned ? "pin.fill" : "doc.text")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(label)")
                }
                .padding(.leading, 8)
                .background(isActive ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("document-row-\(tab.id)")
            } else {
                pill
            }
        }
        .contextMenu { contextMenu }
        .accessibilityValue(isActive ? "Active" : "Inactive")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var pill: some View {
        pillContent
            .frame(height: isActive ? 40 : 32)
            .background { pillBackground }
            .overlay { pillOutline }
            .overlay(alignment: .top) {
                if isActive {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 9)
                        .padding(.top, 2)
                }
            }
            // Inactive tabs float above the document-edge rule. Only the
            // active tab reaches through it into the content below.
            .padding(.bottom, isActive ? 0 : 4)
            .contentShape(.rect)
            .onTapGesture { onSelect() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isActive ? "Active" : "Inactive")
            .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    @ViewBuilder
    private var pillContent: some View {
        if tab.isPinned {
            pinnedChip
        } else {
            fullPill
        }
    }

    /// Pinned tab: compact favicon-style chip. No filename text, no
    /// close button. Long-press for the context menu to unpin / close.
    @ViewBuilder
    private var pinnedChip: some View {
        Image(systemName: pinnedIconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isActive ? Color.primary : .secondary)
            .frame(width: 36)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var fullPill: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            // Spacer pushes the close X to the trailing edge so the
            // pill's background actually fills the equal-width slot
            // its parent gives it. Without this, the HStack would
            // collapse to its content width.
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pillBackground: some View {
        if isActive {
            UnevenRoundedRectangle(
                topLeadingRadius: 9,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 9,
                style: .continuous
            )
            .fill(activeSurfaceColor)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.secondarySystemFill))
        }
    }

    @ViewBuilder
    private var pillOutline: some View {
        if isActive {
            ActiveTabOutline(cornerRadius: 9)
                .stroke(Color(.separator).opacity(0.8), lineWidth: 0.75)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.22), lineWidth: 0.5)
        }
    }

    /// Match the surface directly below the tab. The launcher uses grouped
    /// chrome; editors and the in-tab file browser use the standard surface.
    private var activeSurfaceColor: Color {
        switch tab.kind {
        case .launcher:
            Color(.systemGroupedBackground)
        case .editor, .fileBrowser:
            Color(.systemBackground)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onPin()
        } label: {
            Label(
                tab.isPinned ? "Unpin Tab" : "Pin Tab",
                  systemImage: tab.isPinned ? "pin.slash" : "pin")
        }
        if DeviceIdiom.supportsMultipleWindows {
            Button {
                CommandActions.moveTabToNewWindow(tab.id)
            } label: {
                Label("Move Tab to New Window", systemImage: "macwindow.badge.plus")
            }
        }
        Divider()
        Button(role: .destructive, action: onClose) {
            Label("Close This Tab", systemImage: "xmark")
        }
    }

    private var label: String {
        switch tab.kind {
        case .fileBrowser: return "New Tab"
        case .launcher:    return "Start Page"
        case .editor:
            let base = tab.document.displayName
            // Only show the unsaved-dot for genuinely dirty buffers.
            // A brand-new Untitled tab shouldn't claim edits it
            // doesn't have.
            return tab.document.isDirty ? "● \(base)" : base
        }
    }

    private var accessibilityLabel: String {
        let pinned = tab.isPinned ? "Pinned tab. " : ""
        return pinned + label
    }

    /// Pinned-chip glyph: favicon-equivalent. Browser tabs show a
    /// folder; URL-backed editor tabs show a document; unsaved
    /// scratches show a pin.
    private var pinnedIconName: String {
        switch tab.kind {
        case .fileBrowser: return "folder.fill"
        case .launcher:    return "rectangle.stack.badge.plus"
        case .editor:
            return tab.document.fileURL == nil ? "pin.fill" : "doc.text.fill"
        }
    }
}

/// Open path around the selected tab: top and sides only. Omitting the
/// bottom segment is what visually joins the tab to the document surface.
private struct ActiveTabOutline: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
