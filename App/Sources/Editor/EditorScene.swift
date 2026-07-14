import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding

/// One `EditorSession` per window. Hosts scene-level modifiers
/// (pickers, sheets, scenePhase lifecycle, bus registrations).
/// I/O bypasses `DocumentGroup` to dodge the iOS 26.5 simulator
/// FileProvider FP-1005 bug — see `PlainTextDocument`.
struct EditorScene: View {

    @State private var session = EditorSession()
    @Bindable private var bus = AppStateBus.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var sceneReceivedOpenURL = false
    @State private var didApplySessionRecord = false
    @State private var sceneUUID: String = ""
    @State private var exportSnapshotBox = ExportSnapshotBox()
    @Bindable private var prefs = AppPreferencesStore.shared

    @Namespace private var tabSwitcherNS

    private var document: PlainTextDocument { session.activeTab.document }
    private var state: EditorState { session.activeTab.state }

    /// SwiftUI evaluates `.fileExporter(document:)` on every body
    /// re-render, not just at Save As time, so the proxy defers this
    /// O(n) buffer copy + encode until the exporter actually writes.
    /// Keep the encode pure — an earlier version raced `applyPayload`
    /// and clobbered freshly-loaded files back to "". `fileWrapper`
    /// isn't documented to run on the main thread, hence the hop.
    private func exportSnapshotProvider(for tab: TabModel) -> @Sendable () throws -> Data {
        let state = tab.state
        let document = tab.document
        let tabID = tab.id
        let box = exportSnapshotBox
        return {
            let snapshot: (text: String, data: Data)
            if Thread.isMainThread {
                snapshot = try MainActor.assumeIsolated {
                    try Self.liveEncodedSnapshot(state: state, document: document)
                }
            } else {
                snapshot = try DispatchQueue.main.sync {
                    try MainActor.assumeIsolated {
                        try Self.liveEncodedSnapshot(state: state, document: document)
                    }
                }
            }
            box.store(.init(tabID: tabID, text: snapshot.text, data: snapshot.data))
            return snapshot.data
        }
    }

    private static func liveEncodedSnapshot(
        state: EditorState,
        document: PlainTextDocument
    ) throws -> (text: String, data: Data) {
        let liveText = state.textView?.text ?? document.text
        let defaults = UserDefaults.standard
        let data = try PlainTextDocument.encode(
            text: liveText,
            encoding: document.fileEncoding,
            lineEnding: document.lineEnding,
            trimTrailingWhitespace: defaults.bool(forKey: AppPreferenceKey.trimTrailingWhitespaceOnSave),
            ensureTrailingNewline: defaults.bool(forKey: AppPreferenceKey.ensureTrailingNewline),
            saveUTF8BOMPref: defaults.bool(forKey: AppPreferenceKey.saveUTF8BOM)
        )
        return (liveText, data)
    }

    /// OR over (currentEditor, currentSession): a stale currentEditor
    /// (e.g. pointing at a closed tab) must not collapse the focused
    /// window's importer bindings into `.constant(false)`.
    private var isActive: Bool {
        bus.scenes.isActive(state) || bus.scenes.currentSession === session
    }

    private var documentTitle: String { document.displayName }

    /// Empty for clean URL-backed docs; "edited" + location for
    /// dirty / Untitled. An Untitled doc with no actual edits stays
    /// clean.
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

    var body: some View {
        // NavigationStack gives the window a real title-bar region;
        // without it iPadOS squeezes a resize grabber into the middle
        // of content.
        NavigationStack {
            ZStack {
                editorStack
                    // Cross-fade against the switcher. The earlier
                    // matchedGeometryEffect cached the source frame and
                    // wouldn't grow back when the window resized
                    // (Stage Manager / Slide Over), leaving the
                    // editor stuck at a smaller-than-window size.
                    // Plain opacity is layout-safe and good enough.
                    .opacity(session.tabSwitcherActive ? 0 : 1)
                    .allowsHitTesting(!session.tabSwitcherActive)

                if session.tabSwitcherActive {
                    TabSwitcherView(
                        session: session,
                        namespace: tabSwitcherNS,
                        matchID: switcherMatchID,
                        onDismiss: dismissSwitcher
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
        .preferredColorScheme(scenePreferredScheme)
        .focusedSceneValue(\.focusedSession, session)
        .focusedSceneValue(\.presentEditorSheet, SheetPresenter { [session] sheet in
            AppStateBus.shared.scenes.currentSession = session
            AppStateBus.shared.scenes.currentEditor = session.activeTab.state
            AppStateBus.shared.presentation.presentedSheet = sheet
        })
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    AppStateBus.shared.scenes.currentSession = session
                    AppStateBus.shared.scenes.registerSession(session)
                    AppStateBus.shared.scenes.currentEditor = session.activeTab.state
                    return
                }
                // Dirty tabs autosave inside persistSessionRecord, so
                // every persist caller (background + onDisappear) is
                // covered without double-saving here.
                persistSessionRecord()
            }
            .onAppear {
                AppStateBus.shared.scenes.currentSession = session
                AppStateBus.shared.scenes.registerSession(session)
                applySessionRestoreIfNeeded()
                markColdLaunchHandled()
                consumePendingNewWindowURL()
                adoptPendingTabIfAvailable()
                if let pending = bus.scenes.pendingShortcut {
                    bus.scenes.pendingShortcut = nil
                    applyHomeShortcut(pending)
                }
                let env = ProcessInfo.processInfo.environment
                if let autoOpen = env["AYYYY_AUTO_OPEN"] {
                    openURL(URL(fileURLWithPath: autoOpen))
                }
                if env["AYYYY_SHOW_PALETTE"] != nil {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        CommandActions.presentCommandPalette()
                    }
                }
                if env["AYYYY_SHOW_SIDEBAR"] != nil {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        state.sidebarOpen = true
                    }
                }
                if env["AYYYY_SHOW_INSPECTOR"] != nil {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        state.inspectorOpen = true
                    }
                }
                if env["AYYYY_SPLIT"] != nil {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        state.splitOpen = true
                    }
                }
                if env["AYYYY_SHOW_FIND"] != nil {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        CommandActions.presentFindNavigator()
                    }
                }
            }
            .onOpenURL { url in
                sceneReceivedOpenURL = true
                route(open: url)
            }
            .onDisappear {
                AppStateBus.shared.scenes.deregisterSession(session)
                persistSessionRecord()
                for tab in session.tabs {
                    tab.state.loadTask?.cancel()
                    tab.state.loadTask = nil
                }
            }
            .background(SceneRegistrationBridge(sceneUUID: sceneUUID))
            // ⌃P alias for the command palette. iPadOS only routes a
            // keyboard chord when a Button claims it, so we attach an
            // invisible button instead of duplicating the menu-bar
            // entry. `.hidden()` keeps the button in the layout (so
            // the shortcut registers) without drawing anything.
            .background(
                Button("Command Palette (⌃P)") {
                    CommandActions.presentCommandPalette()
                }
                .keyboardShortcut("p", modifiers: .control)
                .hidden()
            )
            // Each picker on its own background — stacked
            // `.fileImporter`s on a single view silently coalesce to
            // one binding.
            .background(
                EmptyView().fileImporter(
                    isPresented: isActive ? bus.pickers.binding(for: .open) : .constant(false),
                    allowedContentTypes: PlainTextDocument.supportedReadTypes
                ) { result in
                    if case let .success(url) = result { route(open: url) }
                }
            )
            .background(
                EmptyView().fileExporter(
                    isPresented: isActive ? bus.pickers.binding(for: .saveAs) : .constant(false),
                    document: TextFileWrapperProxy(snapshot: exportSnapshotProvider(for: session.activeTab)),
                    contentType: PlainTextDocument.supportedWriteType(for: state.fileURL),
                    defaultFilename: state.fileURL?.lastPathComponent ?? document.displayName
                ) { result in
                    switch result {
                    case .success(let url):
                        guard let snapshot = exportSnapshotBox.take(),
                              let target = session.tabs.first(where: { $0.id == snapshot.tabID })
                        else {
                            bus.presentation.openErrorMessage =
                                "The file was exported, but its originating tab is no longer open."
                            return
                        }
                        let currentText = target.state.textView?.text ?? target.document.text
                        target.document.finishExternalSave(
                            to: url,
                            savedText: snapshot.text,
                            savedData: snapshot.data,
                            currentText: currentText
                        )
                        target.state.text = currentText
                        target.state.fileURL = url
                        target.state.savedBaselineText = snapshot.text
                        target.state.fileEncoding = target.document.fileEncoding
                        target.state.lineEnding = target.document.lineEnding
                        target.state.languageIdentifier = LanguageRegistry.identifier(for: url)
                        target.state.isLargeFile = !SyntaxLimit.current().allows(byteCount: snapshot.data.count)
                        RecentFilesStore.shared.record(url)
                    case .failure(let error):
                        exportSnapshotBox.clear()
                        if (error as? CocoaError)?.code == .userCancelled {
                            return
                        }
                        bus.presentation.openErrorMessage =
                            "Couldn't save \(document.displayName): \(error.localizedDescription)"
                    }
                }
            )
            .background(
                EmptyView().fileImporter(
                    isPresented: isActive ? bus.pickers.binding(for: .insertFile) : .constant(false),
                    allowedContentTypes: [.text, .plainText, .sourceCode, .data]
                ) { result in
                    if case let .success(url) = result {
                        insertFileContents(at: url)
                    }
                }
            )
            .background(
                EmptyView().fileImporter(
                    isPresented: isActive ? bus.pickers.binding(for: .insertFolder) : .constant(false),
                    allowedContentTypes: [.folder]
                ) { result in
                    if case let .success(url) = result {
                        insertFolderListing(at: url)
                    }
                }
            )
            // Shared bus values: gate by isActive so only the focused
            // scene consumes them — every open window observes the
            // change and would otherwise act on it N times.
            .onChange(of: bus.pending.openInPlace) { _, url in
                guard isActive, let url else { return }
                openURL(url)
                bus.pending.openInPlace = nil
            }
            .onChange(of: bus.scenes.pendingShortcut) { _, shortcut in
                guard isActive, let shortcut else { return }
                applyHomeShortcut(shortcut)
                bus.scenes.pendingShortcut = nil
            }
            .onChange(of: bus.presentation.revertRequestCount) { _, _ in
                // Counter lives on the shared bus, so every scene
                // observes the bump. Gate by isActive so only the
                // window the user clicked Revert in reloads its file —
                // backgrounded scenes ignore the tick. openURL reuses
                // the async load path: errors surface via
                // openErrorMessage and isLargeFile is recomputed.
                guard isActive, let url = document.fileURL else { return }
                openURL(url)
            }
    }

    // MARK: - Tab switcher morph

    @ViewBuilder
    private var editorStack: some View {
        VStack(spacing: 0) {
            if DeviceIdiom.supportsMultipleWindows && prefs.showToolbar {
                WindowToolbar(
                    title: documentTitle,
                    subtitle: documentSubtitle,
                    onInteraction: {
                        AppStateBus.shared.scenes.currentSession = session
                        AppStateBus.shared.scenes.currentEditor = session.activeTab.state
                    }
                )
            }
            if session.tabs.count > 1, !DeviceIdiom.isPhone {
                TabBarView(session: session)
            }
            HStack(spacing: 0) {
                if state.sidebarOpen, !DeviceIdiom.isPhone {
                    OutlineSidebar(state: state)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                activeTabContent
                    // Remount on tab swap so the engine doesn't try
                    // to swap text in place.
                    .id(session.selectedTabID)
            }
        }
    }

    /// `.launcher` / `.fileBrowser` inject their UI via
    /// `tabContentOverride` so the surrounding chrome stays put
    /// regardless of what's filling the text-area region.
    @ViewBuilder
    private var activeTabContent: some View {
        switch session.activeTab.kind {
        case .editor:
            EditorView(document: document, state: state)
        case .fileBrowser:
            EditorView(
                document: document,
                state: state,
                tabContentOverride: AnyView(
                    FileBrowserTabContent(
                        onPick: { adoptPickedFileIntoActiveTab($0) },
                        onCancel: { session.activeTab.kind = .launcher }
                    )
                )
            )
        case .launcher:
            EditorView(
                document: document,
                state: state,
                tabContentOverride: AnyView(launcherOverride)
            )
        }
    }

    @ViewBuilder
    private var launcherOverride: some View {
        NewDocumentLauncherView(
            onPickTemplate: { adoptTemplateIntoActiveTab($0) },
            onPickDraft: { adoptDraftIntoActiveTab($0) },
            onPickOpenFile: { session.activeTab.kind = .fileBrowser },
            onPickClipboard: { adoptClipboardIntoActiveTab($0) },
            isWindowScopeLauncher: session.tabs.count == 1,
            onCancel: {
                if session.tabs.count == 1, DeviceIdiom.supportsMultipleWindows {
                    // Pass the owning session — the bus's focused
                    // session may lag behind and point at another
                    // window, which would close the wrong one.
                    CommandActions.closeWindow(session: session)
                } else {
                    CommandActions.requestCloseTab(session.activeTab.id, in: session)
                }
            },
            showsCancel: session.tabs.count > 1 || DeviceIdiom.supportsMultipleWindows
        )
    }

    private func adoptPickedFileIntoActiveTab(_ url: URL) {
        let tab = session.activeTab
        tab.kind = .editor
        openURL(url)
    }

    private func adoptClipboardIntoActiveTab(_ text: String) {
        let tab = session.activeTab
        tab.document.text = text
        tab.document.fileURL = nil
        tab.document.isDirty = !text.isEmpty
        tab.state.text = text
        tab.state.fileURL = nil
        tab.state.savedBaselineText = ""
        tab.kind = .editor
        tab.state.requestEditorFocus()
    }

    private func adoptTemplateIntoActiveTab(_ template: TemplateRecord) {
        let tab = session.activeTab
        let body = TemplatesStore.shared.loadContent(template) ?? ""
        tab.document.text = body
        tab.document.fileURL = nil
        tab.document.isDirty = !body.isEmpty
        tab.state.text = body
        tab.state.fileURL = nil
        tab.state.savedBaselineText = ""
        tab.state.languageIdentifier = LanguageRegistry.identifier(for: template.url)
        tab.kind = .editor
        tab.state.requestEditorFocus()
    }

    /// Adopts a draft into the active tab. The draft file stays in
    /// place while the buffer is open so a crash before the next
    /// close/background write still leaves a recoverable copy. The
    /// next committed draft write overwrites this same URL; Save /
    /// Discard still delete it. URL-backed drafts also run the
    /// stale-source safeguard (missing file / changed since capture).
    private func adoptDraftIntoActiveTab(_ draft: DraftRecord) {
        let tab = session.activeTab
        Task {
            do {
                if let staleCheck = try await Self.adoptDraft(draft, into: tab) {
                    bus.presentation.sourceStaleCheck = staleCheck
                }
            } catch is CancellationError {
                // The scene went away while an iCloud draft was loading.
            } catch {
                bus.presentation.openErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    static func adoptDraft(_ draft: DraftRecord, into tab: TabModel) async throws -> SourceStaleCheck? {
        try await DraftRecoveryWorkflow.adopt(draft, into: tab)
    }

    /// Stable across tab switches. Keyed off active tab id earlier,
    /// which made every Cmd-T fire a matched-geometry interpolation
    /// from the previous tab's frame.
    private var switcherMatchID: String { "tab-morph-active" }

    private func dismissSwitcher() {
        withAnimation(.appSwitcherMorph) {
            session.tabSwitcherActive = false
        }
    }

    private var scenePreferredScheme: ColorScheme? {
        switch AppThemeName(stored: prefs.themeName).preferredColorScheme {
        case .light: return .light
        case .dark:  return .dark
        case .none:  return nil
        case .some(_): return nil
        }
    }

    /// Capped at 5 MB so a tap on a giant file can't wedge the buffer.
    private func insertFileContents(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= 5 * 1024 * 1024 else {
            bus.presentation.openErrorMessage = "\(url.lastPathComponent) is too large to insert (>5 MB)."
            return
        }
        if let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            state.textView?.replace(state.selectedRange, withText: s)
        }
    }

    private func insertFolderListing(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) else { return }
        var lines: [String] = ["\(url.lastPathComponent)/"]
        for (index, entry) in contents.enumerated() {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let branch = index == contents.count - 1 ? "└── " : "├── "
            lines.append("\(branch)\(entry.lastPathComponent)\(isDir ? "/" : "")")
        }
        let nl = state.lineEnding.string
        state.textView?.replace(state.selectedRange, withText: lines.joined(separator: nl) + nl)
    }

    private func markColdLaunchHandled() {
        AppStateBus.shared.scenes.hasAppliedLaunchBehavior = true
        SessionsStore.shared.purgeHiddenSessions()
    }

    /// First scene of the launch seeds the restore queue + spawns
    /// `pendingCount - 1` extras (SwiftUI only restores one scene
    /// on its own). Subsequent scenes just pop their record.
    private func applySessionRestoreIfNeeded() {
        guard !didApplySessionRecord else { return }
        didApplySessionRecord = true
        if sceneUUID.isEmpty {
            sceneUUID = UUID().uuidString
        }
        session.sceneUUID = sceneUUID
        let pendingCount = SessionsStore.shared.initiateRestoreSweep()
        if pendingCount > 1 {
            for _ in 0..<(pendingCount - 1) {
                openWindow(id: SceneID.editor.rawValue)
            }
        }
        if let record = SessionsStore.shared.consumePendingRestore() {
            SessionRestore.apply(record, to: session)
        }
    }

    /// Snapshots current tabs (file bookmarks + draft refs + active
    /// index) under the scene's UUID. Re-saves on every background
    /// transition so a force-quit picks up the latest state.
    private func persistSessionRecord() {
        guard !sceneUUID.isEmpty, !session.isClosingWindow else { return }
        DraftsStore.shared.withCapEnforcementSuspended {
            for tab in session.tabs where tab.document.isDirty {
                if let live = tab.state.textView?.text {
                    tab.document.text = live
                }
                tab.document.autoSave(commitDraft: true)
            }
        }
        // Empty windows (every tab without fileURL or draftURL) are
        // dropped — restoring them would seed phantom Untitled
        // windows on next launch.
        let hasRestorableTab = session.tabs.contains { tab in
            tab.document.fileURL != nil || tab.document.draftURL != nil
        }
        guard hasRestorableTab else {
            SessionsStore.shared.remove(forScene: sceneUUID)
            DraftsStore.shared.enforceCapNow()
            return
        }
        SessionsStore.shared.save(SessionRecord(scene: sceneUUID, session: session))
        DraftsStore.shared.enforceCapNow()
    }

    private func adoptPendingTabIfAvailable() {
        guard let adopted = AppStateBus.shared.pending.adoptedTab,
              session.tabs.count == 1,
              session.activeTab.document.fileURL == nil,
              session.activeTab.document.text.isEmpty
        else { return }
        AppStateBus.shared.pending.adoptedTab = nil
        // Insert-then-remove (not the reverse) so the strip never
        // briefly hosts two tabs and animates the placeholder out.
        let placeholder = session.activeTab
        session.attachTab(adopted)
        adopted.state.requestEditorFocus()
        if let idx = session.tabs.firstIndex(where: { $0 === placeholder }) {
            session.tabs.remove(at: idx)
        }
    }

    private func consumePendingNewWindowURL() {
        guard let url = AppStateBus.shared.pending.newWindow,
              document.fileURL == nil,
              document.text.isEmpty else { return }
        AppStateBus.shared.pending.newWindow = nil
        openURL(url)
    }

    private func applyHomeShortcut(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .newFile:
            openWindow(id: SceneID.editor.rawValue)
        case .commandPalette:
            CommandActions.presentCommandPalette()
        }
    }

    /// Tasked through MainActor so the dismissing picker gets a
    /// runloop tick before the new scene takes over.
    private func route(open url: URL) {
        let destination = DocumentDestination.current()
        AppStateBus.shared.pending.nextOpenDestinationOverride = nil
        switch destination {
        case .window:
            AppStateBus.shared.pending.newWindow = url
            Task { @MainActor in openWindow(id: SceneID.editor.rawValue) }
        case .tab:
            Task { @MainActor in
                session.newTab(kind: .editor)
                openURL(url)
            }
        }
    }

    private func openURL(_ url: URL) {
        let line = AppStateBus.shared.pending.goToLine
        AppStateBus.shared.pending.goToLine = nil
        DocumentWorkflow.open(url, in: session.activeTab, goToLine: line)
    }
}

private struct ExportSnapshot: Sendable {
    let tabID: UUID
    let text: String
    let data: Data
}

/// `.fileExporter` may call the snapshot closure off-main. Keep the exact
/// bytes and originating tab in a tiny lock-protected handoff so completion
/// cannot accidentally finalize whichever tab became active later.
private final class ExportSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ExportSnapshot?

    func store(_ snapshot: ExportSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    func take() -> ExportSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        defer { value = nil }
        return value
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
