import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding
import UIKit

/// Hosts one editor session and its scene-level presentation state.
struct EditorScene: View {

    @Binding private var route: EditorRoute?
    @State private var session = EditorSession()
    @Bindable private var bus = AppStateBus.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var sceneReceivedOpenURL = false
    @State private var didApplySessionRecord = false
    @State private var sceneUUID: String = ""
    @State private var exportSnapshotBox = ExportSnapshotBox()
    @State private var persistenceTask: Task<Void, Never>?
    @Bindable private var prefs = AppPreferencesStore.shared
    @Bindable private var closedWindows = ClosedWindowsStore.shared

    @Namespace private var tabSwitcherNS

    init(route: Binding<EditorRoute?>) {
        self._route = route
    }

    private var document: PlainTextDocument { session.activeTab.document }
    private var state: EditorState { session.activeTab.state }

    /// Captures the live buffer when the exporter writes, on the main actor.
    private func exportSnapshotProvider(for tab: TabModel) -> @Sendable () throws -> Data {
        let state = tab.state
        let document = tab.document
        let tabID = tab.id
        let box = exportSnapshotBox
        return {
            let snapshot: (sourceText: String, savedText: String, data: Data)
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
            box.store(.init(
                tabID: tabID,
                sourceText: snapshot.sourceText,
                savedText: snapshot.savedText,
                data: snapshot.data
            ))
            return snapshot.data
        }
    }

    private static func liveEncodedSnapshot(
        state: EditorState,
        document: PlainTextDocument
    ) throws -> (sourceText: String, savedText: String, data: Data) {
        let liveText = state.textView?.text ?? document.text
        let defaults = UserDefaults.standard
        let savedText = PlainTextDocument.prepareTextForSaving(
            liveText,
            lineEnding: document.lineEnding,
            trimTrailingWhitespace: defaults.bool(forKey: AppPreferenceKey.trimTrailingWhitespaceOnSave),
            ensureTrailingNewline: defaults.bool(forKey: AppPreferenceKey.ensureTrailingNewline)
        )
        let data = try PlainTextDocument.encode(
            text: savedText,
            encoding: document.fileEncoding,
            lineEnding: document.lineEnding,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: defaults.bool(forKey: AppPreferenceKey.saveUTF8BOM)
        )
        return (liveText, savedText, data)
    }

    /// Accept either focused-session signal during focus transitions.
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
        .overlay(alignment: .bottom) {
            if isActive,
               scenePhase == .active,
               let record = closedWindows.pendingNotice {
                ClosedWindowRecoveryBanner(
                    record: record,
                    onRestore: { restoreClosedWindowInNewScene(record) },
                    onDismiss: { closedWindows.dismissNotice() }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: closedWindows.noticeRecordID)
        .preferredColorScheme(scenePreferredScheme)
        .focusedSceneValue(\.focusedSession, session)
        .focusedSceneValue(\.presentEditorSheet, SheetPresenter { [session] sheet in
            AppStateBus.shared.scenes.currentSession = session
            AppStateBus.shared.scenes.currentEditor = session.activeTab.state
            AppStateBus.shared.presentation.present(sheet, owner: session.activeTab.state)
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
                        var currentText = target.state.textView?.text ?? target.document.text
                        // Apply save-time formatting to the live buffer only
                        // if the user did not edit while the exporter was up.
                        // The replace remains undoable; an Undo after Save
                        // correctly makes the document dirty again.
                        if currentText == snapshot.sourceText,
                           currentText != snapshot.savedText {
                            if let textView = target.state.textView {
                                textView.replace(
                                    NSRange(location: 0, length: (currentText as NSString).length),
                                    withText: snapshot.savedText
                                )
                            }
                            currentText = snapshot.savedText
                        }
                        target.document.finishExternalSave(
                            to: url,
                            savedText: snapshot.savedText,
                            savedData: snapshot.data,
                            currentText: currentText
                        )
                        target.state.text = currentText
                        target.state.fileURL = url
                        target.state.savedBaselineText = snapshot.savedText
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
                let tab = session.activeTab
                DocumentWorkflow.revert(url, in: tab)
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
                        onCancel: { session.activeTab.kind = .editor }
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
            onRestoreClosedWindow: { restoreClosedWindowFromLauncher($0) },
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
        TemplateWorkflow.apply(
            template,
            document: tab.document,
            state: tab.state
        )
        tab.kind = .editor
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
                // The scene went away while a recovery snapshot was loading.
            } catch {
                bus.presentation.openErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    static func adoptDraft(
        _ draft: DraftRecord,
        into tab: TabModel,
        store: DraftsStore = .shared
    ) async throws -> SourceStaleCheck? {
        try await DraftRecoveryWorkflow.adopt(draft, into: tab, store: store)
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
        if let route, case .restoreClosedWindow(let archivedID) = route {
            self.route = nil
            if let archived = closedWindows.record(id: archivedID) {
                restoreClosedWindow(archived)
                return
            }
            bus.presentation.openErrorMessage =
                "That recoverable window is no longer available."
        }
        if let record = SessionsStore.shared.consumePendingRestore() {
            SessionRestore.apply(record, to: session)
        }
    }

    /// A launcher-only window can be replaced in place. A launcher tab in a
    /// window that already contains other work opens the archive separately,
    /// preserving both the current window and the archived tab group.
    private func restoreClosedWindowFromLauncher(_ archived: ClosedWindowRecord) {
        if session.tabs.count == 1 {
            restoreClosedWindow(archived)
        } else {
            restoreClosedWindowInNewScene(archived)
        }
    }

    private func restoreClosedWindowInNewScene(_ archived: ClosedWindowRecord) {
        closedWindows.dismissNotice()
        guard let openEditorWindow = bus.scenes.openEditorWindow else {
            bus.presentation.openErrorMessage =
                "A new window isn't available yet. The recovered window was kept so you can try again."
            return
        }
        openEditorWindow(.restoreClosedWindow(archived.id))
    }

    /// Save the replacement open-session record before removing recovery
    /// metadata. This keeps every draft filename protected without a gap
    /// while the async file/draft population work begins.
    private func restoreClosedWindow(_ archived: ClosedWindowRecord) {
        let replacement = archived.sessionRecord(
            sceneUUID: sceneUUID,
            launchID: SessionsStore.shared.currentLaunchID,
            persistentIdentifier: SessionsStore.shared.persistentIdentifier(
                forSceneUUID: sceneUUID
            )
        )
        SessionsStore.shared.save(replacement)
        SessionRestore.apply(replacement, to: session)
        closedWindows.completeRestore(archived.id)
    }

    /// Snapshots current tabs (file bookmarks + draft refs + active
    /// index) under the scene's UUID. Re-saves on every background
    /// transition so a force-quit picks up the latest state.
    private func persistSessionRecord() {
        guard !sceneUUID.isEmpty, !session.isClosingWindow else { return }
        let previous = persistenceTask
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Persist editor recovery"
        )
        persistenceTask = Task { @MainActor in
            _ = await previous?.value
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            do {
                try await persistSessionRecordNow()
            } catch {
                bus.presentation.openErrorMessage =
                    "Couldn't preserve this window: \(error.localizedDescription)"
            }
        }
    }

    private func persistSessionRecordNow() async throws {
        guard !sceneUUID.isEmpty, !session.isClosingWindow else { return }
        try await DraftsStore.shared.withCapEnforcementSuspended {
            for tab in session.tabs where tab.document.isDirty {
                if let live = tab.state.textView?.text {
                    tab.document.text = live
                }
                try await tab.document.commitRecoverySnapshot()
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

private struct ClosedWindowRecoveryBanner: View {
    let record: ClosedWindowRecord
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.clock")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Window closed")
                    .font(.subheadline.weight(.semibold))
                Text(recoveryMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Restore", action: onRestore)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss recovery notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .frame(maxWidth: 620)
    }

    private var recoveryMessage: String {
        let noun = record.dirtyTabCount == 1 ? "tab" : "tabs"
        return "\(record.dirtyTabCount) unsaved \(noun) kept on this iPad."
    }
}

private struct ExportSnapshot: Sendable {
    let tabID: UUID
    let sourceText: String
    let savedText: String
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
