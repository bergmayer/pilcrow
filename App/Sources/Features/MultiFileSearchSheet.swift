import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CryptoKit
import EditorEngine

/// Searches a folder, the current window, or all open windows.
struct MultiFileSearchSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Bindable private var bus = AppStateBus.shared

    enum Scope: String, CaseIterable, Identifiable {
        case folder
        case tabs
        case windows
        var id: String { rawValue }

        var label: String {
            switch self {
            case .folder:  return "Folder…"
            case .tabs:    return DeviceIdiom.isPhone ? "Open Tabs" : "Tabs in Source Window"
            case .windows: return "All Open Windows"
            }
        }
    }

    @MainActor
    @Observable
    fileprivate final class Model {
        enum Activity {
            case idle
            case searching
            case replacing
        }

        enum Prompt {
            case none
            case confirmReplaceAll
            case query(Int)
        }

        weak var owner: EditorSession?

        init(owner: EditorSession?) { self.owner = owner }

        var context = AppStateBus.shared.find.context
        var scope: Scope = .folder
        var folder: URL?
        var pickingFolder = false
        var extensionFilter = "swift,m,h,c,cpp,js,ts,tsx,py,rb,go,rs,java,kt,html,css,xml,json,yaml,yml,md,txt"
        var searchTask: Task<Void, Never>?
        var searchGeneration = UUID()
        var searchedContext: FindContext?
        var fingerprints: [ResultGroupKey: Data] = [:]
        var activity: Activity = .idle
        var sourcesScanned = 0
        var results: [SearchResult] = []
        var groups: [ResultGroup] = []
        var errorText: String?
        var seenFirstAppear = false
        var currentResultIndex = -1
        var prompt: Prompt = .none
        var queryOffsetDeltas: [ResultGroupKey: Int] = [:]
        var replaceSummary: String?

        var isSearching: Bool {
            get { activity == .searching }
            set { activity = newValue ? .searching : .idle }
        }

        var pendingReplaceAllConfirm: Bool {
            get {
                if case .confirmReplaceAll = prompt { return true }
                return false
            }
            set {
                if newValue {
                    prompt = .confirmReplaceAll
                } else if case .confirmReplaceAll = prompt {
                    prompt = .none
                }
            }
        }

        var queryCursor: Int? {
            get {
                if case .query(let index) = prompt { return index }
                return nil
            }
            set { prompt = newValue.map(Prompt.query) ?? .none }
        }
    }

    /// iPhone is single-scene, so "All Open Windows" is hidden.
    private static var availableScopes: [Scope] {
        DeviceIdiom.isPhone ? [.folder, .tabs] : Scope.allCases
    }

    @State private var model: Model
    private let request: UtilityWindowRequest?
    private let isStandalone: Bool

    init(owner: EditorSession?) {
        _model = State(initialValue: Model(owner: owner))
        request = nil
        isStandalone = false
    }

    init(request: UtilityWindowRequest?) {
        self.request = request
        isStandalone = true
        let owner = AppStateBus.shared.scenes.allOpenSessions.first { $0.sceneUUID == request?.ownerSessionID }
        _model = State(initialValue: Model(owner: owner))
    }

    private var scope: Scope { get { model.scope } nonmutating set { model.scope = newValue } }
    private var folder: URL? { get { model.folder } nonmutating set { model.folder = newValue } }
    private var pickingFolder: Bool { get { model.pickingFolder } nonmutating set { model.pickingFolder = newValue } }
    private var extensionFilter: String { get { model.extensionFilter } nonmutating set { model.extensionFilter = newValue } }
    private var searchTask: Task<Void, Never>? { get { model.searchTask } nonmutating set { model.searchTask = newValue } }
    private var isSearching: Bool { get { model.isSearching } nonmutating set { model.isSearching = newValue } }
    private var sourcesScanned: Int { get { model.sourcesScanned } nonmutating set { model.sourcesScanned = newValue } }
    private var results: [SearchResult] { get { model.results } nonmutating set { model.results = newValue } }
    private var groups: [ResultGroup] { get { model.groups } nonmutating set { model.groups = newValue } }
    private var errorText: String? { get { model.errorText } nonmutating set { model.errorText = newValue } }
    private var seenFirstAppear: Bool { get { model.seenFirstAppear } nonmutating set { model.seenFirstAppear = newValue } }
    private var currentResultIndex: Int { get { model.currentResultIndex } nonmutating set { model.currentResultIndex = newValue } }
    private var pendingReplaceAllConfirm: Bool { get { model.pendingReplaceAllConfirm } nonmutating set { model.pendingReplaceAllConfirm = newValue } }
    private var queryCursor: Int? { get { model.queryCursor } nonmutating set { model.queryCursor = newValue } }
    private var queryOffsetDeltas: [ResultGroupKey: Int] { get { model.queryOffsetDeltas } nonmutating set { model.queryOffsetDeltas = newValue } }
    private var replaceSummary: String? { get { model.replaceSummary } nonmutating set { model.replaceSummary = newValue } }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                querySection
                if scope == .folder {
                    folderSection
                    extensionSection
                }
                controlsSection
                resultsSection
            }
            .disabled(model.activity == .replacing)
            .navigationTitle("Multi-File Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        searchTask?.cancel()
                        close()
                    }
                }
            }
            .fileImporter(
                isPresented: Binding(
                    get: { pickingFolder },
                    set: { pickingFolder = $0 }
                ),
                allowedContentTypes: [.folder]
            ) { result in
                switch result {
                case .success(let url): folder = url
                case .failure(let error): errorText = error.localizedDescription
                }
            }
            .onAppear {
                if !seenFirstAppear {
                    seenFirstAppear = true
                    // Do not restore this utility window after relaunch.
                    if isStandalone, request?.launchID != SessionsStore.shared.currentLaunchID {
                        openWindow(id: SceneID.editor.rawValue, value: EditorRoute.newDocument())
                        close()
                        return
                    }
                }
            }
            .onDisappear { searchTask?.cancel() }
            .alert(
                "Replace in all \(uniqueSourceCount) source\(uniqueSourceCount == 1 ? "" : "s")?",
                isPresented: Binding(
                    get: { pendingReplaceAllConfirm },
                    set: { pendingReplaceAllConfirm = $0 }
                )
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Replace All", role: .destructive) { runReplacement { await replaceMatches(results) } }
            } message: {
                Text("Replaces the displayed matches. Folder searches write the source files; open-tab searches edit buffers with undo.")
            }
            .alert(
                queryAlertTitle,
                isPresented: queryAlertBinding,
                presenting: currentQueryResult
            ) { _ in
                Button("Skip") { queryAdvance() }
                Button("Replace") { runReplacement { await queryReplaceAndAdvance() } }
                Button("Replace All Remaining", role: .destructive) { runReplacement { await replaceMatches(Array(results.dropFirst(queryCursor ?? results.count))) } }
                Button("Cancel", role: .cancel) { queryCursor = nil }
            } message: { match in
                Text("\(match.groupLabel) line \(match.line):\n\(match.preview)")
            }
        }
    }

    private var queryAlertTitle: String {
        guard let cursor = queryCursor, results.indices.contains(cursor) else { return "" }
        return "Replace match \(cursor + 1) of \(results.count)?"
    }

    private var queryAlertBinding: Binding<Bool> {
        Binding(
            get: { queryCursor != nil && (queryCursor.map { results.indices.contains($0) } ?? false) },
            set: { newValue in if !newValue { queryCursor = nil } }
        )
    }

    private var currentQueryResult: SearchResult? {
        guard let cursor = queryCursor, results.indices.contains(cursor) else { return nil }
        return results[cursor]
    }

    private var uniqueSourceCount: Int {
        Set(results.map { $0.groupKey }).count
    }

    // MARK: - Sections

    @ViewBuilder
    private var scopeSection: some View {
        Section("Scope") {
            Picker(
                "Search in",
                selection: Binding(get: { scope }, set: { scope = $0 })
            ) {
                ForEach(Self.availableScopes) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) { _, _ in invalidateSearch() }
            .onChange(of: folder) { _, _ in invalidateSearch() }
            .onChange(of: extensionFilter) { _, _ in invalidateSearch() }
            .onChange(of: model.context) { previous, current in
                var previousPattern = previous
                previousPattern.replacement = current.replacement
                if previousPattern != current { invalidateSearch() }
            }
        }
    }

    @ViewBuilder
    private var querySection: some View {
        Section("Query") {
            TextField(
                model.context.useRegex ? "Regular expression" : "Find",
                text: $model.context.query
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(model.context.useRegex ? .body.monospaced() : .body)

            TextField("Replace with (optional)", text: $model.context.replacement)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(model.context.useRegex ? .body.monospaced() : .body)

            Toggle("Regular Expression", isOn: $model.context.useRegex)
            Toggle("Case Sensitive",    isOn: $model.context.caseSensitive)
            Toggle("Whole Word",        isOn: $model.context.wholeWord)
                .disabled(model.context.useRegex)
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        Section("Folder") {
            HStack {
                if let folder {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder chosen").foregroundStyle(.secondary)
                }
                Spacer()
                Button(folder == nil ? "Choose…" : "Change…") { pickingFolder = true }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var extensionSection: some View {
        Section {
            TextField(
                "Comma-separated (blank = all)",
                text: Binding(
                    get: { extensionFilter },
                    set: { extensionFilter = $0 }
                )
            )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.body.monospaced())
        } header: {
            Text("File Extensions")
        } footer: {
            Text("Files above 5 MB are skipped. Binary files are filtered automatically.")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            if isSearching {
                HStack {
                    ProgressView()
                    Text("Scanned \(sourcesScanned), \(results.count) match\(results.count == 1 ? "" : "es")…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { searchTask?.cancel() }
                }
            } else {
                Button {
                    startSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartSearch)
            }
            if !results.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        stepResult(by: -1)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text(positionLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        stepResult(by: 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                // Replace surfaces only after a search returns —
                // user sees the scope of damage first. Query walks
                // per-match; Replace All commits in one pass after
                // the final confirm.
                HStack(spacing: 12) {
                    Button {
                        beginQueryReplace()
                    } label: {
                        Label("Query", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(replacementContext == nil || model.activity != .idle)
                    Button(role: .destructive) {
                        pendingReplaceAllConfirm = true
                    } label: {
                        Label("Replace All", systemImage: "arrow.2.squarepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(replacementContext == nil || model.activity != .idle)
                }
            }
            if let replaceSummary {
                Text(replaceSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var positionLabel: String {
        guard !results.isEmpty else { return "" }
        let display = currentResultIndex < 0 ? 0 : currentResultIndex + 1
        return "\(display) / \(results.count)"
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !groups.isEmpty {
            Section("Results — \(results.count) match\(results.count == 1 ? "" : "es") in \(groups.count) source\(groups.count == 1 ? "" : "s")") {
                ForEach(groups) { group in
                    DisclosureGroup {
                        ForEach(group.matches) { match in
                            Button {
                                if let idx = results.firstIndex(of: match) {
                                    currentResultIndex = idx
                                    open(match)
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(currentResultIndex >= 0
                                                         && results.indices.contains(currentResultIndex)
                                                         && results[currentResultIndex].id == match.id
                                                         ? AnyShapeStyle(.tint)
                                                         : AnyShapeStyle(Color.clear))
                                        .frame(width: 12)
                                    Text("\(match.line)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(match.preview)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(match.url == nil && !match.isOpenTabResult)
                        }
                    } label: {
                        Label("\(group.label) (\(group.matches.count))",
                              systemImage: group.systemImage)
                    }
                }
            }
        } else if !isSearching && sourcesScanned > 0 {
            Section { Text("No matches.").foregroundStyle(.secondary) }
        }
    }

    // MARK: - Actions

    private func close() {
        if isStandalone { dismissWindow() } else { dismiss() }
    }

    private var canStartSearch: Bool {
        guard !model.context.query.isEmpty else { return false }
        switch scope {
        case .folder:  return folder != nil
        case .tabs:    return model.owner != nil
        case .windows: return !bus.scenes.allOpenSessions.isEmpty
        }
    }

    /// The new scene consumes `newWindow` on first appear; the
    /// `goToLine` lands once the buffer finishes loading.
    private func open(_ match: SearchResult) {
        if case .tab(let tabID) = match.groupKey {
            for session in bus.scenes.allOpenSessions {
                guard let tab = session.tabs.first(where: { $0.id == tabID }) else { continue }
                session.selectedTabID = tabID
                tab.kind = .editor
                tab.state.requestEditorFocus()
                if let textView = tab.state.textView {
                    textView.goToLine(match.line)
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        tab.state.textView?.goToLine(match.line)
                    }
                }
                if let scene = SessionsStore.shared.scene(forSceneUUID: session.sceneUUID) {
                    UIApplication.shared.requestSceneSessionActivation(
                        scene.session,
                        userActivity: nil,
                        options: nil
                    )
                }
                return
            }
        }
        guard let url = match.url else { return }
        CommandActions.routeOpenURL(url, in: model.owner, line: match.line)
    }

    private func stepResult(by delta: Int) {
        guard !results.isEmpty else { return }
        if currentResultIndex < 0 {
            currentResultIndex = delta > 0 ? 0 : results.count - 1
        } else {
            currentResultIndex = (currentResultIndex + delta + results.count) % results.count
        }
        open(results[currentResultIndex])
    }

    private func invalidateSearch() {
        searchTask?.cancel()
        searchTask = nil
        model.searchGeneration = UUID()
        model.activity = .idle
        model.searchedContext = nil
        model.fingerprints = [:]
        results = []
        groups = []
        sourcesScanned = 0
        currentResultIndex = -1
        queryCursor = nil
        queryOffsetDeltas = [:]
        errorText = nil
        replaceSummary = nil
    }

    private func startSearch() {
        searchTask?.cancel()
        let generation = UUID()
        model.searchGeneration = generation
        model.fingerprints = [:]
        model.searchedContext = nil
        errorText = nil
        results = []
        groups = []
        sourcesScanned = 0
        currentResultIndex = -1
        isSearching = true

        let ctx = model.context
        bus.find.context = ctx
        let exts = Set(
            extensionFilter
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        let scopeCopy = scope
        let folderCopy = folder
        // Snapshot before the scan so concurrent edits don't shift
        // offsets out from under us.
        let inMemorySources: [SearchEngine.InMemorySource]
        switch scopeCopy {
        case .folder:  inMemorySources = []
        case .tabs:    inMemorySources = SearchEngine.tabsSources(in: model.owner)
        case .windows: inMemorySources = SearchEngine.windowsSources()
        }

        searchTask = Task { @MainActor in
            defer {
                if model.searchGeneration == generation {
                    isSearching = false
                    searchTask = nil
                }
            }
            do {
                let matcher = try SearchEngine.compileMatcher(for: ctx)
                let worker: Task<SearchEngine.SearchOutput, any Error>
                if scopeCopy == .folder, let folderCopy {
                    worker = Task.detached(priority: .userInitiated) {
                        try await SearchEngine.runFolderSearch(
                            folder: folderCopy,
                            matcher: matcher,
                            extensions: exts
                        )
                    }
                } else {
                    worker = Task.detached(priority: .userInitiated) {
                        try SearchEngine.runInMemorySearch(
                            sources: inMemorySources,
                            matcher: matcher
                        )
                    }
                }
                let output = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard model.searchGeneration == generation else { return }
                model.searchedContext = ctx
                model.fingerprints = output.fingerprints
                results = output.results
                sourcesScanned = output.sourcesScanned
                errorText = output.issues.isEmpty ? nil : output.issues.joined(separator: "\n")
            } catch is CancellationError {
                // Stop button.
            } catch {
                guard !Task.isCancelled, model.searchGeneration == generation else { return }
                errorText = error.localizedDescription
            }
            guard model.searchGeneration == generation else { return }
            groups = Self.group(results)
        }
    }

    /// Pure search/source service. It owns filesystem traversal, source
    /// snapshots, matching, and cancellation; the SwiftUI view only presents
    /// requests and results.
    enum SearchEngine {

    /// Past ~10k matches the list becomes unwieldy and previews grow
    /// linearly in memory.
    nonisolated private static let maxResults = 10_000
    /// Above 5 MB almost never holds text the user wants to grep.
    nonisolated static let maxFileBytes = 5 * 1024 * 1024

    struct SearchOutput: Sendable {
        var results: [SearchResult]
        var sourcesScanned: Int
        var fingerprints: [ResultGroupKey: Data] = [:]
        var issues: [String] = []
    }

    nonisolated static func runFolderSearch(
        folder: URL,
        matcher: Matcher,
        extensions: Set<String>
    ) async throws -> SearchOutput {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let urls = try Self.collectFiles(in: folder, extensions: extensions)
        try Task.checkCancellation()

        var output = SearchOutput(results: [], sourcesScanned: 0)
        var skipped = 0
        for url in urls {
            try Task.checkCancellation()
            if output.results.count >= Self.maxResults { break }
            output.sourcesScanned += 1
            let source: (text: String, fingerprint: Data)
            do {
                source = try await Self.readText(at: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped += 1
                if output.issues.count < 20 { output.issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                continue
            }
            let text = source.text
            let groupKey = ResultGroupKey.url(url)
            let groupLabel = url.lastPathComponent
            let hits = matcher.matches(
                in: text,
                groupKey: groupKey,
                groupLabel: groupLabel,
                fileURL: url,
                limit: Self.maxResults - output.results.count
            )
            output.results.append(contentsOf: hits)
            if !hits.isEmpty { output.fingerprints[groupKey] = source.fingerprint }
        }
        if skipped > 0 { output.issues.insert("Skipped \(skipped) files. Details for up to 20 files follow.", at: 0) }
        if output.results.count == maxResults { output.issues.append("Results limited to 10,000 matches. Narrow the search to see more.") }
        return output
    }

    nonisolated static func runInMemorySearch(
        sources: [InMemorySource],
        matcher: Matcher
    ) throws -> SearchOutput {
        var output = SearchOutput(results: [], sourcesScanned: 0)
        for source in sources {
            try Task.checkCancellation()
            output.sourcesScanned += 1
            if output.results.count >= Self.maxResults { break }
            let hits = matcher.matches(
                in: source.text,
                groupKey: source.groupKey,
                groupLabel: source.groupLabel,
                fileURL: source.url,
                limit: Self.maxResults - output.results.count
            )
            output.results.append(contentsOf: hits)
            if !hits.isEmpty { output.fingerprints[source.groupKey] = fingerprint(Data(source.text.utf8)) }
        }
        if output.results.count == maxResults { output.issues.append("Results limited to 10,000 matches. Narrow the search to see more.") }
        return output
    }

    // MARK: - In-memory source collection

    struct InMemorySource: Sendable {
        let groupKey: ResultGroupKey
        let groupLabel: String
        let url: URL?
        let text: String
    }

    @MainActor
    static func tabsSources(in session: EditorSession?) -> [InMemorySource] {
        guard let session else { return [] }
        return session.tabs.enumerated().map { idx, tab in
            sourceFor(tab: tab, windowIndex: nil, tabIndex: idx)
        }
    }

    @MainActor
    fileprivate static func windowsSources() -> [InMemorySource] {
        let sessions = AppStateBus.shared.scenes.allOpenSessions
        var out: [InMemorySource] = []
        for (wi, session) in sessions.enumerated() {
            for (ti, tab) in session.tabs.enumerated() {
                out.append(sourceFor(tab: tab, windowIndex: wi, tabIndex: ti))
            }
        }
        return out
    }

    @MainActor
    private static func sourceFor(tab: TabModel, windowIndex: Int?, tabIndex: Int) -> InMemorySource {
        let url = tab.document.fileURL
        let key = ResultGroupKey.tab(tab.id)
        let title = url?.lastPathComponent ?? "Untitled"
        let label: String
        if let wi = windowIndex {
            label = "\(title)  (Window \(wi + 1), Tab \(tabIndex + 1))"
        } else {
            label = "\(title)  (Tab \(tabIndex + 1))"
        }
        let text = tab.state.textView?.text ?? tab.document.text
        return InMemorySource(groupKey: key, groupLabel: label, url: url, text: text)
    }

    // MARK: - File walking + reading

    nonisolated private static func collectFiles(in root: URL, extensions: Set<String>) throws -> [URL] {
        var collected: [URL] = []
        let manager = FileManager.default
        var enumerationError: (any Error)?
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: root]) }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if !extensions.isEmpty {
                let ext = url.pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
            }
            collected.append(url)
            if collected.count > 200_000 { throw SearchFailure.tooManyFiles }
        }
        if let enumerationError { throw enumerationError }
        return collected.sorted { $0.path < $1.path }
    }

    enum SearchFailure: LocalizedError {
        case tooManyFiles
        var errorDescription: String? { "This folder contains more than 200,000 matching files. Choose a smaller folder or narrow the extension filter." }
    }

    nonisolated private static func readText(at url: URL) async throws -> (text: String, fingerprint: Data) {
        try await CoordinatedFileAccess.perform(at: url) { sourceURL in
            let attributes = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
            guard let size = attributes.fileSize, size <= maxFileBytes else {
                throw PlainTextDocument.DocumentError.fileTooLarge(bytes: attributes.fileSize ?? 0)
            }
            let data = try Data(contentsOf: sourceURL)
            guard data.count <= maxFileBytes else { throw PlainTextDocument.DocumentError.fileTooLarge(bytes: data.count) }
            return (try PlainTextDocument.decodePayload(from: data).text, fingerprint(data))
        }
    }

    // MARK: - Matching

    struct Matcher: Sendable {
        let regex: NSRegularExpression?
        let literal: String?
        let caseSensitive: Bool

        func matches(
            in text: String,
            groupKey: ResultGroupKey,
            groupLabel: String,
            fileURL: URL?,
            limit: Int
        ) -> [SearchResult] {
            guard limit > 0 else { return [] }
            let ns = text as NSString
            var out: [SearchResult] = []
            // Reuse the previous line offset to avoid quadratic rescanning.
            var cursor = LineCursor()
            if let regex {
                let range = NSRange(location: 0, length: ns.length)
                regex.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
                    if Task.isCancelled { stop.pointee = true; return }
                    guard let match else { return }
                    out.append(makeResult(at: match.range, ns: ns, cursor: &cursor,
                                          groupKey: groupKey, groupLabel: groupLabel,
                                          url: fileURL))
                    if out.count >= limit { stop.pointee = true }
                }
            } else if let literal {
                var searchStart = 0
                while searchStart < ns.length, !Task.isCancelled {
                    let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
                    let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                    let found = ns.range(of: literal, options: opts, range: searchRange)
                    if found.location == NSNotFound { break }
                    out.append(makeResult(at: found, ns: ns, cursor: &cursor,
                                          groupKey: groupKey, groupLabel: groupLabel,
                                          url: fileURL))
                    if out.count >= limit { break }
                    searchStart = found.location + max(1, found.length)
                }
            }
            return out
        }

        /// Running (offset, line) position within one source.
        private struct LineCursor {
            var offset = 0
            var line = 1

            mutating func line(at location: Int, in ns: NSString) -> Int {
                while offset < location {
                    let ch = ns.character(at: offset)
                    if ch == 0x0A {
                        line += 1
                    } else if ch == 0x0D,
                              offset + 1 >= ns.length || ns.character(at: offset + 1) != 0x0A {
                        // Count bare CR; CRLF is counted at LF.
                        line += 1
                    }
                    offset += 1
                }
                return line
            }
        }

        private func makeResult(
            at range: NSRange,
            ns: NSString,
            cursor: inout LineCursor,
            groupKey: ResultGroupKey,
            groupLabel: String,
            url: URL?
        ) -> SearchResult {
            let line = cursor.line(at: range.location, in: ns)
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var preview = ns.substring(with: lineRange)
            if let last = preview.last, last == "\n" || last == "\r" { preview.removeLast() }
            preview = preview.trimmingCharacters(in: .whitespaces)
            return SearchResult(
                groupKey: groupKey,
                groupLabel: groupLabel,
                url: url,
                line: line,
                preview: preview,
                range: range
            )
        }
    }

    static func compileMatcher(for ctx: FindContext) throws -> Matcher {
        if FindCompile.useRegex(for: ctx) {
            return Matcher(
                regex: try FindCompile.regex(for: ctx),
                literal: nil,
                caseSensitive: ctx.caseSensitive
            )
        }
        return Matcher(regex: nil, literal: ctx.query, caseSensitive: ctx.caseSensitive)
    }

    }

    // MARK: - Grouping

    private static func group(_ results: [SearchResult]) -> [ResultGroup] {
        var byKey: [ResultGroupKey: ResultGroup] = [:]
        var order: [ResultGroupKey] = []
        for r in results {
            if byKey[r.groupKey] == nil {
                order.append(r.groupKey)
                byKey[r.groupKey] = ResultGroup(
                    key: r.groupKey,
                    label: r.groupLabel,
                    matches: []
                )
            }
            byKey[r.groupKey]?.matches.append(r)
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: - Models

    enum ResultGroupKey: Hashable, Sendable {
        case url(URL)
        case tab(UUID)
    }

    struct SearchResult: Identifiable, Hashable, Sendable {
        let id = UUID()
        let groupKey: ResultGroupKey
        let groupLabel: String
        let url: URL?
        let line: Int
        let preview: String
        let range: NSRange

        var isOpenTabResult: Bool {
            if case .tab = groupKey { return true }
            return false
        }
    }

    struct ResultGroup: Identifiable {
        var id: ResultGroupKey { key }
        let key: ResultGroupKey
        let label: String
        var matches: [SearchResult]

        var systemImage: String {
            switch key {
            case .url:  "doc.text"
            case .tab:  "rectangle.stack"
            }
        }
    }

    private var replacementContext: FindContext? {
        guard var context = model.searchedContext else { return nil }
        context.replacement = model.context.replacement
        return context == model.context ? context : nil
    }

    nonisolated static func fingerprint(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - Replace

    private enum ReplacementFailure: LocalizedError {
        case cannotEncode(String, String)
        case openFileHasUnsavedChanges(String)
        case sourceChanged(String)
        case matchNoLongerExists

        var errorDescription: String? {
            switch self {
            case .cannotEncode(let name, let encoding):
                "Couldn't save \(name): the replacement contains characters that \(encoding) cannot represent. No changes were written."
            case .openFileHasUnsavedChanges(let name):
                "Couldn't replace in \(name) from the folder scope because its open tab has unsaved changes. Use the Open Tabs scope or save it first."
            case .sourceChanged(let name):
                "Couldn't replace in \(name) because it changed on disk after the search. Run the search again."
            case .matchNoLongerExists:
                "A selected match changed after the search. Run the search again before replacing it."
            }
        }
    }

    struct ReplacementOutcome: Sendable {
        let count: Int
        let utf16Delta: Int
        var fingerprint: Data?

        static let unchanged = ReplacementOutcome(count: 0, utf16Delta: 0)
    }

    private func runReplacement(_ operation: @escaping @MainActor () async -> Void) {
        guard model.activity == .idle else { return }
        let generation = model.searchGeneration
        model.activity = .replacing
        searchTask = Task { @MainActor in
            await operation()
            guard model.searchGeneration == generation else { return }
            model.activity = .idle
            searchTask = nil
        }
    }

    /// All bulk modes consume the same displayed ranges and source versions.
    private func replaceMatches(_ matches: [SearchResult]) async {
        guard let ctx = replacementContext else { return }
        let generation = model.searchGeneration
        let targets = Self.group(matches)
        var sourcesChanged = 0
        var replaced = 0
        var failures: [String] = []
        for group in targets {
            if Task.isCancelled { break }
            let delta = queryOffsetDeltas[group.key, default: 0]
            let ranges = group.matches.map { NSRange(location: $0.range.location + delta, length: $0.range.length) }
            do {
                let outcome = try await replacementEngine.applyReplacement(in: group.key,
                    query: ctx.query, replacement: ctx.replacement, context: ctx,
                    expectedFingerprint: model.fingerprints[group.key], targetRanges: ranges)
                sourcesChanged += outcome.count > 0 ? 1 : 0
                replaced += outcome.count
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(group.label): \(error.localizedDescription)")
            }
        }
        guard model.searchGeneration == generation else { return }
        replaceSummary = "Replaced \(replaced) matches in \(sourcesChanged) sources."
        if !failures.isEmpty {
            errorText = failures.joined(separator: "\n")
        }
        queryCursor = nil
        results = []
        groups = []
        currentResultIndex = -1
    }

    private func beginQueryReplace() {
        guard !results.isEmpty, replacementContext != nil else { return }
        replaceSummary = nil
        queryOffsetDeltas = [:]
        queryCursor = 0
    }

    private func queryAdvance() {
        guard let cursor = queryCursor else { return }
        let next = cursor + 1
        if next < results.count {
            queryCursor = next
        } else {
            queryCursor = nil
            results = []
            groups = []
            currentResultIndex = -1
            replaceSummary = "Query mode finished."
        }
    }

    private func queryReplaceAndAdvance() async {
        guard let cursor = queryCursor, results.indices.contains(cursor), let ctx = replacementContext else { return }
        let generation = model.searchGeneration
        let target = results[cursor]
        do {
            let range = NSRange(location: target.range.location + queryOffsetDeltas[target.groupKey, default: 0], length: target.range.length)
            let outcome = try await replacementEngine.applyReplacement(in: target.groupKey,
                query: ctx.query, replacement: ctx.replacement, context: ctx,
                expectedFingerprint: model.fingerprints[target.groupKey], targetRanges: [range])
            guard model.searchGeneration == generation else { return }
            queryOffsetDeltas[target.groupKey, default: 0] += outcome.utf16Delta
            model.fingerprints[target.groupKey] = outcome.fingerprint
            queryAdvance()
        } catch {
            guard model.searchGeneration == generation else { return }
            errorText = error.localizedDescription
            queryCursor = nil
        }
    }

    private var replacementEngine: ReplacementEngine {
        ReplacementEngine(folder: folder)
    }

    @MainActor
    struct ReplacementEngine {
        let folder: URL?

        private struct TextReplacement: Sendable {
            let text: String
            let count: Int
            let utf16Delta: Int

            var outcome: ReplacementOutcome {
                ReplacementOutcome(count: count, utf16Delta: utf16Delta)
            }
        }

        private struct FileEdit: Sendable {
            let originalText: String
            let saved: PlainTextDocument.SavedSnapshot
            let outcome: ReplacementOutcome
        }

        func applyReplacement(
            in key: ResultGroupKey,
            query: String,
            replacement: String,
            context ctx: FindContext,
            expectedFingerprint: Data?,
            targetRanges: [NSRange]
        ) async throws -> ReplacementOutcome {
            guard let expectedFingerprint else { throw ReplacementFailure.matchNoLongerExists }
            try Task.checkCancellation()
            switch key {
            case .url(let url):
                return try await replaceFile(url, query: query, replacement: replacement,
                    context: ctx, expected: expectedFingerprint, ranges: targetRanges)
            case .tab(let id):
                guard let tab = Self.openTab(id: id) else { throw ReplacementFailure.matchNoLongerExists }
                let before = tab.state.textView?.text ?? tab.document.text
                guard fingerprint(Data(before.utf8)) == expectedFingerprint else {
                    throw ReplacementFailure.matchNoLongerExists
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try Self.makeReplacement(in: before, query: query, replacement: replacement,
                        context: ctx, limitToFirst: false, targetRanges: targetRanges)
                }
                let update = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let update else { return .unchanged }
                guard (tab.state.textView?.text ?? tab.document.text) == before,
                      Self.openTab(id: id) === tab else { throw ReplacementFailure.matchNoLongerExists }
                Self.apply(update.text, to: tab, replacing: before)
                tab.document.autoSave()
                return ReplacementOutcome(count: update.count, utf16Delta: update.utf16Delta,
                    fingerprint: fingerprint(Data(update.text.utf8)))
            }
        }

        private func replaceFile(
            _ url: URL, query: String, replacement: String, context: FindContext,
            expected: Data, ranges: [NSRange]
        ) async throws -> ReplacementOutcome {
            for tab in Self.openTabs(for: url) {
                let live = tab.state.textView?.text ?? tab.document.text
                guard !tab.document.isDirty, live == tab.state.savedBaselineText else {
                    throw ReplacementFailure.openFileHasUnsavedChanges(url.lastPathComponent)
                }
            }
            let folderScoped = folder?.startAccessingSecurityScopedResource() == true
            defer { if folderScoped, let folder { folder.stopAccessingSecurityScopedResource() } }
            let edit: FileEdit? = try await CoordinatedFileAccess.perform(at: url, writing: true) { destination in
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= SearchEngine.maxFileBytes else { throw PlainTextDocument.DocumentError.fileTooLarge(bytes: size) }
                let data = try Data(contentsOf: destination)
                guard data.count <= SearchEngine.maxFileBytes else { throw PlainTextDocument.DocumentError.fileTooLarge(bytes: data.count) }
                guard fingerprint(data) == expected else {
                    throw ReplacementFailure.sourceChanged(url.lastPathComponent)
                }
                let payload = try PlainTextDocument.decodePayload(from: data)
                guard let update = try Self.makeReplacement(in: payload.text, query: query,
                    replacement: replacement, context: context, limitToFirst: false, targetRanges: ranges)
                else { return nil }
                guard let encoded = Self.encodeReplacement(update.text,
                    encoding: payload.encoding.encoding, originalData: data) else {
                    throw ReplacementFailure.cannotEncode(url.lastPathComponent, payload.encoding.localizedName)
                }
                try encoded.write(to: destination, options: .atomic)
                let date = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let saved = PlainTextDocument.SavedSnapshot(url: destination, inputText: payload.text,
                    text: update.text, data: encoded, encoding: payload.encoding,
                    lineEnding: PlainTextDocument.detectLineEnding(in: update.text) ?? .lf,
                    modificationDate: date)
                return FileEdit(originalText: payload.text, saved: saved,
                    outcome: ReplacementOutcome(count: update.count, utf16Delta: update.utf16Delta,
                        fingerprint: fingerprint(encoded)))
            }
            guard let edit else { return .unchanged }
            for tab in Self.openTabs(for: url) {
                let live = tab.state.textView?.text ?? tab.document.text
                // An edit made while the write waited belongs to that tab.
                // Its old disk baseline will require conflict resolution on Save.
                guard !tab.document.isDirty, live == edit.originalText else { continue }
                Self.apply(edit.saved.text, to: tab, replacing: live)
                tab.document.finishExternalSave(to: edit.saved.url, savedText: edit.saved.text,
                    savedData: edit.saved.data, currentText: edit.saved.text,
                    modificationDate: edit.saved.modificationDate)
                tab.state.savedBaselineText = edit.saved.text
            }
            return edit.outcome
        }

        private static func apply(_ text: String, to tab: TabModel, replacing oldText: String) {
            if let textView = tab.state.textView {
                textView.replaceText(in: BatchReplaceSet(replacements: [
                    .init(range: NSRange(location: 0, length: oldText.utf16.count), text: text)
                ]))
            } else {
                tab.document.isDirty = true
                tab.document.bufferRevision &+= 1
            }
            tab.document.text = text
            tab.state.text = text
        }

        nonisolated private static func makeReplacement(
            in text: String,
            query: String,
            replacement: String,
            context ctx: FindContext,
            limitToFirst: Bool,
            targetRanges: [NSRange]?
        ) throws -> TextReplacement? {
            let (replaced, count) = try replaceInString(
                text,
                query: query,
                replacement: replacement,
                context: ctx,
                limitToFirst: limitToFirst,
                targetRanges: targetRanges
            )
            guard count > 0 else {
                if targetRanges != nil { throw ReplacementFailure.matchNoLongerExists }
                return nil
            }
            if let targetRanges, count != targetRanges.count {
                throw ReplacementFailure.matchNoLongerExists
            }
            return TextReplacement(
                text: replaced,
                count: count,
                utf16Delta: (replaced as NSString).length - (text as NSString).length
            )
        }

        private static func openTab(id: UUID) -> TabModel? {
            for session in AppStateBus.shared.scenes.allOpenSessions {
                if let tab = session.tabs.first(where: { $0.id == id }) {
                    return tab
                }
            }
            return nil
        }

        private static func openTabs(for url: URL) -> [TabModel] {
            let target = url.standardizedFileURL
            return AppStateBus.shared.scenes.allOpenSessions.flatMap(\.tabs).filter {
                $0.document.fileURL?.standardizedFileURL == target
            }
        }

        nonisolated static func encodeReplacement(
            _ text: String,
            encoding detectedEncoding: String.Encoding,
            originalData: Data
        ) -> Data? {
            let boms: [(bytes: [UInt8], encoding: String.Encoding)] = [
                ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
                ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
                ([0xEF, 0xBB, 0xBF], .utf8),
                ([0xFE, 0xFF], .utf16BigEndian),
                ([0xFF, 0xFE], .utf16LittleEndian)
            ]
            let originalBOM = boms.first { originalData.starts(with: $0.bytes) }
            let encoding = originalBOM?.encoding ?? detectedEncoding
            guard var encoded = text.data(using: encoding, allowLossyConversion: false) else {
                return nil
            }
            if let originalBOM, !encoded.starts(with: originalBOM.bytes) {
                var prefixed = Data(originalBOM.bytes)
                prefixed.append(encoded)
                encoded = prefixed
            }
            return encoded
        }

        nonisolated static func replaceInString(
            _ text: String,
            query: String,
            replacement: String,
            context ctx: FindContext,
            limitToFirst: Bool,
            targetRanges: [NSRange]? = nil
        ) throws -> (String, Int) {
            if let targetRanges {
                return try replaceTargetRanges(
                    targetRanges,
                    in: text,
                    query: query,
                    replacement: replacement,
                    context: ctx
                )
            }
            if FindCompile.useRegex(for: ctx) {
                return try replaceRegex(
                    in: text,
                    replacement: replacement,
                    context: ctx,
                    limitToFirst: limitToFirst
                )
            }
            return replaceLiteral(
                in: text,
                query: query,
                replacement: replacement,
                caseSensitive: ctx.caseSensitive,
                limitToFirst: limitToFirst
            )
        }

        nonisolated private static func replaceTargetRanges(
            _ ranges: [NSRange],
            in text: String,
            query: String,
            replacement: String,
            context: FindContext
        ) throws -> (String, Int) {
            let source = text as NSString
            let requested = Set(ranges)
            var edits: [(NSRange, String)] = []
            if FindCompile.useRegex(for: context) {
                let regex = try FindCompile.regex(for: context)
                regex.enumerateMatches(in: text, options: [.reportProgress],
                    range: NSRange(location: 0, length: source.length)) { match, _, stop in
                    if Task.isCancelled { stop.pointee = true; return }
                    guard let match, requested.contains(match.range) else { return }
                    edits.append((match.range, regex.replacementString(for: match, in: text,
                        offset: 0, template: replacement)))
                }
            } else {
                let options: NSString.CompareOptions = context.caseSensitive ? [] : [.caseInsensitive]
                for range in requested {
                    try Task.checkCancellation()
                    guard range.location >= 0, range.length >= 0,
                          range.location <= source.length, range.length <= source.length - range.location,
                          source.range(of: query, options: options, range: range) == range else { continue }
                    edits.append((range, replacement))
                }
            }
            try Task.checkCancellation()
            let output = NSMutableString(string: text)
            for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                output.replaceCharacters(in: range, with: replacement)
            }
            return (output as String, edits.count)
        }

        nonisolated private static func replaceRegex(
            in text: String,
            replacement: String,
            context: FindContext,
            limitToFirst: Bool
        ) throws -> (String, Int) {
            let source = text as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let regex = try FindCompile.regex(for: context)
            guard limitToFirst else {
                let mutable = NSMutableString(string: text)
                let count = regex.replaceMatches(
                    in: mutable,
                    options: [],
                    range: fullRange,
                    withTemplate: replacement
                )
                return (mutable as String, count)
            }
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
                return (text, 0)
            }
            let substituted = regex.replacementString(
                for: match,
                in: text,
                offset: 0,
                template: replacement
            )
            let result = source.substring(to: match.range.location)
                + substituted
                + source.substring(from: NSMaxRange(match.range))
            return (result, 1)
        }

        nonisolated private static func replaceLiteral(
            in text: String,
            query: String,
            replacement: String,
            caseSensitive: Bool,
            limitToFirst: Bool
        ) -> (String, Int) {
            let source = text as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            let mutable = NSMutableString(string: text)
            guard limitToFirst else {
                let count = mutable.replaceOccurrences(
                    of: query,
                    with: replacement,
                    options: options,
                    range: fullRange
                )
                return (mutable as String, count)
            }
            let range = source.range(of: query, options: options, range: fullRange)
            guard range.location != NSNotFound else { return (text, 0) }
            mutable.replaceCharacters(in: range, with: replacement)
            return (mutable as String, 1)
        }


    }

    nonisolated static func encodeReplacement(
        _ text: String,
        encoding: String.Encoding,
        originalData: Data
    ) -> Data? {
        ReplacementEngine.encodeReplacement(
            text,
            encoding: encoding,
            originalData: originalData
        )
    }

    nonisolated static func replaceInString(
        _ text: String,
        query: String,
        replacement: String,
        context: FindContext,
        limitToFirst: Bool,
        targetRanges: [NSRange]? = nil
    ) throws -> (String, Int) {
        try ReplacementEngine.replaceInString(
            text,
            query: query,
            replacement: replacement,
            context: context,
            limitToFirst: limitToFirst,
            targetRanges: targetRanges
        )
    }
}
