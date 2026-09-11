import SwiftUI
import UIKit
import FileEncoding

/// One tab's restorable state. Bookmark, not raw URL — File Provider
/// locations (Nextcloud, iCloud) need explicit scope to re-open after
/// relaunch.
struct TabSnapshot: Codable, Sendable {
    var fileBookmark: Data?
    /// Filename within the recovery directory; relative because the
    /// Application Support base path is container-specific.
    var draftFilename: String?
    var isPinned: Bool
    /// Human-readable tab title captured at close time. Optional keeps
    /// records written by older builds decodable.
    var displayName: String? = nil
    var editorLayout: EditorLayoutSnapshot? = nil
    /// The periodic checkpoint can be newer than the last lifecycle snapshot.
    var scratchFilename: String? = nil

    var recoveryFilename: String? { draftFilename ?? scratchFilename }
}

/// One window's restorable tab list. `launchID` tags every record
/// saved during a single app run so the next launch can identify
/// "windows open at last quit" — records from earlier launches still
/// sit in the store as dormant history until the cap evicts them.
/// `persistentIdentifier` is iPadOS's `UISceneSession.persistentIdentifier`
/// captured at scene register time — the AppDelegate's
/// `configurationForConnecting` uses it to correlate a cold-launch
/// scene back to its record. No record == iPadOS ghost (user swiped
/// or explicitly closed); a matching record means "involuntary kill,
/// the user wants this back."
struct SessionRecord: Codable, Sendable {
    let sceneUUID: String
    var tabs: [TabSnapshot]
    var activeIndex: Int
    var lastModified: Date
    var launchID: String
    var persistentIdentifier: String?
}

/// Unsaved work from an older app version or a scene discarded without
/// an explicit save/discard decision. Unlike an open `SessionRecord`, this
/// record is exposed only when automatic restoration leaves work behind.
/// Its filenames keep the local recovery payloads protected.
struct ClosedWindowRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var tabs: [TabSnapshot]
    var activeIndex: Int
    var closedAt: Date
    var sourcePersistentIdentifier: String?
    /// Explicit in-app close also creates per-tab history entries. Remember
    /// their ids so restoring/discarding the whole window doesn't leave
    /// duplicate "recently closed tab" entries behind.
    var closedTabRecordIDs: [UUID]

    init(
        id: UUID = UUID(),
        sessionRecord: SessionRecord,
        closedAt: Date = Date(),
        closedTabRecordIDs: [UUID] = []
    ) {
        self.id = id
        self.tabs = sessionRecord.tabs
        self.activeIndex = sessionRecord.activeIndex
        self.closedAt = closedAt
        self.sourcePersistentIdentifier = sessionRecord.persistentIdentifier
        self.closedTabRecordIDs = closedTabRecordIDs
    }

    var dirtyTabCount: Int {
        tabs.reduce(into: 0) { count, tab in
            if tab.recoveryFilename != nil { count += 1 }
        }
    }

    var tabCount: Int { tabs.count }

    var draftFilenames: Set<String> {
        Set(tabs.compactMap(\.recoveryFilename))
    }

    func sessionRecord(
        sceneUUID: String,
        launchID: String,
        persistentIdentifier: String?
    ) -> SessionRecord {
        SessionRecord(
            sceneUUID: sceneUUID,
            tabs: tabs,
            activeIndex: activeIndex,
            lastModified: Date(),
            launchID: launchID,
            persistentIdentifier: persistentIdentifier
        )
    }
}

/// One individually-presented recovery row. A single-tab closed window owns
/// its draft row so Restore and Discard can update the window metadata and
/// recovery bytes atomically without showing two representations.
struct RecoverableDraftItem: Identifiable, Sendable {
    let draft: DraftRecord
    let closedWindow: ClosedWindowRecord?

    var id: UUID { draft.id }
}

/// Normalizes raw draft files and closed-window manifests into one recovery
/// presentation:
///
/// - multi-tab windows remain grouped and consume their member draft rows;
/// - single-tab windows become ordinary draft rows with an owner;
/// - orphan drafts remain ordinary draft rows;
/// - incomplete, duplicate, or already-open window manifests are reported
///   for metadata-only pruning, leaving any surviving draft bytes visible.
struct RecoverableWorkCatalog: Sendable {
    let windows: [ClosedWindowRecord]
    let drafts: [RecoverableDraftItem]
    let invalidWindowIDs: Set<UUID>
    let draftsByFilename: [String: DraftRecord]

    init(
        drafts: [DraftRecord],
        closedWindows: [ClosedWindowRecord],
        excludedDraftFilenames: Set<String> = []
    ) {
        var lookup: [String: DraftRecord] = [:]
        var orderedUniqueDrafts: [DraftRecord] = []
        for draft in drafts {
            let filename = draft.recoveryFilename
            guard lookup[filename] == nil else { continue }
            lookup[filename] = draft
            orderedUniqueDrafts.append(draft)
        }

        var groupedWindows: [ClosedWindowRecord] = []
        var groupedFilenames = Set<String>()
        var ownersByFilename: [String: ClosedWindowRecord] = [:]
        var claimedFilenames = Set<String>()
        var invalidIDs = Set<UUID>()

        for window in closedWindows {
            let filenames = window.draftFilenames
            let hasEveryDraft = !filenames.isEmpty
                && filenames.allSatisfy { lookup[$0] != nil }
            let conflictsWithVisibleWork = !filenames.isDisjoint(
                with: excludedDraftFilenames
            )
            let duplicatesAnotherWindow = !filenames.isDisjoint(
                with: claimedFilenames
            )
            guard hasEveryDraft,
                  !conflictsWithVisibleWork,
                  !duplicatesAnotherWindow
            else {
                invalidIDs.insert(window.id)
                continue
            }

            if window.tabCount > 1 {
                groupedWindows.append(window)
                groupedFilenames.formUnion(filenames)
            } else if window.tabCount == 1, let filename = filenames.first {
                ownersByFilename[filename] = window
            } else {
                invalidIDs.insert(window.id)
                continue
            }
            claimedFilenames.formUnion(filenames)
        }

        var visibleDrafts: [RecoverableDraftItem] = []
        for draft in orderedUniqueDrafts {
            let filename = draft.recoveryFilename
            guard !groupedFilenames.contains(filename),
                  !excludedDraftFilenames.contains(filename)
            else { continue }
            visibleDrafts.append(RecoverableDraftItem(
                draft: draft,
                closedWindow: ownersByFilename[filename]
            ))
        }

        self.windows = groupedWindows
        self.drafts = visibleDrafts
        self.invalidWindowIDs = invalidIDs
        self.draftsByFilename = lookup
    }

    var isEmpty: Bool {
        windows.isEmpty && drafts.isEmpty
    }
}

/// Durable, device-local metadata for windows closed with unsaved work. The
/// actual buffer bytes stay in `DraftsStore`; retaining their filenames here
/// protects them from ordinary orphan cleanup until Restore or Discard.
@MainActor
@Observable
final class ClosedWindowsStore {

    static let shared = ClosedWindowsStore()

    private let defaults: UserDefaults
    private let discardDraft: (String) -> Void
    private let removeClosedTab: (UUID) -> Void

    private(set) var records: [ClosedWindowRecord]

    init(
        defaults: UserDefaults = .standard,
        discardDraft: @escaping (String) -> Void = {
            DraftsStore.shared.discardIfUnreferenced(named: $0)
        },
        removeClosedTab: @escaping (UUID) -> Void = {
            ClosedTabsStore.shared.remove($0)
        }
    ) {
        self.defaults = defaults
        self.discardDraft = discardDraft
        self.removeClosedTab = removeClosedTab
        self.records = Self.load(from: defaults)
            .sorted { $0.closedAt > $1.closedAt }
    }

    func record(id: UUID) -> ClosedWindowRecord? {
        records.first { $0.id == id }
    }

    /// Clean windows don't need a recovery surface. A repeated system
    /// callback for the same persistent scene returns the existing archive
    /// instead of adding a duplicate row.
    @discardableResult
    func archive(
        _ sessionRecord: SessionRecord,
        closedTabRecordIDs: [UUID] = []
    ) -> ClosedWindowRecord? {
        guard sessionRecord.tabs.contains(where: { $0.recoveryFilename != nil }) else {
            return nil
        }
        if let persistentID = sessionRecord.persistentIdentifier,
           let existing = records.first(where: {
               $0.sourcePersistentIdentifier == persistentID
           }) {
            return existing
        }
        let archived = ClosedWindowRecord(
            sessionRecord: sessionRecord,
            closedTabRecordIDs: closedTabRecordIDs
        )
        records.insert(archived, at: 0)
        persist()
        return archived
    }

    /// The caller saves the replacement `SessionRecord` before invoking
    /// this, so draft payloads remain protected throughout the handoff.
    func completeRestore(_ id: UUID) {
        guard let archived = removeMetadata(id) else { return }
        archived.closedTabRecordIDs.forEach(removeClosedTab)
    }

    /// Removes manifests that can no longer be restored as a complete
    /// window. Draft and closed-tab payloads deliberately remain untouched;
    /// the catalog will surface any surviving drafts individually.
    func pruneInvalidRecords(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        records.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Explicit destructive action from Recoverable Work. Associated closed-
    /// tab entries go first; each draft is then removed only if no other
    /// open/closed record references the same filename.
    func discard(_ id: UUID) {
        guard let archived = removeMetadata(id) else { return }
        archived.closedTabRecordIDs.forEach(removeClosedTab)
        Set(archived.tabs.compactMap(\.recoveryFilename)).forEach(discardDraft)
    }

    private func removeMetadata(_ id: UUID) -> ClosedWindowRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let archived = records.remove(at: index)
        persist()
        return archived
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: AppPreferenceKey.closedWindowRecords)
    }

    private static func load(from defaults: UserDefaults) -> [ClosedWindowRecord] {
        guard let data = defaults.data(forKey: AppPreferenceKey.closedWindowRecords),
              let decoded = try? JSONDecoder().decode([ClosedWindowRecord].self, from: data)
        else { return [] }
        return decoded
    }
}

/// Records on disk (UserDefaults `sessionRecords`). The actual draft
/// bytes live in `DraftsStore`'s files; this layer just remembers
/// which window owned which tabs and which files they had open.
///
/// SwiftUI on iOS only restores one `WindowGroup` scene by default,
/// so the user's other windows would be lost. The launch-id grouping
/// + pending-restore queue let the first scene proactively spawn
/// extras (`openWindow(id:)`) to cover every record from the
/// previous launch.
@MainActor
final class SessionsStore {

    static let shared = SessionsStore()

    /// Cap on stored records — old launch groups sit here until
    /// evicted by newer writes.
    static let cap = 60

    /// Tests pass an isolated UserDefaults suite and skip the global
    /// UIScene observer; production wires both to standard.
    private let defaults: UserDefaults

    private(set) var records: [SessionRecord]

    /// Fresh per app launch. Saves tag records with this so the next
    /// launch can identify the "most recent" group.
    let currentLaunchID = UUID().uuidString

    /// FIFO queue of records waiting to be applied to scenes. Seeded
    /// once per launch by `initiateRestoreSweep()`; each scene's
    /// `onAppear` pops one entry.
    private var pendingRestores: [SessionRecord] = []

    /// Trips on the first call to `initiateRestoreSweep()` so only
    /// one scene seeds the queue.
    private(set) var hasInitiatedRestore = false

    /// Maps a live `UIScene`'s object identity to the `sceneUUID`
    /// of its `SessionRecord`. Populated by `register(_:sceneUUID:)`
    /// from `EditorScene`; the `didDisconnectNotification` observer
    /// uses it to evict records when the user closes a window.
    private var sceneUUIDsByObjectIdentifier: [ObjectIdentifier: String] = [:]

    /// Mirror map from our `sceneUUID` to iPadOS's
    /// `UISceneSession.persistentIdentifier`. Saved into each
    /// `SessionRecord` at persist time so the AppDelegate can
    /// correlate a cold-launch scene to our record.
    private var persistentIdsByUUID: [String: String] = [:]

    init(defaults: UserDefaults = .standard, observesScenes: Bool = true) {
        self.defaults = defaults
        self.records = Self.load(from: defaults) ?? []
        guard observesScenes else { return }
        // `for await note in …` delivers each notification already on
        // this Task's @MainActor context, sidestepping the Sendable-
        // capture warnings from the older `addObserver(forName:…)`
        // closure-based API. `Notification`'s `object`/`userInfo` are
        // non-Sendable, so the closure form couldn't legally read
        // `scene.session` (main-actor-isolated) under Swift 6 strict
        // concurrency.
        sceneDisconnectTask = Task { @MainActor [weak self] in
            let stream = NotificationCenter.default.notifications(
                named: UIScene.didDisconnectNotification
            )
            for await note in stream {
                guard let self,
                      let scene = note.object as? UIScene
                else { continue }
                let key = ObjectIdentifier(scene)
                // A disconnect is not necessarily a user close: UIKit
                // may purge a scene object under memory pressure while
                // preserving its UISceneSession for reconnection. Drop
                // only the live object mapping here. Explicit in-app
                // closes and didDiscardSceneSessions are the permanent
                // removal signals and clear the persisted record.
                self.sceneUUIDsByObjectIdentifier.removeValue(forKey: key)
            }
        }
    }

    /// Cancels the scene-disconnect observation on dealloc — without
    /// this the Task would outlive the singleton in test injection.
    deinit {
        sceneDisconnectTask?.cancel()
    }

    private var sceneDisconnectTask: Task<Void, Never>?

    /// Called by `EditorScene` once it has both a `sceneUUID` and a
    /// live `UIWindowScene`. The disconnect observer above uses this
    /// mapping to evict the record when the user closes the window.
    /// Idempotent — repeat calls with the same arguments are no-ops.
    func register(_ scene: UIScene, sceneUUID: String) {
        sceneUUIDsByObjectIdentifier[ObjectIdentifier(scene)] = sceneUUID
        persistentIdsByUUID[sceneUUID] = scene.session.persistentIdentifier
    }

    /// Looked up by `SessionRecord.init(scene:session:)` so the
    /// record carries the iPadOS session id forward across launches.
    func persistentIdentifier(forSceneUUID uuid: String) -> String? {
        persistentIdsByUUID[uuid]
    }

    /// Resolves the live `UIScene` registered for a scene UUID, so
    /// session-scoped commands (Close Window) can target the window
    /// that actually owns the session instead of guessing from the
    /// unordered `connectedScenes` set.
    func scene(forSceneUUID uuid: String) -> UIScene? {
        guard !uuid.isEmpty else { return nil }
        return UIApplication.shared.connectedScenes.first {
            sceneUUIDsByObjectIdentifier[ObjectIdentifier($0)] == uuid
        }
    }

    /// `true` if any prior-launch record claims this iPadOS session.
    /// AppDelegate's `configurationForConnecting` uses it to decide
    /// whether a restoring session is one we want back or an iPadOS
    /// ghost to destroy.
    func hasRecord(forPersistentIdentifier id: String) -> Bool {
        records.contains { $0.persistentIdentifier == id }
    }

    func record(forPersistentIdentifier id: String) -> SessionRecord? {
        records.first { $0.persistentIdentifier == id }
    }

    /// Drop any record claiming this persistent identifier. Used
    /// from `application(_:didDiscardSceneSessions:)` so iOS-level
    /// discards (user swiped a window away in the App Switcher
    /// while the app was running) mirror into our store.
    func removeRecord(forPersistentIdentifier id: String) {
        records.removeAll { $0.persistentIdentifier == id }
        persist()
    }

    /// One-shot cleanup of orphaned `UISceneSession`s — the ones
    /// iPadOS keeps after a user dismisses a window via Stage
    /// Manager / App Switcher and that show up as "N hidden
    /// windows" on next launch. By the time this fires (cold-launch
    /// first scene `.active`), the system has already decided which
    /// sessions to reconnect; any session in `openSessions` whose
    /// `scene` is nil is genuinely orphaned. Drafts are already
    /// safe on disk from the prior `.background` / `.onDisappear`
    /// flush, so Recoverable Work remains the recovery surface. Guarded by
    /// `hasPurgedHiddenSessions` so it runs
    /// once per launch.
    private var hasPurgedHiddenSessions = false
    func purgeHiddenSessions() {
        guard !hasPurgedHiddenSessions else { return }
        hasPurgedHiddenSessions = true
        let app = UIApplication.shared
        let liveScenes = Set(app.connectedScenes.map { ObjectIdentifier($0) })
        for session in app.openSessions {
            // A session whose scene is in `connectedScenes` is the
            // window the user just opened — leave it alone.
            if let scene = session.scene, liveScenes.contains(ObjectIdentifier(scene)) {
                continue
            }
            // A persisted record means this disconnected session is
            // intentionally restorable (for example after memory
            // reclamation). Only purge truly unowned system sessions.
            if hasRecord(forPersistentIdentifier: session.persistentIdentifier) {
                continue
            }
            app.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
        }
    }

    /// First scene to call this seeds `pendingRestores` from the
    /// previous launch's records and returns the count. Subsequent
    /// callers receive `0`.
    @discardableResult
    func initiateRestoreSweep() -> Int {
        guard !hasInitiatedRestore else { return 0 }
        hasInitiatedRestore = true
        let toRestore = recordsFromPreviousLaunch()
        pendingRestores = toRestore
        // Retire dormant launch history. Keeping it as open-window metadata
        // would resurrect older sessions after the last current window closes.
        // Its surviving payloads remain available through exceptional recovery.
        records = records.filter { $0.launchID == currentLaunchID } + toRestore
        persist()
        return toRestore.count
    }

    var pendingRestoreSceneIDs: [String] { pendingRestores.map(\.sceneUUID) }

    func consumePendingRestore(sceneUUID: String? = nil) -> SessionRecord? {
        guard let index = pendingRestores.firstIndex(where: { sceneUUID == nil || $0.sceneUUID == sceneUUID }) else { return nil }
        return pendingRestores.remove(at: index)
    }

    /// Records sharing the most recent prior-launch `launchID`,
    /// oldest-first. Returns `[]` when there's nothing to restore.
    /// Used by `applySessionRestoreIfNeeded` to re-open windows
    /// that were alive at the prior involuntary kill (OOM, reboot).
    /// User-initiated closes remove their records before this point
    /// either via the explicit Close Window path (in-app close) or
    /// `didDiscardSceneSessions` (App Switcher swipe), so
    /// only "the user didn't mean to lose this" records survive.
    private func recordsFromPreviousLaunch() -> [SessionRecord] {
        let priorRecords = records.filter { $0.launchID != currentLaunchID }
        guard let mostRecent = priorRecords.max(by: { $0.lastModified < $1.lastModified }) else {
            return []
        }
        return priorRecords
            .filter { $0.launchID == mostRecent.launchID }
            .sorted { $0.lastModified < $1.lastModified }
    }

    func record(forScene sceneUUID: String) -> SessionRecord? {
        records.first { $0.sceneUUID == sceneUUID }
    }

    func save(_ record: SessionRecord) {
        records.removeAll { $0.sceneUUID == record.sceneUUID }
        records.insert(record, at: 0)
        if records.count > Self.cap {
            records.removeLast(records.count - Self.cap)
        }
        persist()
    }

    func remove(forScene sceneUUID: String) {
        records.removeAll { $0.sceneUUID == sceneUUID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: AppPreferenceKey.sessionRecords)
    }

    private static func load(from defaults: UserDefaults) -> [SessionRecord]? {
        guard let data = defaults.data(forKey: AppPreferenceKey.sessionRecords),
              let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data)
        else { return nil }
        return decoded
    }
}

extension TabSnapshot {
    @MainActor
    init(of tab: TabModel) {
        self.isPinned = tab.isPinned
        self.editorLayout = EditorLayoutSnapshot(tab: tab)
        self.displayName = tab.document.displayName
        if tab.needsCloseConfirmation { self.scratchFilename = tab.document.scratchFilename }
        if let url = tab.document.fileURL {
            // Bookmark under an active security scope — without it,
            // file-provider URLs fail bookmarkData and the tab silently
            // restores as a blank editor. Best-effort either way.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            self.fileBookmark = try? url.bookmarkData()
        }
        if let draft = tab.document.draftURL {
            self.draftFilename = draft.lastPathComponent
        }
    }
}

extension SessionRecord {
    @MainActor
    init(scene sceneUUID: String, session: EditorSession) {
        self.sceneUUID = sceneUUID
        // Only persist tabs with restorable content. Launcher /
        // file-browser tabs would otherwise come back as empty
        // `.editor` tabs (populate sets no kind), surfacing as
        // "Untitled N" blanks on the next launch.
        let restorable = session.tabs.filter {
            $0.document.fileURL != nil || $0.document.draftURL != nil || $0.needsCloseConfirmation
        }
        self.tabs = restorable.map(TabSnapshot.init(of:))
        let activeID = session.selectedTabID
        self.activeIndex = restorable.firstIndex { $0.id == activeID } ?? 0
        self.lastModified = Date()
        self.launchID = SessionsStore.shared.currentLaunchID
        self.persistentIdentifier = SessionsStore.shared.persistentIdentifier(forSceneUUID: sceneUUID)
    }
}

/// Applies a `SessionRecord` to a freshly-created `EditorSession`.
/// File loads kick off as async tasks so a hung File Provider doesn't
/// block the scene from showing.
@MainActor
enum SessionRestore {

    private typealias ResolvedSource = (url: URL, isStale: Bool)

    private struct DraftRestoreResult {
        let text: String?
        let url: URL?
        let metadata: DraftMetadata?
        let error: (any Error)?
    }

    private struct SourceRestoreResult {
        let payload: PlainTextDocument.LoadPayload?
        let error: (any Error)?
    }

    static func apply(_ record: SessionRecord, to session: EditorSession, append: Bool = false) {
        guard !record.tabs.isEmpty else { return }
        var restored: [TabModel] = []
        for snapshot in record.tabs {
            let tab = TabModel()
            tab.isPinned = snapshot.isPinned
            // Default to a blank editor. If a stale snapshot has
            // nothing left to load, recovery remains available from
            // the file browser rather than intercepting this tab.
            tab.kind = .editor
            _ = populate(tab, from: snapshot, in: session)
            restored.append(tab)
        }
        if append { session.tabs += restored }
        else { session.tabs = restored }
        let idx = min(max(record.activeIndex, 0), restored.count - 1)
        session.selectedTabID = restored[idx].id
    }

    /// Returns `true` when something was actually loaded — a resolvable
    /// fileBookmark or a draft file present on disk. `false` means the
    /// caller should leave the tab as a fresh blank editor.
    @discardableResult
    private static func populate(_ tab: TabModel, from snapshot: TabSnapshot, in session: EditorSession) -> Bool {
        let draft = DraftsStore.shared.loadAll().first {
            $0.recoveryFilename == snapshot.recoveryFilename
                || $0.url.lastPathComponent == snapshot.scratchFilename
        }
        let draftURL = draft?.url ?? snapshot.recoveryFilename.flatMap {
            DraftsStore.shared.existingRecoveryURL(named: $0)
        }
        let resolvedSource = snapshot.fileBookmark.flatMap(resolveBookmark)
        guard snapshot.recoveryFilename != nil || resolvedSource != nil else { return false }

        let state = tab.state
        let document = tab.document
        let seedRevision = document.bufferRevision
        state.loadTask?.cancel()
        state.loadGeneration &+= 1
        let generation = state.loadGeneration
        document.isLoading = true
        state.loadTask = Task { @MainActor [weak tab, weak session] in
            guard let tab else { return }
            let state = tab.state
            let document = tab.document
            defer {
                if state.loadGeneration == generation {
                    state.loadTask = nil
                    document.isLoading = false
                    session?.persistRestorationRecord()
                }
            }

            guard let draft = await loadDraft(draft, fallbackURL: draftURL, allowEmpty: snapshot.fileBookmark != nil) else { return }
            guard let source = await loadSource(resolvedSource) else { return }
            guard !Task.isCancelled else { return }

            let liveText = state.textView?.text ?? state.text
            let userEdited = document.bufferRevision != seedRevision
            applyLoadedSource(source.payload, from: resolvedSource, to: tab)

            if let draftText = draft.text {
                applyRecoveredDraft(
                    draftText,
                    result: draft,
                    sourcePayload: source.payload,
                    source: resolvedSource,
                    liveText: liveText,
                    userEdited: userEdited,
                    to: tab
                )
            } else {
                finishWithoutDraft(sourceWasLoaded: source.payload != nil, tab: tab)
            }

            if !userEdited { snapshot.editorLayout?.restore(to: tab) }
            presentRestoreError(
                draft: draft,
                source: source,
                snapshot: snapshot,
                originalDraftURL: draftURL
            )
        }
        return true
    }

    /// Returns nil only for cancellation. Ordinary read failures are data:
    /// the source may still restore, and the caller presents the right error.
    private static func loadDraft(
        _ draft: DraftRecord?, fallbackURL: URL?, allowEmpty: Bool
    ) async -> DraftRestoreResult? {
        do {
            if let draft {
                let loaded = try await DraftsStore.shared.loadForRestoration(draft, allowEmpty: allowEmpty)
                return DraftRestoreResult(text: loaded.text, url: loaded.url, metadata: draft.metadata, error: nil)
            }
            // Older zero-byte, file-backed snapshots may lack metadata and
            // are omitted from the general catalog. The bookmark identifies
            // an intentional deletion of all text, which must still restore.
            let text: String?
            if let fallbackURL { text = try await DraftsStore.readText(at: fallbackURL, allowEmpty: allowEmpty) }
            else { text = nil }
            return DraftRestoreResult(text: text, url: fallbackURL, metadata: nil, error: nil)
        } catch is CancellationError {
            return nil
        } catch {
            return DraftRestoreResult(text: nil, url: draft?.url ?? fallbackURL, metadata: draft?.metadata, error: error)
        }
    }

    /// Returns nil only for cancellation, mirroring `loadDraft`.
    private static func loadSource(_ source: ResolvedSource?) async -> SourceRestoreResult? {
        guard let source else { return SourceRestoreResult(payload: nil, error: nil) }
        do {
            let payload = try await PlainTextDocument.readPayload(from: source.url)
            return SourceRestoreResult(payload: payload, error: nil)
        } catch is CancellationError {
            return nil
        } catch {
            return SourceRestoreResult(payload: nil, error: error)
        }
    }

    private static func applyLoadedSource(
        _ payload: PlainTextDocument.LoadPayload?,
        from source: ResolvedSource?,
        to tab: TabModel
    ) {
        guard let payload, let source else { return }
        tab.document.applyPayload(payload, url: source.url)
        DocumentWorkflow.applyLoadedDocument(tab.document, at: source.url, to: tab.state)
    }

    private static func applyRecoveredDraft(
        _ draftText: String,
        result: DraftRestoreResult,
        sourcePayload: PlainTextDocument.LoadPayload?,
        source: ResolvedSource?,
        liveText: String,
        userEdited: Bool,
        to tab: TabModel
    ) {
        let state = tab.state
        let document = tab.document
        let recoveredText = userEdited ? liveText : draftText
        if sourcePayload == nil {
            document.originalData = nil
            document.fileURL = source?.url
            state.fileURL = source?.url
            state.savedBaselineText = ""
            if let url = source?.url {
                state.languageIdentifier = LanguageRegistry.identifier(for: url)
            }
        }

        document.text = recoveredText
        document.isDirty = true
        document.draftURL = result.url
        document.lineEnding = PlainTextDocument.detectLineEnding(in: recoveredText) ?? .lf
        applyDraftEncoding(result.metadata, to: document)
        // A restored draft must retain the capture-time baseline. Using the
        // just-read attrs would let the next Save overwrite external edits.
        document.sourceMtimeAtLoad = result.metadata?.sourceMtime
        document.sourceSizeAtLoad = result.metadata?.sourceSize
        state.text = recoveredText
        state.fileEncoding = document.fileEncoding
        state.lineEnding = document.lineEnding
        state.isLargeFile = !SyntaxLimit.current().allows(byteCount: recoveredText.utf8.count)
        state.setText?(recoveredText)
        tab.kind = .editor
        state.requestEditorFocus()
        presentStaleSourceCheck(
            source,
            metadata: result.metadata,
            sourcePayload: sourcePayload,
            tabID: tab.id
        )
    }

    private static func applyDraftEncoding(
        _ metadata: DraftMetadata?,
        to document: PlainTextDocument
    ) {
        guard let raw = metadata?.sourceEncodingRaw else { return }
        let encoding = String.Encoding(rawValue: raw)
        document.fileEncoding = FileEncoding(
            encoding: encoding,
            withUTF8BOM: encoding == .utf8 && (metadata?.sourceHadUTF8BOM ?? false)
        )
    }

    private static func presentStaleSourceCheck(
        _ source: ResolvedSource?,
        metadata: DraftMetadata?,
        sourcePayload: PlainTextDocument.LoadPayload?,
        tabID: UUID
    ) {
        guard let source else { return }
        let recordedMatches = sourcePayload?.modificationDate == metadata?.sourceMtime
            && sourcePayload?.data.count == metadata?.sourceSize
        if sourcePayload == nil {
            AppStateBus.shared.presentation.sourceStaleCheck = .missing(
                tabID: tabID,
                displayName: source.url.lastPathComponent
            )
        } else if source.isStale || !recordedMatches {
            AppStateBus.shared.presentation.sourceStaleCheck = .changedOnAdopt(
                tabID: tabID,
                displayName: source.url.lastPathComponent
            )
        }
    }

    private static func finishWithoutDraft(sourceWasLoaded: Bool, tab: TabModel) {
        if sourceWasLoaded {
            // A missing/corrupt draft stays on disk for Recoverable Work.
            tab.document.draftURL = nil
        } else {
            tab.document.fileURL = nil
            tab.document.draftURL = nil
            tab.state.fileURL = nil
            tab.kind = .editor
        }
    }

    private static func presentRestoreError(
        draft: DraftRestoreResult,
        source: SourceRestoreResult,
        snapshot: TabSnapshot,
        originalDraftURL: URL?
    ) {
        if let error = draft.error {
            AppStateBus.shared.presentation.openErrorMessage =
                "Couldn't restore an unsaved draft: \(error.localizedDescription)"
        } else if snapshot.recoveryFilename != nil, originalDraftURL == nil {
            AppStateBus.shared.presentation.openErrorMessage =
                "A recovery draft from the previous session is missing."
        } else if let error = source.error, draft.text == nil {
            AppStateBus.shared.presentation.openErrorMessage =
                "Couldn't restore the source file: \(error.localizedDescription)"
        }
    }

    private static func resolveBookmark(_ data: Data) -> ResolvedSource? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return (url, stale)
    }
}

/// Bridges `view.window?.windowScene` back into SwiftUI so
/// `EditorScene` can register its session and configure native close warnings.
struct SceneRegistrationBridge: UIViewRepresentable {

    let sceneUUID: String
    let unsavedDocumentCount: Int
    let onReview: () -> Void
    let onClose: () -> Void

    func makeUIView(context: Context) -> SceneRegistrationView {
        let view = SceneRegistrationView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SceneRegistrationView, context: Context) {
        uiView.onReview = onReview
        uiView.onClose = onClose
        uiView.unsavedDocumentCount = unsavedDocumentCount
        // sceneUUID starts empty, becomes non-empty on the first
        // `onAppear` once `applySessionRestoreIfNeeded` runs. The
        // dispatch hops past this render so `view.window` is wired.
        let uuid = sceneUUID
        guard !uuid.isEmpty else { return }
        DispatchQueue.main.async {
            guard let scene = uiView.window?.windowScene else { return }
            SessionsStore.shared.register(scene, sceneUUID: uuid)
        }
    }

    static func dismantleUIView(_ uiView: SceneRegistrationView, coordinator: ()) {
        uiView.clearClosureConfirmation()
    }
}

/// UIKit closes the scene after any non-cancel confirmation action. Reviewing
/// must cancel that request before handing control back to the owning window.
final class SceneRegistrationView: UIView {
    var onReview: () -> Void = {}
    var onClose: () -> Void = {}
    var unsavedDocumentCount = 0 {
        didSet {
            guard oldValue != unsavedDocumentCount else { return }
            updateClosureConfirmation()
        }
    }

    private weak var configuredScene: UIWindowScene?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateClosureConfirmation()
    }

    func clearClosureConfirmation() {
        configuredScene?.closureConfirmation = nil
        configuredScene = nil
    }

    private func updateClosureConfirmation() {
        let scene = window?.windowScene
        if configuredScene !== scene { clearClosureConfirmation() }
        guard let scene else { return }
        configuredScene = scene
        guard unsavedDocumentCount > 0 else {
            scene.closureConfirmation = nil
            return
        }
        let subject = unsavedDocumentCount == 1 ? "1 tab has" : "\(unsavedDocumentCount) tabs have"
        scene.closureConfirmation = UISceneClosureConfirmation(
            title: "Close Window With Unsaved Changes?",
            message: "\(subject) changes that haven't been saved to a file. Review them to choose what to save or keep editing. Don’t Save discards these changes and closes the window.",
            actions: closureActions()
        )
    }

    func closureActions() -> [UIAlertAction] {
        [
            // Only .cancel keeps the scene alive. A .default action proceeds
            // with destruction as soon as its synchronous handler returns;
            // it cannot wait for a review sheet, file picker, or async save.
            UIAlertAction(title: "Review Changes…", style: .cancel) { [weak self] _ in
                // Let UIKit finish its confirmation callback before SwiftUI
                // presents the review. This handler never saves or discards.
                DispatchQueue.main.async { [weak self] in self?.onReview() }
            },
            UIAlertAction(title: "Don’t Save", style: .destructive) { [weak self] _ in
                self?.onClose()
            }
        ]
    }
}
