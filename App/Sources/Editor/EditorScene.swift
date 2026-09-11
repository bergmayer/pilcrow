import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding
import UIKit

/// Hosts one editor session and its scene-level presentation state.
struct EditorScene: View {

    @Binding private var route: EditorRoute?
    @State private var session: EditorSession
    @Bindable private var bus = AppStateBus.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var sceneReceivedOpenURL = false
    @State private var didApplySessionRecord = false
    @State private var sceneUUID: String = ""
    @State private var picker: FilePickerPresentation?
    @State private var pickerTask: Task<Void, Never>?
    @State private var closeSaveTask: Task<Void, Never>?
    @State private var closeSaveCompletion: CheckedContinuation<Bool, any Error>?
    @State private var closeReview: CloseReviewState?
    @State private var documentsVisible = true
    @State private var showingDocuments = false
    @State private var persistenceTask: Task<Void, Never>?
    @Bindable private var prefs = AppPreferencesStore.shared
    @Bindable private var closedWindows: ClosedWindowsStore

    init(route: Binding<EditorRoute?>, session: EditorSession = EditorSession(),
         closedWindows: ClosedWindowsStore = .shared) {
        self._route = route
        self._session = State(initialValue: session)
        self.closedWindows = closedWindows
    }

    private var document: PlainTextDocument { session.activeTab.document }
    private var state: EditorState { session.activeTab.state }

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
        // Keep keyboard avoidance native and singular. NavigationStack
        // already applies the scene's keyboard safe area to its content.
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
                    .accessibilityHidden(session.tabSwitcherActive)

                if session.tabSwitcherActive {
                    TabSwitcherView(
                        session: session,
                        onDismiss: dismissSwitcher
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
        .disabled(closeSaveTask != nil)
        .allowsHitTesting(closeSaveTask == nil)
        .preferredColorScheme(scenePreferredScheme)
        .focusedSceneValue(\.focusedSession, session)
        .modifier(SingleDocumentCloseAlert(
            presented: singleClosePresented,
            request: closeReview?.request,
            onConfirm: completeCloseReview
        ))
            .sheet(isPresented: reviewPresented, onDismiss: finishCloseReview) {
                if let request = closeReview?.request {
                    CloseReviewSheet(tabs: request.tabs) { selected in
                        closeReview = .confirmed(request, selected)
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    AppStateBus.shared.scenes.currentSession = session
                    AppStateBus.shared.scenes.registerSession(session)
                    AppStateBus.shared.scenes.claimFocus(session: session)
                    return
                }
                for tab in session.tabs {
                    tab.state.transformTask?.cancel()
                    tab.secondaryState?.transformTask?.cancel()
                }
                // Dirty tabs autosave inside persistSessionRecord, so
                // every persist caller (background + onDisappear) is
                // covered without double-saving here.
                persistSessionRecord()
            }
            .onAppear {
                session.requestClose = reviewClose
                session.requestSaveAllAndCloseWindow = { performSaveAndClose(.window) }
                AppStateBus.shared.scenes.currentSession = session
                AppStateBus.shared.scenes.registerSession(session)
                markColdLaunchHandled()
                applySessionRestoreIfNeeded()
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
            .onChange(of: session.tabs.map(\.id)) { session.persistRestorationRecord() }
            .onChange(of: session.selectedTabID) { session.persistRestorationRecord() }
            .onChange(of: session.tabs.map { $0.document.isDirty }) { session.persistRestorationRecord() }
            .onChange(of: session.tabs.map { $0.document.fileURL }) { session.persistRestorationRecord() }
            .onOpenURL { url in
                sceneReceivedOpenURL = true
                route(open: url)
            }
            .onDisappear {
                closeReview = nil
                session.requestClose = nil
                session.requestSaveAllAndCloseWindow = nil
                cancelCloseSave()
                pickerTask?.cancel()
                AppStateBus.shared.scenes.deregisterSession(session)
                persistSessionRecord()
                for tab in session.tabs {
                    tab.state.loadTask?.cancel()
                    tab.state.loadTask = nil
                }
            }
            .background(SceneRegistrationBridge(
                sceneUUID: sceneUUID,
                unsavedDocumentCount: session.isClosingWindow ? 0 : session.unsavedDocumentCount,
                onReview: { reviewClose(.window) },
                onClose: discardWindowAndClose
            ))
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
            .background {
                if let picker {
                    EditorFilePicker(presentation: picker, completion: completePicker)
                        .id(picker.id)
                }
            }
            .onChange(of: session.pickers.pending) { _, intent in
                guard let intent else { return }
                session.pickers.pending = nil
                guard closeSaveTask == nil else { return }
                preparePicker(intent)
            }
            .overlay(alignment: .topTrailing) {
                if closeSaveTask != nil || pickerTask != nil {
                    HStack {
                        ProgressView(closeSaveTask != nil ? "Saving documents…" : "Preparing document…")
                        Button("Cancel") {
                            if closeSaveTask != nil { cancelCloseSave() }
                            else { pickerTask?.cancel() }
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
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

    private var usesDocumentSidebar: Bool {
        !DeviceIdiom.isPhone && prefs.documentTabAppearance == .sidebar
    }

    private var editorStack: some View {
        GeometryReader { geometry in
            let inlineSidebar = geometry.size.width >= 600
            VStack(spacing: 0) {
                if DeviceIdiom.supportsMultipleWindows && prefs.showToolbar {
                    WindowToolbar(
                        title: session.activeTab.kind == .editor ? documentTitle : nil,
                        subtitle: documentSubtitle,
                        onInteraction: {
                            bus.scenes.claimFocus(session: session)
                        },
                        onToggleSidebar: {
                            if usesDocumentSidebar {
                                if inlineSidebar { documentsVisible.toggle() } else { showingDocuments.toggle() }
                            } else {
                                state.sidebarOpen.toggle()
                            }
                        }
                    )
                }
                if !DeviceIdiom.isPhone {
                    if usesDocumentSidebar {
                        if !inlineSidebar || !documentsVisible {
                            HStack {
                                Button {
                                    showingDocuments.toggle()
                                } label: {
                                    Label("Documents (\(session.tabs.count))", systemImage: "sidebar.left")
                                        .frame(minHeight: 44)
                                }
                                .accessibilityIdentifier("show-documents")
                                Spacer()
                                if inlineSidebar {
                                    Button("Show Sidebar") { documentsVisible = true }
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    } else {
                        TabBarView(session: session)
                    }
                }
                HStack(spacing: 0) {
                    if !DeviceIdiom.isPhone,
                        state.sidebarOpen || (usesDocumentSidebar && inlineSidebar && documentsVisible)
                    {
                        VStack(spacing: 0) {
                            if usesDocumentSidebar && inlineSidebar && documentsVisible {
                                TabBarView(session: session, appearance: .sidebar)
                            }
                            if state.sidebarOpen {
                                OutlineSidebar(document: document, state: state)
                            }
                        }
                        .frame(width: 260)
                        Divider()
                    }
                    activeTabContent
                        .id(session.selectedTabID)
                }
                .accessibilityHidden(usesDocumentSidebar && showingDocuments)
                .overlay(alignment: .leading) {
                    if usesDocumentSidebar && showingDocuments {
                        ZStack(alignment: .leading) {
                            Button {
                                showingDocuments = false
                            } label: {
                                Color.black.opacity(0.2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close Document List")
                            TabBarView(
                                session: session, appearance: .sidebar,
                                onSelection: { showingDocuments = false }
                            )
                            .frame(maxWidth: 320)
                            .padding(.trailing, 44)
                            .shadow(radius: 8)
                        }
                    }
                }
            }
        }
        .onChange(of: prefs.documentTabAppearance) { _, _ in showingDocuments = false }
    }

    /// `.launcher` / `.fileBrowser` inject their UI via
    /// `tabContentOverride` so the surrounding chrome stays put
    /// regardless of what's filling the text-area region.
    @ViewBuilder
    private var activeTabContent: some View {
        let tab = session.activeTab
        switch tab.kind {
        case .editor:
            EditorView(document: document, state: state)
        case .fileBrowser:
            EditorView(
                document: document,
                state: state,
                tabContentOverride: AnyView(
                    FileBrowserTabContent(
                        onPick: { url in
                            guard session.tabs.contains(tab) else { return }
                            DocumentWorkflow.open(url, in: tab)
                        },
                        onCancel: { tab.kind = .launcher }
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
        let tab = session.activeTab
        NewDocumentLauncherView(
            session: session,
            onPickBlank: { tab.startDocument() },
            onPickTemplate: { TemplateWorkflow.apply($0, to: tab) },
            onPickOpenFile: { tab.kind = .fileBrowser },
            onPickClipboard: { tab.startDocument(with: $0) },
            isWindowScopeLauncher: session.tabs.count == 1,
            onCancel: {
                CommandActions.requestCloseTab(tab.id, in: session)
            },
            showsCancel: session.tabs.count > 1
        )
    }

    /// Stable across tab switches. Keyed off active tab id earlier,
    /// which made every Cmd-T fire a matched-geometry interpolation
    /// from the previous tab's frame.
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

    private func preparePicker(_ intent: PickerIntent) {
        guard picker == nil, pickerTask == nil else { return }
        let tab = session.activeTab
        let preferred = bus.scenes.currentEditor
        let editor = tab.owns(preferred) ? (preferred ?? tab.state) : tab.state
        let target = PickerTarget(intent: intent, tab: tab, editor: editor,
            loadGeneration: tab.state.loadGeneration, bufferRevision: tab.document.bufferRevision,
            selection: editor.textView?.selectedRange ?? editor.selectedRange,
            sourceURL: tab.document.fileURL, displayName: tab.document.fileURL?.lastPathComponent
                ?? LanguageRegistry.suggestedFilename(tab.document.displayName, language: editor.languageIdentifier))
        guard intent == .saveAs else { picker = .importing(target); return }
        let input = editor.textView?.text ?? tab.document.text
        let settings = tab.document.saveSettings
        pickerTask = Task { @MainActor in
            defer { pickerTask = nil }
            let worker = Task.detached(priority: .userInitiated) {
                let prepared = try settings.prepare(input)
                try Task.checkCancellation()
                return ExportSnapshot(sourceText: input, savedText: prepared.text,
                    data: prepared.data, settings: settings)
            }
            do {
                let snapshot = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard target.isCurrent(in: session) else { throw CancellationError() }
                picker = .exporting(target, snapshot)
            } catch is CancellationError {
                finishCloseSaveAs(.success(false))
            } catch {
                if !finishCloseSaveAs(.failure(error)) {
                    bus.presentation.openErrorMessage = "Couldn't prepare Save As: " + error.localizedDescription
                }
            }
        }
    }

    private func completePicker(_ target: PickerTarget, _ snapshot: ExportSnapshot?, _ result: Result<URL, any Error>) {
        guard picker?.id == target.id else { return }
        picker = nil
        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                finishCloseSaveAs(.success(false))
            } else if !finishCloseSaveAs(.failure(error)) {
                bus.presentation.openErrorMessage = error.localizedDescription
            }
        case .success(let url):
            guard target.isCurrent(in: session) else {
                if !finishCloseSaveAs(.failure(CancellationError())) {
                    bus.presentation.openErrorMessage = "The originating document is no longer open."
                }
                return
            }
            if target.intent == .open { route(open: url); return }
            pickerTask = Task { @MainActor in
                defer { pickerTask = nil }
                do {
                    if let snapshot {
                        let saved = try await CoordinatedFileAccess.perform(at: url) { exportedURL in
                            guard try Data(contentsOf: exportedURL) == snapshot.data else {
                                throw PlainTextDocument.DocumentError.sourceChanged
                            }
                            let date = try exportedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                            return PlainTextDocument.SavedSnapshot(url: exportedURL, inputText: snapshot.sourceText,
                                text: snapshot.savedText, data: snapshot.data, encoding: snapshot.settings.encoding,
                                lineEnding: snapshot.settings.lineEnding, modificationDate: date)
                        }
                        try Task.checkCancellation()
                        guard target.isCurrent(in: session) else { throw CancellationError() }
                        DocumentWorkflow.adoptSavedSnapshot(saved, into: target.tab)
                        target.tab.state.languageIdentifier = LanguageRegistry.identifier(for: saved.url)
                        target.tab.state.isLargeFile = !SyntaxLimit.current().allows(byteCount: saved.data.count)
                        RecentFilesStore.shared.record(saved.url)
                        finishCloseSaveAs(.success(true))
                    } else {
                        let text = try await DocumentWorkflow.insertionText(from: url,
                            folder: target.intent == .insertFolder, lineEnding: target.editor.lineEnding.string)
                        try Task.checkCancellation()
                        guard target.isCurrent(in: session),
                              target.tab.document.bufferRevision == target.bufferRevision,
                              let editor = target.editor.textView, editor.selectedRange == target.selection else {
                            throw DocumentWorkflow.InsertionError.documentChanged
                        }
                        editor.replace(target.selection, withText: text)
                    }
                } catch is CancellationError { finishCloseSaveAs(.success(false)) }
                catch {
                    if !finishCloseSaveAs(.failure(error)) {
                        let operation = snapshot == nil ? "insert" : "finish adopting the exported copy of"
                        bus.presentation.openErrorMessage = "Couldn't \(operation) \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func discardWindowAndClose() {
        closeReview = nil
        cancelCloseSave()
        guard let scene = SessionsStore.shared.scene(forSceneUUID: session.sceneUUID) else {
            state.operationError = "The window is not ready to close. Please try again."
            return
        }
        CommandActions.closeWindow(session, scene: scene, discardChanges: true)
    }

    private var singleClosePresented: Binding<Bool> {
        Binding(
            get: { if case .choosing(let request) = closeReview { request.usesSimpleAlert } else { false } },
            set: { presented in
                if !presented, case .choosing = closeReview { closeReview = nil }
            }
        )
    }

    private var reviewPresented: Binding<Bool> {
        Binding(
            get: { if case .choosing(let request) = closeReview { !request.usesSimpleAlert } else { false } },
            set: { presented in
                if !presented, case .choosing = closeReview { closeReview = nil }
            }
        )
    }

    private func reviewClose(_ target: EditorSession.CloseTarget) {
        guard closeSaveTask == nil, closeReview == nil else { return }
        guard picker == nil, pickerTask == nil else {
            state.operationError = "Finish or cancel the current file operation before saving and closing."
            return
        }
        let candidates: [TabModel]
        switch target {
        case .window: candidates = session.tabs
        case .tabs(let ids): candidates = session.tabs.filter { ids.contains($0.id) }
        }
        for tab in candidates {
            tab.state.textView?.resignFirstResponder()
            tab.secondaryState?.textView?.resignFirstResponder()
            if let live = tab.state.textView?.text { tab.document.text = live }
        }
        let dirty = candidates.filter(\.needsCloseConfirmation)
        if !dirty.isEmpty {
            closeReview = .choosing(CloseReviewRequest(target: target, tabs: dirty))
        } else {
            performSaveAndClose(target)
        }
    }

    private func finishCloseReview() {
        guard case .confirmed(let request, let selected) = closeReview else { return }
        completeCloseReview(request, saving: selected)
    }

    private func completeCloseReview(_ request: CloseReviewRequest, saving selected: Set<UUID>) {
        closeReview = nil
        let reviewed = Set(request.tabs.map(\.id))
        performSaveAndClose(request.target, discarding: reviewed.subtracting(selected), reviewed: reviewed)
    }

    private func performSaveAndClose(
        _ target: EditorSession.CloseTarget, discarding: Set<UUID> = [], reviewed: Set<UUID>? = nil
    ) {
        guard closeSaveTask == nil, closeReview == nil else { return }
        guard picker == nil, pickerTask == nil else {
            state.operationError = "Finish or cancel the current file operation before saving and closing."
            return
        }
        let tabIDs: [UUID]?
        switch target {
        case .window: tabIDs = nil
        case .tabs(let ids): tabIDs = ids
        }
        // onDismiss runs inside SwiftUI's sheet update. Resigning a responder
        // there synchronously lays out the keyboard and reenters SheetBridge,
        // causing an exclusivity crash. The owned task leaves that stack before
        // touching UIKit or presenting the next document's Save As dialog.
        closeSaveTask = Task { @MainActor in
            defer { closeSaveTask = nil }
            do {
                try Task.checkCancellation()
                for tab in session.tabs {
                    tab.state.textView?.resignFirstResponder()
                    tab.secondaryState?.textView?.resignFirstResponder()
                    if let live = tab.state.textView?.text { tab.document.text = live }
                }
                guard
                    try await session.saveDocumentsBeforeClosing(
                        tabIDs: tabIDs, discarding: discarding, reviewed: reviewed,
                        saveUntitled: { _ in
                            // The session selected this tab before asking for its destination.
                            bus.scenes.claimFocus(session: session)
                            return try await withCheckedThrowingContinuation { continuation in
                                closeSaveCompletion = continuation
                                preparePicker(.saveAs)
                            }
                        })
                else { return }
                try Task.checkCancellation()
                switch target {
                case .window:
                    guard let scene = SessionsStore.shared.scene(forSceneUUID: session.sceneUUID) else {
                        state.operationError = "The window is not ready to close. Its tabs have been kept open."
                        return
                    }
                    CommandActions.closeWindow(session, scene: scene, discardChanges: !discarding.isEmpty)
                case .tabs(let ids):
                    for id in ids {
                        session.closeTab(id, disposition: discarding.contains(id) ? .discard : .archive)
                    }
                }
            } catch is CancellationError {} catch {
                state.operationError = "Couldn't save \(document.displayName): \(error.localizedDescription)"
            }
        }
    }

    private func cancelCloseSave() {
        guard closeSaveTask != nil else { return }
        closeSaveTask?.cancel()
        pickerTask?.cancel()
        picker = nil
        finishCloseSaveAs(.success(false))
    }

    @discardableResult
    private func finishCloseSaveAs(_ result: Result<Bool, any Error>) -> Bool {
        guard let continuation = closeSaveCompletion else { return false }
        closeSaveCompletion = nil
        continuation.resume(with: result)
        return true
    }

    private func markColdLaunchHandled() {
        AppStateBus.shared.scenes.hasAppliedLaunchBehavior = true
        SessionsStore.shared.purgeHiddenSessions()
    }

    /// The first scene seeds restoration and requests one window per
    /// remaining record. Each typed request claims its own record once.
    private func applySessionRestoreIfNeeded() {
        guard !didApplySessionRecord else { return }
        didApplySessionRecord = true
        if sceneUUID.isEmpty {
            sceneUUID = UUID().uuidString
        }
        session.sceneUUID = sceneUUID
        let store = SessionsStore.shared
        let startingRestore = store.initiateRestoreSweep() > 0
        let request = route
        if let request {
            switch request {
            case .newDocument:
                break
            case .openDocument(let url, let line, _):
                DocumentWorkflow.open(url, in: session.activeTab, goToLine: line)
            case .moveTab(let tabID):
                if let source = bus.scenes.session(containing: tabID), source !== session,
                   let tab = source.detachTab(tabID) {
                    let placeholder = session.activeTab
                    session.attachTab(tab)
                    session.tabs.removeAll { $0 === placeholder }
                    tab.state.requestEditorFocus()
                } else {
                    bus.presentation.openErrorMessage = "That tab is no longer available to move."
                }
            case .restoreSession(let recordID):
                guard let record = store.consumePendingRestore(sceneUUID: recordID) else {
                    dismissWindow()
                    return
                }
                sceneUUID = record.sceneUUID
                session.sceneUUID = sceneUUID
                SessionRestore.apply(record, to: session)
            case .restoreClosedWindow(let archivedID):
                if let archived = closedWindows.record(id: archivedID) {
                    restoreClosedWindow(archived)
                } else {
                    bus.presentation.openErrorMessage = "That recoverable window is no longer available."
                }
            }
            route = nil
        } else if let record = store.consumePendingRestore() {
            sceneUUID = record.sceneUUID
            session.sceneUUID = sceneUUID
            SessionRestore.apply(record, to: session)
        }
        if startingRestore {
            for recordID in store.pendingRestoreSceneIDs {
                openWindow(id: SceneID.editor.rawValue, value: EditorRoute.restoreSession(recordID))
            }
        }
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
        try await session.checkpointDocuments()
        session.persistRestorationRecord()
        DraftsStore.shared.enforceCapNow()
    }

    private func applyHomeShortcut(_ shortcut: HomeShortcut) {
        switch shortcut {
        case .newFile:
            openWindow(id: SceneID.editor.rawValue, value: EditorRoute.newDocument())
        case .commandPalette:
            CommandActions.presentCommandPalette()
        }
    }

    private func route(open url: URL) {
        if DeviceIdiom.supportsMultipleWindows {
            openWindow(id: SceneID.editor.rawValue, value: EditorRoute.openDocument(url))
        } else {
            let tab = session.newTab(kind: .editor)
            DocumentWorkflow.open(url, in: tab)
        }
    }

    private func openURL(_ url: URL) {
        DocumentWorkflow.open(url, in: session.activeTab)
    }

}

private struct PickerTarget: Sendable {
    let id = UUID()
    let intent: PickerIntent
    let tab: TabModel
    let editor: EditorState
    let loadGeneration: UInt64
    let bufferRevision: UInt64
    let selection: NSRange
    let sourceURL: URL?
    let displayName: String

    var filenameLabel: String {
        let suffix = (displayName as NSString).pathExtension
        return suffix.isEmpty ? "Name" : "Name (without .\(suffix))"
    }

    @MainActor func isCurrent(in session: EditorSession) -> Bool {
        !session.isClosingWindow && session.tabs.contains { $0 === tab }
            && tab.state.loadGeneration == loadGeneration && tab.document.fileURL == sourceURL
    }
}

private struct ExportSnapshot: Sendable {
    let sourceText: String
    let savedText: String
    let data: Data
    let settings: PlainTextDocument.SaveSettings
}

private enum FilePickerPresentation: Identifiable {
    case importing(PickerTarget)
    case exporting(PickerTarget, ExportSnapshot)

    var id: UUID {
        switch self {
        case .importing(let target), .exporting(let target, _): target.id
        }
    }
}

/// Immutable per-presentation inputs keep native picker callbacks tied to
/// their originating tab, even when another window or tab becomes active.
private struct EditorFilePicker: View {
    let presentation: FilePickerPresentation
    let completion: (PickerTarget, ExportSnapshot?, Result<URL, any Error>) -> Void
    @State private var presented = false

    var body: some View {
        Group {
            switch presentation {
            case .importing(let target):
                Color.clear.frame(width: 0, height: 0)
                    .fileImporter(isPresented: $presented,
                        allowedContentTypes: target.intent == .insertFolder ? [.folder] : PlainTextDocument.supportedReadTypes,
                        allowsMultipleSelection: false,
                        onCompletion: { result in
                            completion(target, nil, result.flatMap { urls in
                                guard let url = urls.first else { return .failure(CocoaError(.fileReadUnknown)) }
                                return .success(url)
                            })
                        },
                        onCancellation: { completion(target, nil, .failure(CocoaError(.userCancelled))) })
            case .exporting(let target, let snapshot):
                Color.clear.frame(width: 0, height: 0)
                    .fileExporter(isPresented: $presented, document: TextFileWrapperProxy(data: snapshot.data),
                        contentTypes: [.data],
                        defaultFilename: target.displayName,
                        onCompletion: { completion(target, snapshot, $0) },
                        onCancellation: { completion(target, snapshot, .failure(CocoaError(.userCancelled))) })
                    .fileExporterFilenameLabel(target.filenameLabel)
                    .fileDialogBrowserOptions(.displayFileExtensions)
            }
        }
        .onAppear { presented = true }
    }
}

private struct CloseReviewRequest {
    let target: EditorSession.CloseTarget
    let tabs: [TabModel]

    var usesSimpleAlert: Bool {
        if case .window = target { return false }
        return tabs.count == 1
    }
}

private enum CloseReviewState {
    case choosing(CloseReviewRequest)
    case confirmed(CloseReviewRequest, Set<UUID>)

    var request: CloseReviewRequest {
        switch self {
        case .choosing(let request), .confirmed(let request, _): request
        }
    }
}

/// Keep the alert's generic builder outside the scene's long modifier chain.
private struct SingleDocumentCloseAlert: ViewModifier {
    @Binding var presented: Bool
    let request: CloseReviewRequest?
    let onConfirm: (CloseReviewRequest, Set<UUID>) -> Void

    func body(content: Content) -> some View {
        content.alert("Save Changes Before Closing?", isPresented: $presented, presenting: request) { request in
            Button(request.tabs.first?.document.fileURL == nil ? "Save…" : "Save") {
                onConfirm(request, Set(request.tabs.map(\.id)))
            }
            Button("Don’t Save", role: .destructive) {
                onConfirm(request, [])
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("Save changes to “\(request.tabs.first?.document.displayName ?? "this document")”? Your changes will be lost if you don’t save them.")
        }
    }
}

/// A choice for each unsaved document, with one explicit decision to close.
/// No changes are discarded until every selected save has succeeded.
private struct CloseReviewSheet: View {
    let tabs: [TabModel]
    let onConfirm: (Set<UUID>) -> Void
    @State private var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(tabs: [TabModel], onConfirm: @escaping (Set<UUID>) -> Void) {
        self.tabs = tabs
        self.onConfirm = onConfirm
        _selected = State(initialValue: Set(tabs.map(\.id)))
    }

    private var saveTitle: String {
        selected.count == tabs.count ? "Save All" : "Save Selected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label {
                Text("Save documents before closing?")
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "doc.text")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
            }
            .accessibilityIdentifier("close-review-title")

            Text("If you don’t save, your changes will be lost. Choose the documents to save.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(tabs) { tab in
                Button {
                    if selected.contains(tab.id) { selected.remove(tab.id) } else { selected.insert(tab.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(tab.id) ? "checkmark.square.fill" : "square")
                            .contentTransition(.identity)
                            .transaction {
                                $0.animation = nil
                                $0.disablesAnimations = true
                            }
                            .foregroundStyle(.tint)
                        Label(tab.document.displayName, systemImage: "doc.text")
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save \(tab.document.displayName)")
                .accessibilityValue(selected.contains(tab.id) ? "Selected" : "Not selected")
                .accessibilityAddTraits(selected.contains(tab.id) ? .isSelected : [])
                .accessibilityIdentifier("save-\(tab.id)")
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
            .listStyle(.plain)
            .frame(minHeight: 88, idealHeight: 180, maxHeight: 260)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(selected.count) to save · \(tabs.count - selected.count) to discard")
                    .accessibilityIdentifier("close-review-selection-count")
                Text("Unchecked documents will close without saving.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    discardButton
                    Spacer(minLength: 0)
                    cancelButton
                    saveButton
                }
                VStack(spacing: 12) {
                    saveButton
                    cancelButton
                    discardButton
                            }
                        }
                    }
        .padding(24)
        .presentationSizing(.fitted)
    }

    private var discardButton: some View {
        Button("Don’t Save", role: .destructive) { onConfirm([]) }
            .buttonStyle(.bordered)
            .controlSize(.large)
    }

    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
    }

    private var saveButton: some View {
        Button(saveTitle) { onConfirm(selected) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selected.isEmpty)
            .keyboardShortcut(.defaultAction)
                }
            }
