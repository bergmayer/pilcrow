import SwiftUI
import UniformTypeIdentifiers
import FileEncoding

struct EditorView: View {

    let document: PlainTextDocument
    let state: EditorState
    /// Replaces `splitOrSingleEditor` while keeping the surrounding
    /// chrome (toolbar / status bar / accessory). Launcher + inline
    /// file browser use this so they show *inside* the tab.
    let tabContentOverride: AnyView?

    init(document: PlainTextDocument, state: EditorState, tabContentOverride: AnyView? = nil) {
        self.document = document
        self.state = state
        self.tabContentOverride = tabContentOverride
    }

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var prefs = AppPreferencesStore.shared
    /// Fraction at divider-drag start; DragGesture translation is
    /// cumulative, so deltas must apply against this anchor, not the
    /// already-updated live fraction.
    @State private var dividerDragStartFraction: CGFloat?
    @State private var commandAfterDismiss: (() -> Void)?

    private var selectedPane: EditorState {
        if let focused = bus.scenes.currentEditor, currentTab?.owns(focused) == true { return focused }
        return state
    }

    var body: some View {
        observeStateForEngineUpdates()
        // The scene owns keyboard avoidance. Keep chrome in the layout so
        // a short viewport cannot put its last line behind the status bar.
        return VStack(spacing: 0) {
            recoveryFailureBanner
            // Native panes stay mounted through split and size changes.
            Group {
                if let override = tabContentOverride {
                    override
                } else {
                    splitOrSingleEditor
                }
            }
            .frame(maxHeight: .infinity)

            if state.showStatusBar {
                EditorStatusBar(document: document, state: state, selection: selectedPane.selectedRange)
            }
        }
        // Non-modal so the editor stays editable while the user browses
        // metadata or the outline.
        .inspector(isPresented: Binding(
            get: { state.inspectorOpen },
            set: { state.inspectorOpen = $0 }
        )) {
            InfoInspectorSheet(document: document, state: state, onJump: { goToLine($0) })
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        // Blocks typing into a buffer that's about to be replaced.
        .overlay {
            if document.isLoading { loadingOverlay }
        }
        // isActive gate: shared bus flag surfaces only on the focused window.
        .sheet(
            item: ownsPresentedSheet ? $bus.presentation.presentedSheet : .constant(nil),
            onDismiss: {
                let action = commandAfterDismiss
                commandAfterDismiss = nil
                // Commands may change first responder or present another dialog.
                // Leave SwiftUI's sheet update before executing those side effects.
                if let action { Task { @MainActor in action() } }
            }
        ) { sheet in
            sheetContent(for: sheet)
        }
        .sheet(item: Binding(get: { state.documentShare }, set: { state.documentShare = $0 })) { share in
            DocumentShareSheet(share: share)
        }
        // `.alert` not `.confirmationDialog`: iPad popover-with-tail needs
        // an anchor, and close paths come from disparate places (tab
        // strip, switcher, ⌘W, palette) with no single sensible anchor.
        // Each alert is its own ViewModifier — the trailing-closure
        // alert API counts heavily against the type-checker budget and
        // stacking them inline previously exceeded that budget.
        .modifier(OpenErrorAlertModifier(
            presented: openErrorAlertBinding,
            message: bus.presentation.openErrorMessage
        ))
        .modifier(StaleSourceAlertModifier(
            title: staleAlertTitle,
            presented: staleCheckBinding,
            check: bus.presentation.sourceStaleCheck,
            cancel: { bus.presentation.sourceStaleCheck = nil }
        ))
        .onAppear {
            primeStateFromDocument()
            AppStateBus.shared.scenes.currentEditor = state
            if let session = AppStateBus.shared.scenes.currentSession {
                AppStateBus.shared.scenes.registerSession(session)
            }
            // Restore-with-split-open: the onChange below won't fire
            // for the initial value.
            if state.splitOpen { _ = currentTab?.ensureSecondaryState() }
        }
        // ensureSecondaryState mutates @Observable state, so it can't
        // run during body. Create the pane state here and let body
        // render the split once `secondaryState` exists.
        .task(id: SourceObservationRequest(url: document.fileURL, saving: document.isSaving,
                                           active: scenePhase == .active)) {
            guard let tab = currentTab, tab.kind == .editor, let url = document.fileURL,
                  scenePhase == .active, !document.isSaving else { return }
            let observation = SourceFileObservation(url: url)
            defer { observation.stop() }
            for await currentURL in observation.events {
                guard !Task.isCancelled else { return }
                if currentURL != url, document.fileURL == url {
                    document.fileURL = currentURL
                    state.fileURL = currentURL
                    state.siblingState?.fileURL = currentURL
                    document.revisionKey = RevisionStore.key(for: currentURL)
                    RecentFilesStore.shared.record(currentURL)
                }
                await DocumentWorkflow.refreshExternalSource(tab, at: currentURL)
            }
        }
        .task(id: WritingStatistics.Request(text: document.text, selection: selectedPane.selectedRange,
                    encoding: document.fileEncoding.encoding.rawValue, utf8BOM: document.fileEncoding.withUTF8BOM)) {
            let request = WritingStatistics.Request(text: document.text, selection: selectedPane.selectedRange,
                encoding: document.fileEncoding.encoding.rawValue, utf8BOM: document.fileEncoding.withUTF8BOM)
            let previous = state.writingStatistics
            let worker = Task.detached(priority: .utility) { WritingStatistics(request, reusing: previous) }
            let statistics = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled { state.writingStatistics = statistics }
        }
        .onChange(of: state.splitOpen) { _, open in
            if open { _ = currentTab?.ensureSecondaryState() }
        }
        // No matching .onDisappear: SwiftUI fires it on any focus loss
        // (palette / preferences / multitasking swipe), which dimmed the
        // menu bar despite a live editor behind another window.
        // `currentEditor` is weak — nils on EditorState dealloc.
        // Pref → live state propagation is automatic: every preference
        // field on EditorState is a computed read through
        // AppPreferencesStore, so Settings changes show up via Observation
        // without an explicit .onChange chain. The remaining observers
        // (encoding/lineEnding mirror, recovery checkpoints, spell-check
        // toggle, tap-to-suggest) live in EditorObserversModifier — see
        // its file for the per-handler rationale.
        .modifier(EditorObserversModifier(
            document: document,
            state: state,
            onBufferEdit: {
                state.scheduleAutoSave(for: document)
                scheduleLiveSpellCheckIfEnabled()
            }
        ))
        // Load / revert / restore flow through document.text; the engine's
        // updateUIView picks them up via lastPushedDocumentText.
        .navigationTitle(documentTitle)
        .navigationSubtitle(documentSubtitle)
        .navigationBarTitleDisplayMode(.inline)
        // iPad swaps the system nav bar for the WindowToolbar pill;
        // iPhone keeps the system bar (where the filename lives).
        .toolbar(
            (DeviceIdiom.supportsMultipleWindows && prefs.showToolbar) ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbar {
            if DeviceIdiom.isPhone {
                PhoneEditorToolbar(
                    documentTitle: documentTitle,
                    showToolbarPref: prefs.showToolbar,
                    claimFocus: claimFocus
                )
            }
        }
    }

    private var ownsPresentedSheet: Bool {
        let owner = bus.presentation.presentedSheetOwner
        return owner === state || owner?.siblingState === state || (owner == nil && isActive)
    }

    private var isActive: Bool { bus.scenes.isActive(state) }

    /// Only the owning scene presents — otherwise every window stacks it.
    private var staleCheckBinding: Binding<Bool> {
        Binding(
            get: {
                guard let check = bus.presentation.sourceStaleCheck else { return false }
                let tabID: UUID
                switch check {
                case .missing(let t, _), .changedOnAdopt(let t, _), .changedOnSave(let t, _):
                    tabID = t
                }
                return session?.tabs.contains(where: { $0.id == tabID }) ?? false
            },
            set: { newValue in
                if !newValue { bus.presentation.sourceStaleCheck = nil }
            }
        )
    }

    private var staleAlertTitle: String {
        switch bus.presentation.sourceStaleCheck {
        case .missing:        return "Source file missing"
        case .changedOnAdopt: return "Source file changed"
        case .changedOnSave:  return "Source file changed"
        case .none:           return ""
        }
    }

    private var session: EditorSession? {
        bus.scenes.allOpenSessions.first { $0.tabs.contains(where: { $0.state === state }) }
    }

    private var currentTab: TabModel? {
        session?.tabs.first(where: { $0.state === state })
    }

    private var openErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { isActive && bus.presentation.openErrorMessage != nil },
            set: { newValue in
                if !newValue { bus.presentation.openErrorMessage = nil }
            }
        )
    }

    private var documentTitle: String {
        currentTab?.kind == .editor ? document.displayName : "Pilcrow"
    }

    /// "edited" hint + location, middle-dot joined. Brand-new Untitled
    /// with no edits is NOT "edited"; only flips once `isDirty` does.
    private var documentSubtitle: String {
        let unsaved = document.isDirty
        let location: String = document.fileURL.map { DocumentLocation.describe(parentOf: $0) } ?? ""
        switch (unsaved, location.isEmpty) {
        case (true, true):   return "edited"
        case (true, false):  return "edited · \(location)"
        case (false, true):  return ""
        case (false, false): return location
        }
    }

    /// updateUIView only fires when SwiftUI re-evaluates THIS body, which
    /// only happens when an @Observable is read here. Touch every engine-
    /// relevant property to force propagation.
    ///
    /// Do NOT add `document.bufferRevision` — per-keystroke body re-eval
    /// is exactly the cost we're avoiding. `document.text` is safe: only
    /// changes on load / revert / restore + 300 ms debounced snapshot.
    private func observeStateForEngineUpdates() {
        _ = document.text  // load / revert / restore pushes
        _ = state.languageIdentifier
        _ = state.themeName
        _ = state.font
        _ = state.fontSize
        _ = state.lineHeight
        _ = state.showLineNumbers
        _ = state.wrapLines
        _ = state.highlightCurrentLine
        _ = state.highlightMatchingBrackets
        _ = state.showPageGuide
        _ = state.pageGuideColumn
        _ = state.showInvisibles
        _ = state.showInvisibleSpace
        _ = state.showInvisibleTab
        _ = state.showInvisibleNewline
        _ = state.showInvisibleNonBreakingSpace
        _ = state.usesTabs
        _ = state.indentWidth
        _ = state.insertCharacterPairs
        _ = state.autoCorrect
        _ = state.autoCapitalize
        _ = state.smartQuotes
        _ = state.spellCheck
        _ = state.autoLinkDetection
        _ = state.savedBaselineText
        _ = state.editorFocusRequestID
        _ = state.showChangeHistoryGutter
        _ = state.overscroll
        _ = state.sidebarOpen
        _ = state.splitOpen
        _ = state.splitFraction
        _ = state.splitOrientation
    }

    private func primeStateFromDocument() {
        state.text = document.text
        // Diff-gutter baseline. Save flows rewrite this so the gutter
        // resets after a successful write.
        state.savedBaselineText = document.text
        state.fileEncoding = document.fileEncoding
        state.lineEnding = document.lineEnding
        state.fileURL = document.fileURL
        if let url = document.fileURL {
            state.languageIdentifier = LanguageRegistry.identifier(for: url)
        }
        // Weak captures: closures stored on `state` would ARC-cycle.
        state.setText = { [weak state, weak document] newText in
            guard state != nil, let document else { return }
            if document.text != newText {
                document.text = newText
                document.isDirty = true
            }
        }
        state.reinterpretWithEncoding = { [weak state, weak document] newEncoding in
            guard let state, let document else { return }
            do {
                let decoded = try document.reinterpretOriginalData(as: newEncoding)
                state.text = decoded
                state.fileEncoding = document.fileEncoding
            } catch {
                AppStateBus.shared.presentation.openErrorMessage =
                    "Couldn't reopen using \(newEncoding.localizedName): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Loading overlay

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.06).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(loadingMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel") {
                    state.loadTask?.cancel()
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var loadingMessage: String {
        // Open-in-new-window: document.fileURL is nil until applyPayload.
        let url = document.fileURL ?? state.fileURL
        guard let url else { return "Loading…" }
        let provider = DocumentLocation.describe(parentOf: url)
            .split(separator: "›").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let name = url.lastPathComponent
        if provider.isEmpty {
            return "Loading \(name)…"
        }
        return "Loading \(name)\nfrom \(provider)…"
    }

    /// Keep both mounted panes stable through split toggles and rotation.
    /// Undo operations may target either pane, including the hidden one.
    private var splitOrSingleEditor: some View {
        GeometryReader { proxy in
            let horizontal = state.splitOrientation == .horizontal
            let total = max(horizontal ? proxy.size.width : proxy.size.height, 1)
            let available = max(total - 6, 0)
            let minimum = min(120, available / 2)
            let primarySize = max(minimum, min(available - minimum, available * state.splitFraction))
            let secondary = currentTab?.secondaryState
            let isSplit = state.splitOpen && secondary != nil
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                EditorTextView(document: document, state: state)
                    .frame(width: isSplit && horizontal ? primarySize : nil,
                           height: isSplit && !horizontal ? primarySize : nil)
                if let secondary {
                    splitDivider(in: total, axis: state.splitOrientation)
                        .frame(width: isSplit ? nil : 0, height: isSplit ? nil : 0)
                        .clipped()
                        .allowsHitTesting(isSplit)
                    EditorTextView(document: document, state: secondary)
                        .frame(width: isSplit ? nil : 0, height: isSplit ? nil : 0)
                        .clipped()
                        .opacity(isSplit ? 1 : 0)
                        .allowsHitTesting(isSplit)
                        .accessibilityHidden(!isSplit)
                }
            }
        }
    }

    @ViewBuilder
    private func splitDivider(in totalSize: CGFloat, axis: SplitOrientation) -> some View {
        Color(.separator)
            .frame(width:  axis == .horizontal ? 6 : nil,
                   height: axis == .vertical   ? 6 : nil)
            .overlay {
                switch axis {
                case .horizontal: Rectangle().fill(Color.secondary).frame(width: 1)
                case .vertical:   Rectangle().fill(Color.secondary).frame(height: 1)
                }
            }
            // Inset hit area: the bare 6 pt strip is near-undraggable
            // by touch.
            .contentShape(Rectangle().inset(by: -12))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dividerDragStartFraction ?? state.splitFraction
                        dividerDragStartFraction = start
                        let delta: CGFloat
                        switch axis {
                        case .horizontal: delta = value.translation.width
                        case .vertical:   delta = value.translation.height
                        }
                        state.splitFraction = max(0.1, min(0.9, start + delta / totalSize))
                    }
                    .onEnded { _ in dividerDragStartFraction = nil }
            )
    }

    /// Beats the iPad Stage Manager / Split View race where scenePhase
    /// fires late and the sheet would land on the wrong window.
    private func claimFocus() {
        bus.scenes.claimFocus(preservingPaneOf: state)
    }


    @ViewBuilder
    private var recoveryFailureBanner: some View {
        if state.transformTask != nil {
            HStack {
                ProgressView("Running transform…")
                Spacer()
                Button("Cancel") { state.transformTask?.cancel() }
            }
            .padding(12)
            .background(.bar)
        }
        if let error = state.operationError {
            HStack {
                Text(error)
                Spacer()
                Button("Dismiss") { state.operationError = nil }
            }
            .font(.callout)
            .padding(12)
            .background(.bar)
        }
        if let message = document.externalChangeMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                HStack {
                    Button("Reload…") { claimFocus(); CommandActions.revertToSaved() }
                    Button("Save As…") { claimFocus(); CommandActions.saveFileAs() }
                }
                .buttonStyle(.bordered)
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.12))
        }
        if let error = document.recoveryError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recovery copy couldn’t be updated", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(error).font(.caption)
                HStack {
                    Button("Retry Recovery") {
                        document.text = state.textView?.text ?? document.text
                        document.autoSave()
                    }
                    Button("Save…") {
                        claimFocus()
                        CommandActions.saveFile()
                    }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
        }
    }

    /// 400 ms debounce matches autocorrect's "stopped typing" feel
    /// without thrashing the highlight list per keystroke.
    private func scheduleLiveSpellCheckIfEnabled() {
        guard state.spellCheck, !document.isLoading else { return }
        state.liveSpellTask?.cancel()
        state.liveSpellTask = Task { @MainActor [weak state] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            defer { state?.liveSpellTask = nil }
            state?.textView?.highlightAllMisspellings()
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(for sheet: EditorSheet) -> some View {
        switch sheet {
        case .encodingPicker:
            EncodingPickerSheet(
                current: document.fileEncoding,
                onSelect: { encoding, action in
                    switch action {
                    case .convert:
                        state.fileEncoding = encoding
                    case .reinterpret:
                        state.reinterpretWithEncoding?(encoding)
                    }
                }
            )
        case .lineEndingPicker:
            LineEndingPickerSheet(
                current: document.lineEnding,
                onSelect: { lineEnding in
                    // document.text is a 300 ms debounced snapshot;
                    // operating on it would drop keystrokes typed
                    // inside the debounce window.
                    let live = state.textView?.text ?? document.text
                    state.lineEnding = lineEnding
                    replaceWholeBuffer(with: live.replacingLineEndings(with: lineEnding))
                }
            )
        case .languagePicker:
            LanguagePickerSheet(
                current: state.languageIdentifier,
                onSelect: { identifier in
                    state.languageIdentifier = identifier
                }
            )
        case .characterInspector:
            CharacterInspectorSheet(text: document.text, range: state.selectedRange)
        case .sortLines:
            let target = LineEditTarget(text: state.textView?.text ?? document.text,
                                        selection: state.textView?.selectedRange ?? state.selectedRange)
            SortLinesSheet(
                text: target.text,
                lineEnding: document.lineEnding,
                scopeLabel: target.isSelection ? "Selected Lines" : "Whole Document",
                onApply: { sorted in
                    guard sorted != target.text else { return }
                    guard let editor = state.textView, editor.text == target.source else {
                        bus.presentation.openErrorMessage = "The document changed. Select the lines and sort again."
                        return
                    }
                    editor.undoManager?.endUndoGrouping()
                    editor.replace(target.range, withText: sorted)
                    editor.undoManager?.endUndoGrouping()
                    editor.setSelection(NSRange(location: target.range.location, length: (sorted as NSString).length))
                }
            )
        case .goToLine:
            GoToLineSheet(
                lineCount: lineCount(in: state.textView?.text ?? document.text),
                onApply: { line in goToLine(line) }
            )
        case .selectLinesContaining:
            SelectLinesContainingSheet()
        case .prefixSuffixLines:
            PrefixSuffixLinesSheet()
        case .insertLoremIpsum:
            InsertLoremIpsumSheet()
        case .snippetsManager:
            SnippetsManagerSheet()
        case .templatePicker:
            TemplatePickerSheet { template in
                if let tab = currentTab { TemplateWorkflow.apply(template, to: tab) }
            }
        case .clipboardHistory:
            ClipboardHistorySheet()
        case .findReplace:
            FindReplaceSheet(editor: state)
        case .zapGremlins:
            ZapGremlinsSheet()
        case .revisions:
            RevisionsSheet(document: document)
        case .commandPalette:
            CommandPaletteSheet { command in
                let owner = selectedPane
                commandAfterDismiss = {
                    CommandActions.perform(for: owner) {
                        if command.isEnabled() { command.action() }
                    }
                }
            }
        case .fileBrowser:
            FileBrowserSheetView(owner: session)
        case .multiFileSearch:
            MultiFileSearchSheet(owner: session)
        case .preferences:
            NavigationStack { PreferencesView() }
        case .tabSwitcher:
            // EditorScene presents the switcher inline so the editor frame
            // can morph into the active card via matchedGeometryEffect.
            EmptyView()
        case .processLines:
            ProcessLinesSheet()
        case .canonize:
            CanonizeSheet()
        case .characterPanel:
            CharacterPanelSheet()
        case .markdownTable:
            MarkdownTableSheet()
        case .markdownPreview:
            MarkdownPreviewSheet(document: document)
        case .organizeFootnotes:
            OrganizeFootnotesSheet()
        case .spellCheck:
            SpellCheckSheet(editor: state)
        }
    }

    /// Whole-buffer sheet actions must update the live engine (preserving
    /// undo), the observable snapshot, and dirty/recovery bookkeeping.
    private func replaceWholeBuffer(with newText: String) {
        let oldText = state.textView?.text ?? document.text
        guard oldText != newText else { return }
        if let textView = state.textView {
            let fullRange = NSRange(location: 0, length: (oldText as NSString).length)
            textView.replace(fullRange, withText: newText)
        } else {
            document.bufferRevision &+= 1
        }
        document.text = newText
        document.isDirty = true
        state.text = newText
    }

    private func lineCount(in text: String) -> Int {
        TextMetrics.lineCount(in: text as NSString)
    }

    private func goToLine(_ line: Int) {
        state.textView?.goToLine(line)
    }
}

private struct SourceObservationRequest: Equatable {
    let url: URL?
    let saving: Bool
    let active: Bool
}
