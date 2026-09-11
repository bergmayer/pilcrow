import SwiftUI
import FileEncoding
import LineEnding

struct EditorStatusBar: View {

    let document: PlainTextDocument
    @Bindable var state: EditorState
    var selection: NSRange? = nil

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if DeviceIdiom.isPhone || horizontalSizeClass == .compact {
            phoneBar
        } else {
            // Inspector / split view / Stage Manager all shrink the
            // editor's effective width without changing the window's
            // horizontalSizeClass. ViewThatFits drops to phoneBar
            // (overflow menu) when wideBar's intrinsic width would
            // overflow — same fallback the toolbar pill uses.
            ViewThatFits(in: .horizontal) {
                wideBar
                phoneBar
            }
        }
    }

    @ViewBuilder
    private var wideBar: some View {
        HStack(spacing: 12) {
            splitCycleButton
            Divider().frame(height: 14)
            // ViewThatFits drops the counts when the bar can't fit
            // them on one line — wrapping would double row height.
            ViewThatFits(in: .horizontal) {
                counts.foregroundStyle(.secondary)
                EmptyView()
            }
            Spacer(minLength: 8)
            byteCountLabel.foregroundStyle(.secondary)
            Divider().frame(height: 14)
            encodingMenu
            Divider().frame(height: 14)
            lineEndingMenu
            Divider().frame(height: 14)
            languageMenu
            Divider().frame(height: 14)
            revisionsButton
            Divider().frame(height: 14)
            infoToggle
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var phoneBar: some View {
        HStack(spacing: 16) {
            phoneTabsButton
            splitCycleButton
            Spacer()
            revisionsButton
            phoneOverflowMenu
            infoToggle
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                    if value.translation.width < -40 {
                        CommandActions.nextTab()
                    } else if value.translation.width > 40 {
                        CommandActions.previousTab()
                    }
                }
        )
    }

    @ViewBuilder
    private var phoneTabsButton: some View {
        Button {
            claimFocus()
            CommandActions.showTabSwitcher()
        } label: {
            ZStack {
                Image(systemName: "square.on.square")
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                if let count = phoneTabBadgeCount {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.thinMaterial, in: .capsule)
                        .offset(x: 10, y: -8)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show All Tabs")
        .accessibilityLabel("Show All Tabs")
        .contextMenu {
            if let session = owningSession {
                TabOverviewContextMenu(session: session)
            }
        }
    }

    /// The session whose tab strip this status bar fronts — same
    /// lookup EditorView uses. The bus's `currentSession` may point
    /// at another window when the user long-presses here.
    private var owningSession: EditorSession? {
        bus.scenes.allOpenSessions.first { $0.tabs.contains(where: { $0.state === state }) }
    }

    private var phoneTabBadgeCount: Int? {
        let count = bus.scenes.currentSession?.tabs.count ?? 1
        return count > 1 ? count : nil
    }

    @ViewBuilder
    private var phoneOverflowMenu: some View {
        Menu {
            if let stats = state.writingStatistics {
                Section("Writing Statistics") {
                    Text("\(stats.words) words · \(stats.characters) characters")
                    if stats.hasSelection {
                        Text("Selected: \(stats.selectedWords) words · \(stats.selectedCharacters) characters")
                    }
                }
            }

            Menu("Encoding")     { encodingMenuChoices }
            Menu("Line Endings") { lineEndingMenuChoices }
            Menu("Syntax")       { languageMenuChoices }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .help("Document settings")
        .accessibilityLabel("Document Settings")
    }

    @ViewBuilder
    private var splitCycleButton: some View {
        Button {
            claimFocus()
            CommandActions.cycleSplitView()
        } label: {
            Image(systemName: splitCycleSymbol)
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(splitCycleLabel)
        .help(splitCycleLabel)
    }

    private var splitCycleSymbol: String {
        switch (state.splitOpen, state.splitOrientation) {
        case (false, _):          return "rectangle"
        case (true, .horizontal): return "rectangle.split.2x1"
        case (true, .vertical):   return "rectangle.split.1x2"
        }
    }

    private var splitCycleLabel: String {
        switch (state.splitOpen, state.splitOrientation) {
        case (false, _):          return "Open Split View"
        case (true, .horizontal): return "Switch to Vertical Split"
        case (true, .vertical):   return "Close Split View"
        }
    }

    @ViewBuilder
    private var revisionsButton: some View {
        Button {
            claimFocus()
            CommandActions.presentRevisions()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                // Negative inset reaches the HIG 44pt touch target
                // without inflating the bar's intrinsic height.
                .contentShape(Rectangle().inset(by: -15))
        }
        .buttonStyle(.plain)
        .help("Browse and restore previous versions of this document")
        .accessibilityLabel("Versions")
    }

    @ViewBuilder
    private var infoToggle: some View {
        Button {
            state.inspectorOpen.toggle()
        } label: {
            Image(systemName: "info")
                .font(.system(size: 14, weight: state.inspectorOpen ? .bold : .regular))
                .foregroundStyle(state.inspectorOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
                // Negative inset reaches the HIG 44pt touch target
                // without inflating the bar's intrinsic height.
                .contentShape(Rectangle().inset(by: -15))
        }
        .buttonStyle(.plain)
        .help("Show file info, outline, and counts")
    }

    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 8) {
            Text(countSegments().joined(separator: "  ·  "))
            if state.liveMatchCount > 0 {
                Text("·  \(state.liveMatchCount) match\(state.liveMatchCount == 1 ? "" : "es")")
                    .foregroundStyle(.tint)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Each segment honors its Settings toggle.
    private func countSegments() -> [String] {
        let nsText = document.text as NSString
        var segments: [String] = []
        if state.statusShowsLineCount {
            segments.append("Lines: \(TextMetrics.lineCount(in: nsText))")
        }
        if let statistics = state.writingStatistics {
            segments.append("Words: \(statistics.words)")
            if state.statusShowsCharCount { segments.append("Chars: \(statistics.characters)") }
            if statistics.hasSelection {
                segments.append("Selection: \(statistics.selectedWords) words, \(statistics.selectedCharacters) chars")
            }
        }
        if state.statusShowsLineCol {
            let (line, column) = TextMetrics.lineColumn(for: (selection ?? state.selectedRange).location, in: nsText)
            segments.append("Loc: \((selection ?? state.selectedRange).location)")
            segments.append("Ln \(line):\(column)")
        }
        return segments
    }

    @ViewBuilder
    private var byteCountLabel: some View {
        Text(state.writingStatistics.map { stats in
            stats.bufferBytes.map { "\($0.formatted(.number)) buffer bytes" } ?? "Not encodable"
        } ?? "Counting…")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var encodingMenu: some View {
        Menu { encodingMenuChoices } label: {
            statusMenuLabel(document.fileEncoding.localizedName)
        }
    }

    @ViewBuilder
    private var encodingMenuChoices: some View {
        ForEach(Self.statusEncodingChoices, id: \.self) { encoding in
            let title = String.localizedName(of: encoding)
            Button {
                claimFocus()
                CommandActions.setEncoding(FileEncoding(encoding: encoding))
            } label: {
                if document.fileEncoding.encoding == encoding && !document.fileEncoding.withUTF8BOM {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
        if Self.statusEncodingChoices.contains(.utf8) {
            Divider()
            Button {
                claimFocus()
                CommandActions.setEncoding(FileEncoding(encoding: .utf8, withUTF8BOM: true))
            } label: {
                if document.fileEncoding.encoding == .utf8 && document.fileEncoding.withUTF8BOM {
                    Label("Unicode (UTF-8) with BOM", systemImage: "checkmark")
                } else {
                    Text("Unicode (UTF-8) with BOM")
                }
            }
        }
    }

    @ViewBuilder
    private var lineEndingMenu: some View {
        Menu { lineEndingMenuChoices } label: {
            statusMenuLabel(document.lineEnding.label)
        }
    }

    @ViewBuilder
    private var lineEndingMenuChoices: some View {
        ForEach(LineEnding.allCases, id: \.self) { ending in
            Button {
                claimFocus()
                CommandActions.setLineEnding(ending)
            } label: {
                if document.lineEnding == ending {
                    Label("\(ending.label) (\(ending.description))", systemImage: "checkmark")
                } else {
                    Text("\(ending.label) (\(ending.description))")
                }
            }
        }
    }

    @ViewBuilder
    private var languageMenu: some View {
        Menu { languageMenuChoices } label: {
            statusMenuLabel(LanguageRegistry.displayName(for: state.languageIdentifier))
        }
    }

    @ViewBuilder
    private var languageMenuChoices: some View {
        ForEach(LanguageRegistry.all, id: \.identifier) { language in
            Button {
                claimFocus()
                CommandActions.setLanguage(language.identifier)
            } label: {
                if state.languageIdentifier == language.identifier {
                    Label(language.displayName, systemImage: "checkmark")
                } else {
                    Text(language.displayName)
                }
            }
        }
    }

    private func statusMenuLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .contentShape(.rect)
    }

    private func claimFocus() {
        bus.scenes.claimFocus(preservingPaneOf: state)
    }

    private static let statusEncodingChoices: [String.Encoding] = {
        String.sortedAvailableStringEncodings.compactMap { $0 }
    }()
}
