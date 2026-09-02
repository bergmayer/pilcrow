import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Searches a folder, the current window, or all open windows.
struct MultiFileSearchSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable private var bus = AppStateBus.shared

    enum Scope: String, CaseIterable, Identifiable {
        case folder
        case tabs
        case windows
        var id: String { rawValue }

        var label: String {
            switch self {
            case .folder:  return "Folder…"
            case .tabs:    return DeviceIdiom.isPhone ? "Open Tabs" : "Tabs in Foreground Window"
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

        var scope: Scope = .folder
        var folder: URL?
        var pickingFolder = false
        var extensionFilter = "swift,m,h,c,cpp,js,ts,tsx,py,rb,go,rs,java,kt,html,css,xml,json,yaml,yml,md,txt"
        var searchTask: Task<Void, Never>?
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

    @State private var model = Model()

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
                if case let .success(url) = result {
                    folder = url
                }
            }
            .onAppear {
                if !seenFirstAppear {
                    seenFirstAppear = true
                    // Do not restore this utility window after relaunch.
                    if !AppStateBus.shared.scenes.consumeOpen(.multiFileSearch) {
                        AppStateBus.shared.scenes.openWindow?(.editor)
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
                Button("Replace All", role: .destructive) { performReplaceAll() }
            } message: {
                Text("This rewrites \(results.count) match\(results.count == 1 ? "" : "es") and saves every changed file. Cannot be undone from this sheet — use each editor's undo if you need to back out.")
            }
            .alert(
                queryAlertTitle,
                isPresented: queryAlertBinding,
                presenting: currentQueryResult
            ) { _ in
                Button("Skip") { queryAdvance() }
                Button("Replace") { queryReplaceAndAdvance() }
                Button("Replace All Remaining", role: .destructive) { queryReplaceAllRemaining() }
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
            .onChange(of: scope) { _, _ in
                // Clear stale progress so the previous scope's
                // counts don't leak.
                results = []
                groups = []
                sourcesScanned = 0
                currentResultIndex = -1
                errorText = nil
            }
        }
    }

    @ViewBuilder
    private var querySection: some View {
        Section("Query") {
            TextField(
                bus.find.context.useRegex ? "Regular expression" : "Find",
                text: $bus.find.context.query
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(bus.find.context.useRegex ? .body.monospaced() : .body)

            TextField("Replace with (optional)", text: $bus.find.context.replacement)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(bus.find.context.useRegex ? .body.monospaced() : .body)

            Toggle("Regular Expression", isOn: $bus.find.context.useRegex)
            Toggle("Case Sensitive",    isOn: $bus.find.context.caseSensitive)
            Toggle("Whole Word",        isOn: $bus.find.context.wholeWord)
                .disabled(bus.find.context.useRegex)
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
                    .disabled(bus.find.context.query.isEmpty)
                    Button(role: .destructive) {
                        pendingReplaceAllConfirm = true
                    } label: {
                        Label("Replace All", systemImage: "arrow.2.squarepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(bus.find.context.query.isEmpty)
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
        dismiss()
    }

    private var canStartSearch: Bool {
        guard !bus.find.context.query.isEmpty else { return false }
        switch scope {
        case .folder:  return folder != nil
        case .tabs:    return bus.scenes.currentSession != nil
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
        bus.pending.goToLine = match.line
        bus.pending.newWindow = url
        bus.scenes.openWindow?(.editor)
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

    private func startSearch() {
        errorText = nil
        results = []
        groups = []
        sourcesScanned = 0
        currentResultIndex = -1
        isSearching = true

        let ctx = bus.find.context
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
        case .tabs:    inMemorySources = SearchEngine.tabsSources()
        case .windows: inMemorySources = SearchEngine.windowsSources()
        }

        searchTask = Task { @MainActor in
            defer { isSearching = false }
            do {
                let matcher = try SearchEngine.compileMatcher(for: ctx)
                let worker: Task<SearchEngine.SearchOutput, any Error>
                if scopeCopy == .folder, let folderCopy {
                    worker = Task.detached(priority: .userInitiated) {
                        try SearchEngine.runFolderSearch(
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
                results = output.results
                sourcesScanned = output.sourcesScanned
            } catch is CancellationError {
                // Stop button.
            } catch {
                errorText = error.localizedDescription
            }
            groups = Self.group(results)
        }
    }

    /// Pure search/source service. It owns filesystem traversal, source
    /// snapshots, matching, and cancellation; the SwiftUI view only presents
    /// requests and results.
    fileprivate enum SearchEngine {

    /// Past ~10k matches the list becomes unwieldy and previews grow
    /// linearly in memory.
    nonisolated private static let maxResults = 10_000
    /// Above 5 MB almost never holds text the user wants to grep.
    nonisolated private static let maxFileBytes = 5 * 1024 * 1024

    fileprivate struct SearchOutput: Sendable {
        var results: [SearchResult]
        var sourcesScanned: Int
    }

    nonisolated fileprivate static func runFolderSearch(
        folder: URL,
        matcher: Matcher,
        extensions: Set<String>
    ) throws -> SearchOutput {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let urls = Self.collectFiles(in: folder, extensions: extensions)
        try Task.checkCancellation()

        var output = SearchOutput(results: [], sourcesScanned: 0)
        for url in urls {
            try Task.checkCancellation()
            output.sourcesScanned += 1
            if output.results.count >= Self.maxResults { break }
            guard let text = Self.readText(at: url) else { continue }
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
        }
        return output
    }

    nonisolated fileprivate static func runInMemorySearch(
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
        }
        return output
    }

    // MARK: - In-memory source collection

    fileprivate struct InMemorySource: Sendable {
        let groupKey: ResultGroupKey
        let groupLabel: String
        let url: URL?
        let text: String
    }

    @MainActor
    fileprivate static func tabsSources() -> [InMemorySource] {
        guard let session = AppStateBus.shared.scenes.currentSession else { return [] }
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

    nonisolated private static func collectFiles(in root: URL, extensions: Set<String>) -> [URL] {
        var collected: [URL] = []
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if !extensions.isEmpty {
                let ext = url.pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
            }
            collected.append(url)
            if collected.count >= 200_000 { break }
        }
        return collected
    }

    nonisolated private static func readText(at url: URL) -> String? {
        guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = attrs.fileSize, size <= maxFileBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PlainTextDocument.decodePayload(from: data).text
    }

    // MARK: - Matching

    fileprivate struct Matcher: @unchecked Sendable {
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
                regex.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
                    guard let match else { return }
                    out.append(makeResult(at: match.range, ns: ns, cursor: &cursor,
                                          groupKey: groupKey, groupLabel: groupLabel,
                                          url: fileURL))
                    if out.count >= limit { stop.pointee = true }
                }
            } else if let literal {
                var searchStart = 0
                while searchStart < ns.length {
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

    fileprivate static func compileMatcher(for ctx: FindContext) throws -> Matcher {
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

    fileprivate struct ReplacementOutcome {
        let count: Int
        let utf16Delta: Int

        static let unchanged = ReplacementOutcome(count: 0, utf16Delta: 0)
    }

    /// File-backed sources rewrite via atomic Data.write; open tabs flow
    /// the new text through the live engine buffer then sync the document.
    private func performReplaceAll() {
        let ctx = bus.find.context
        guard !ctx.query.isEmpty else { return }
        model.activity = .replacing
        defer { model.activity = .idle }
        var filesChanged = 0
        var totalReplacements = 0
        var errors: [String] = []
        for key in Set(results.map { $0.groupKey }) {
            do {
                let outcome = try replacementEngine.applyReplacement(
                    in: key,
                    query: ctx.query,
                    replacement: ctx.replacement,
                    context: ctx
                )
                if outcome.count > 0 {
                    filesChanged += 1
                    totalReplacements += outcome.count
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        replaceSummary = "Replaced \(totalReplacements) match\(totalReplacements == 1 ? "" : "es") in \(filesChanged) file\(filesChanged == 1 ? "" : "s")."
        if !errors.isEmpty {
            errorText = errors.prefix(3).joined(separator: " — ")
        }
        // Replacements invalidate the current result offsets.
        results.removeAll()
        groups.removeAll()
        currentResultIndex = -1
    }

    private func beginQueryReplace() {
        guard !results.isEmpty else { return }
        replaceSummary = nil
        queryOffsetDeltas = [:]
        queryCursor = 0
    }

    private func queryAdvance() {
        guard let cursor = queryCursor else { return }
        let next = cursor + 1
        if next >= results.count {
            queryCursor = nil
            replaceSummary = "Query mode finished."
        } else {
            queryCursor = next
        }
    }

    private func queryReplaceAndAdvance() {
        guard let cursor = queryCursor, results.indices.contains(cursor) else { return }
        let target = results[cursor]
        let ctx = bus.find.context
        do {
            let delta = queryOffsetDeltas[target.groupKey, default: 0]
            let adjustedRange = NSRange(
                location: target.range.location + delta,
                length: target.range.length
            )
            let outcome = try replacementEngine.applyReplacement(
                in: target.groupKey,
                query: ctx.query,
                replacement: ctx.replacement,
                context: ctx,
                targetRanges: [adjustedRange]
            )
            queryOffsetDeltas[target.groupKey, default: 0] += outcome.utf16Delta
        } catch {
            errorText = error.localizedDescription
        }
        queryAdvance()
    }

    private func queryReplaceAllRemaining() {
        guard let cursor = queryCursor else { return }
        model.activity = .replacing
        defer { model.activity = .idle }
        let ctx = bus.find.context
        var changedSources = 0
        var replaceCount = 0
        var targetsByKey: [ResultGroupKey: [NSRange]] = [:]
        for result in results.dropFirst(cursor) {
            let delta = queryOffsetDeltas[result.groupKey, default: 0]
            targetsByKey[result.groupKey, default: []].append(
                NSRange(location: result.range.location + delta, length: result.range.length)
            )
        }
        for (key, ranges) in targetsByKey {
            do {
                let outcome = try replacementEngine.applyReplacement(
                    in: key,
                    query: ctx.query,
                    replacement: ctx.replacement,
                    context: ctx,
                    targetRanges: ranges
                )
                if outcome.count > 0 {
                    changedSources += 1
                    replaceCount += outcome.count
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
        replaceSummary = "Replaced \(replaceCount) remaining match\(replaceCount == 1 ? "" : "es") in \(changedSources) source\(changedSources == 1 ? "" : "s")."
        queryCursor = nil
        results.removeAll()
        groups.removeAll()
        currentResultIndex = -1
    }

    private var replacementEngine: ReplacementEngine {
        ReplacementEngine(scope: scope, folder: folder)
    }

    @MainActor
    fileprivate struct ReplacementEngine {
        let scope: Scope
        let folder: URL?

        private struct TextReplacement {
            let text: String
            let count: Int
            let utf16Delta: Int

            var outcome: ReplacementOutcome {
                ReplacementOutcome(count: count, utf16Delta: utf16Delta)
            }
        }

        fileprivate func applyReplacement(
            in key: ResultGroupKey,
            query: String,
            replacement: String,
            context ctx: FindContext,
            limitToFirst: Bool = false,
            targetRanges: [NSRange]? = nil
        ) throws -> ReplacementOutcome {
            switch key {
            case .url(let url):
                return try applyReplacementToFile(
                    url: url,
                    query: query,
                    replacement: replacement,
                    context: ctx,
                    limitToFirst: limitToFirst,
                    targetRanges: targetRanges
                )
            case .tab(let id):
                return try applyReplacementToTab(
                    tabID: id,
                    query: query,
                    replacement: replacement,
                    context: ctx,
                    limitToFirst: limitToFirst,
                    targetRanges: targetRanges
                )
            }
        }

        private func applyReplacementToFile(
            url: URL,
            query: String,
            replacement: String,
            context ctx: FindContext,
            limitToFirst: Bool,
            targetRanges: [NSRange]?
        ) throws -> ReplacementOutcome {
            if let openTab = Self.openTab(for: url) {
                let liveText = openTab.state.textView?.text ?? openTab.document.text
                let hasUnsavedChanges = openTab.document.isDirty
                    || liveText != openTab.state.savedBaselineText
                guard !hasUnsavedChanges else {
                    throw ReplacementFailure.openFileHasUnsavedChanges(url.lastPathComponent)
                }
                return try applyReplacementToTab(
                    tabID: openTab.id,
                    query: query,
                    replacement: replacement,
                    context: ctx,
                    limitToFirst: limitToFirst,
                    targetRanges: targetRanges,
                    saveAfterReplacing: true
                )
            }
            return try applyReplacementToClosedFile(
                url: url,
                query: query,
                replacement: replacement,
                context: ctx,
                limitToFirst: limitToFirst,
                targetRanges: targetRanges
            )
        }

        private func applyReplacementToClosedFile(
            url: URL,
            query: String,
            replacement: String,
            context ctx: FindContext,
            limitToFirst: Bool,
            targetRanges: [NSRange]?
        ) throws -> ReplacementOutcome {
            let folderScoped = scope == .folder
                && folder?.startAccessingSecurityScopedResource() == true
            defer { if folderScoped, let folder { folder.stopAccessingSecurityScopedResource() } }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let payload = try PlainTextDocument.decodePayload(from: data)
            guard let update = try Self.makeReplacement(
                in: payload.text,
                query: query,
                replacement: replacement,
                context: ctx,
                limitToFirst: limitToFirst,
                targetRanges: targetRanges
            ) else { return .unchanged }
            guard let outData = Self.encodeReplacement(
                update.text,
                encoding: payload.encoding.encoding,
                originalData: data
            ) else {
                throw ReplacementFailure.cannotEncode(
                    url.lastPathComponent,
                    payload.encoding.localizedName
                )
            }
            try outData.write(to: url, options: .atomic)
            return update.outcome
        }

        private func applyReplacementToTab(
            tabID: UUID,
            query: String,
            replacement: String,
            context ctx: FindContext,
            limitToFirst: Bool,
            targetRanges: [NSRange]?,
            saveAfterReplacing: Bool = false
        ) throws -> ReplacementOutcome {
            guard let tab = Self.openTab(id: tabID) else { return .unchanged }
            try Self.validateSource(of: tab, beforeSaving: saveAfterReplacing)

            let liveText = tab.state.textView?.text ?? tab.document.text
            guard let update = try Self.makeReplacement(
                in: liveText,
                query: query,
                replacement: replacement,
                context: ctx,
                limitToFirst: limitToFirst,
                targetRanges: targetRanges
            ) else { return .unchanged }

            Self.apply(update.text, to: tab, replacing: liveText)
            if saveAfterReplacing, tab.document.fileURL != nil {
                try Self.save(tab, text: update.text)
            } else {
                tab.document.autoSave()
            }
            return update.outcome
        }

        private static func validateSource(of tab: TabModel, beforeSaving: Bool) throws {
            guard beforeSaving, let url = tab.document.fileURL else { return }
            guard let loadedMtime = tab.document.sourceMtimeAtLoad,
                  let loadedSize = tab.document.sourceSizeAtLoad,
                  let current = PlainTextDocument.diskAttrs(of: url),
                  current.mtime == loadedMtime,
                  current.size == loadedSize
            else {
                throw ReplacementFailure.sourceChanged(url.lastPathComponent)
            }
        }

        private static func apply(_ text: String, to tab: TabModel, replacing oldText: String) {
            if let textView = tab.state.textView {
                textView.replace(
                    NSRange(location: 0, length: (oldText as NSString).length),
                    withText: text
                )
            }
            tab.document.text = text
            tab.document.isDirty = true
            tab.document.bufferRevision &+= 1
            tab.state.text = text
        }

        private static func save(_ tab: TabModel, text: String) throws {
            let prepared = tab.document.preparedTextForSaving(text)
            if prepared != text, let textView = tab.state.textView {
                textView.replace(
                    NSRange(location: 0, length: (text as NSString).length),
                    withText: prepared
                )
            }
            tab.document.text = prepared
            tab.state.text = prepared
            try tab.document.save()
            tab.state.savedBaselineText = prepared
            tab.state.fileEncoding = tab.document.fileEncoding
            tab.state.lineEnding = tab.document.lineEnding
        }

        private static func makeReplacement(
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

        private static func openTab(for url: URL) -> TabModel? {
            let target = url.standardizedFileURL
            for session in AppStateBus.shared.scenes.allOpenSessions {
                if let tab = session.tabs.first(where: {
                    $0.document.fileURL?.standardizedFileURL == target
                }) {
                    return tab
                }
            }
            return nil
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
            var current = text
            var count = 0
            for range in ranges.sorted(by: { $0.location > $1.location }) {
                let result = try replaceExactMatch(
                    in: current,
                    range: range,
                    query: query,
                    replacement: replacement,
                    context: context
                )
                guard result.didReplace else { continue }
                current = result.text
                count += 1
            }
            return (current, count)
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

        nonisolated private static func replaceExactMatch(
            in text: String,
            range target: NSRange,
            query: String,
            replacement: String,
            context ctx: FindContext
        ) throws -> (text: String, didReplace: Bool) {
            let nsText = text as NSString
            guard target.location >= 0,
                  target.length >= 0,
                  NSMaxRange(target) <= nsText.length
            else { return (text, false) }

            if FindCompile.useRegex(for: ctx) {
                return try replaceExactRegexMatch(
                    in: text,
                    target: target,
                    replacement: replacement,
                    context: ctx
                )
            }
            let options: NSString.CompareOptions = ctx.caseSensitive ? [] : [.caseInsensitive]
            let found = nsText.range(of: query, options: options, range: target)
            guard found == target else { return (text, false) }
            let mutable = NSMutableString(string: text)
            mutable.replaceCharacters(in: target, with: replacement)
            return (mutable as String, true)
        }

        nonisolated private static func replaceExactRegexMatch(
            in text: String,
            target: NSRange,
            replacement: String,
            context: FindContext
        ) throws -> (text: String, didReplace: Bool) {
            let regex = try FindCompile.regex(for: context)
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            var exact: NSTextCheckingResult?
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, stop in
                guard let match else { return }
                if match.range == target {
                    exact = match
                    stop.pointee = true
                } else if match.range.location > target.location {
                    stop.pointee = true
                }
            }
            guard let exact else { return (text, false) }
            let substituted = regex.replacementString(
                for: exact,
                in: text,
                offset: 0,
                template: replacement
            )
            let mutable = NSMutableString(string: text)
            mutable.replaceCharacters(in: exact.range, with: substituted)
            return (mutable as String, true)
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
