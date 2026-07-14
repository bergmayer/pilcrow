import Foundation
import FileEncoding

/// Sidecar JSON next to each draft .txt. Untitled drafts leave the
/// fields nil and recover as fresh Untitled tabs.
struct DraftMetadata: Codable, Sendable {
    /// Security-scoped bookmark, not a raw path: file-provider
    /// locations (Nextcloud, iCloud) need explicit scope to re-open
    /// after relaunch.
    var sourceBookmark: Data?
    /// Last 2-3 path components for the recovery row.
    var sourceDisplay: String?
    /// `String.Encoding.rawValue`. nil for untitled.
    var sourceEncodingRaw: UInt?
    /// Disk state of the source at the moment the draft was last
    /// written. The launcher's adoption path re-reads disk mtime/
    /// size and compares — if either differs (or the file's gone)
    /// the user gets a missing / changed dialog before the buffer
    /// becomes editable. Cheaper than a content hash and good
    /// enough to catch the "someone else wrote it" race.
    var sourceMtime: Date?
    var sourceSize: Int?
    /// `FileEncoding` distinguishes UTF-8 with BOM from plain UTF-8;
    /// raw `String.Encoding` alone cannot preserve that choice.
    var sourceHadUTF8BOM: Bool? = nil
}

/// One recoverable dirty buffer from a previous session.
/// `Documents/Drafts/<UUID>.txt` + optional `<UUID>.json` sidecar.
struct DraftRecord: Identifiable, Sendable {
    enum Origin: Sendable {
        case syncedDraft
        case localScratch
    }

    let id: UUID
    let url: URL
    let modified: Date
    let bytes: Int
    let preview: String
    /// `nil` → recovers as Untitled. Non-nil → re-opens the
    /// bookmarked URL and applies drafted text on top, marking
    /// the doc dirty so the user knows disk still has the old bytes.
    let metadata: DraftMetadata?
    let origin: Origin
    /// A local scratch may be newer than an existing synced draft. When
    /// adopted, overwrite that draft instead of creating a duplicate.
    let replacesDraftFilename: String?

    init(
        id: UUID,
        url: URL,
        modified: Date,
        bytes: Int,
        preview: String,
        metadata: DraftMetadata?,
        origin: Origin = .syncedDraft,
        replacesDraftFilename: String? = nil
    ) {
        self.id = id
        self.url = url
        self.modified = modified
        self.bytes = bytes
        self.preview = preview
        self.metadata = metadata
        self.origin = origin
        self.replacesDraftFilename = replacesDraftFilename
    }
}

/// Mac-style autosave for every dirty buffer. Writes live text to
/// `Documents/Drafts/<UUID>.txt` so a system-gesture close
/// (3-finger pinch, App Switcher swipe, Stage Manager close) can't
/// lose typed bytes, with or without a save location.
///
/// UUID-per-doc + back-reference on `PlainTextDocument.draftURL` so
/// repeat autosaves overwrite the same file — no orphan accumulation.
@MainActor
final class DraftsStore {

    static let shared = DraftsStore()

    /// Six is enough to span a session's worth of experiments
    /// without becoming clutter. New pushes oldest out — the sheet
    /// stays glance-readable.
    static let maxDrafts = 6

    /// Tests pass an isolated temp directory here; production leaves it
    /// nil and we resolve through `UbiquityContainer` so the iCloud /
    /// local pick follows the live Settings toggle.
    private let rootOverride: URL?

    /// Draft filenames the cap must never evict. Defaults to every
    /// draft referenced by a persisted session record: when several
    /// dirty tabs commit drafts on backgrounding, FIFO eviction would
    /// otherwise delete drafts just written for other still-open tabs
    /// — permanent data loss on restore. Injectable for tests.
    private let protectedDraftFilenames: @MainActor () -> Set<String>
    private var capSuspensionDepth = 0

    init(
        rootOverride: URL? = nil,
        protectedDraftFilenames: (@MainActor () -> Set<String>)? = nil
    ) {
        self.rootOverride = rootOverride
        self.protectedDraftFilenames = protectedDraftFilenames ?? {
            Set(SessionsStore.shared.records.flatMap { record in
                record.tabs.compactMap(\.draftFilename)
            })
        }
        // Eagerly ensure draft directories exist so first-write doesn't
        // race with directory creation when the user toggles iCloud
        // mid-session.
        for root in roots {
            let dir = root.appendingPathComponent("Drafts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Where new drafts get written. Resolved on access so a Settings
    /// toggle of "Sync via iCloud Drive" takes effect immediately
    /// without needing a relaunch.
    var directory: URL {
        let root = rootOverride ?? UbiquityContainer.documentsURLForWrite
        let dir = root.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every root the launcher should consider when listing drafts —
    /// iCloud + local. Reading from both means flipping the sync
    /// toggle never hides existing files; the user's old iCloud
    /// drafts stay browseable even after going local-only.
    var readDirectories: [URL] {
        roots.map { root in
            let dir = root.appendingPathComponent("Drafts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    private var roots: [URL] {
        if let rootOverride { return [rootOverride] }
        return UbiquityContainer.documentsRootsForRead
    }

    /// Creates a new UUID-named file on first write, overwrites in
    /// place after that. The returned URL is what the caller should
    /// stash on `PlainTextDocument.draftURL` so the next autosave
    /// hits the same path.
    @discardableResult
    func save(text: String, existing: URL?, metadata: DraftMetadata? = nil) -> URL? {
        let url = existing ?? directory.appendingPathComponent("\(UUID().uuidString).txt")
        let isNew = existing == nil
        let data = Data(text.utf8)
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        do {
            try data.write(to: url, options: .atomic)
            if let metadata {
                let blob = try JSONEncoder().encode(metadata)
                try blob.write(to: sidecar, options: .atomic)
            } else {
                // Strip any stale sidecar — the doc may have been
                // saved-then-reverted, in which case a leftover
                // sidecar would surface a phantom "source" hint.
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try FileManager.default.removeItem(at: sidecar)
                }
            }
            if capSuspensionDepth == 0 {
                enforceCap(keeping: url)
            }
            return url
        } catch {
            if isNew {
                discard(url)
            }
            return nil
        }
    }

    /// FIFO eviction. `freshlySaved` is exempt even if its mtime
    /// is older — an in-place overwrite doesn't always bump
    /// `contentModificationDate`, and we don't want to evict the
    /// caller's brand-new write. Drafts referenced by a persisted
    /// session record are exempt too.
    private func enforceCap(keeping freshlySaved: URL?) {
        let records = loadSyncedDrafts()
        guard records.count > Self.maxDrafts else { return }
        let protected = protectedDraftFilenames()
        var toEvict = Array(records.reversed())
        var remaining = records.count
        while remaining > Self.maxDrafts, let oldest = toEvict.first {
            toEvict.removeFirst()
            if let freshlySaved,
               oldest.url.standardizedFileURL == freshlySaved.standardizedFileURL { continue }
            if protected.contains(oldest.url.lastPathComponent) { continue }
            discard(oldest.url)
            remaining -= 1
        }
    }

    /// Batch lifecycle flushes write every dirty tab before the new
    /// SessionRecord exists. Suspend per-write eviction across that batch,
    /// persist the record, then call `enforceCapNow()` so every newly
    /// referenced filename is protected before any eviction decision.
    func withCapEnforcementSuspended<T>(_ body: () throws -> T) rethrows -> T {
        capSuspensionDepth += 1
        defer { capSuspensionDepth -= 1 }
        return try body()
    }

    func enforceCapNow() {
        enforceCap(keeping: nil)
    }

    /// Missing files are fine — Save-As and Discard both call here
    /// without knowing whether the draft was ever written.
    func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: sidecar)
    }

    /// Every recoverable draft from every active root (iCloud and
    /// local), newest first, empties filtered. Reading the union
    /// means a user who toggled iCloud sync off still sees their
    /// previously-synced drafts in the launcher.
    func loadAll() -> [DraftRecord] {
        let synced = loadSyncedDrafts()
        guard rootOverride == nil else { return synced }

        let scratch = ScratchStore.loadAll()
        let syncedByFilename = Dictionary(
            uniqueKeysWithValues: synced.map { ($0.url.lastPathComponent, $0) }
        )
        var hiddenSyncedFilenames = Set<String>()
        var visibleScratch: [DraftRecord] = []

        for record in scratch {
            guard let filename = record.replacesDraftFilename,
                  let syncedRecord = syncedByFilename[filename]
            else {
                visibleScratch.append(record)
                continue
            }
            if record.modified >= syncedRecord.modified {
                hiddenSyncedFilenames.insert(filename)
                visibleScratch.append(record)
            }
            // If the synced copy is newer, the scratch is an obsolete
            // shadow from before the last committed lifecycle flush.
        }

        return (synced.filter { !hiddenSyncedFilenames.contains($0.url.lastPathComponent) }
            + visibleScratch)
            .sorted { $0.modified > $1.modified }
    }

    private func loadSyncedDrafts() -> [DraftRecord] {
        var records: [DraftRecord] = []
        var seen = Set<String>()
        for dir in readDirectories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                guard url.pathExtension == "txt" else { continue }
                let canonical = url.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = attrs?.contentModificationDate ?? .distantPast
                let bytes = attrs?.fileSize ?? 0
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                let metadata: DraftMetadata?
                if let blob = try? Data(contentsOf: sidecar) {
                    metadata = try? JSONDecoder().decode(DraftMetadata.self, from: blob)
                } else {
                    metadata = nil
                }
                // A zero-byte file-backed draft means the user deleted
                // everything. Preserve it. Empty untitled drafts carry no
                // useful state and remain filtered from the launcher.
                guard bytes > 0 || metadata != nil else { continue }
                records.append(DraftRecord(
                    id: id,
                    url: url,
                    modified: modified,
                    bytes: bytes,
                    preview: Self.preview(at: url),
                    metadata: metadata
                ))
            }
        }
        // The same UUID may exist in both local and iCloud roots after a
        // sync-toggle change. Surface only the newest copy; constructing a
        // Dictionary directly would trap on that duplicate filename.
        var newestByFilename: [String: DraftRecord] = [:]
        for record in records {
            let filename = record.url.lastPathComponent
            if let existing = newestByFilename[filename], existing.modified >= record.modified {
                continue
            }
            newestByFilename[filename] = record
        }
        return newestByFilename.values.sorted { $0.modified > $1.modified }
    }

    /// Draft files are UTF-8 by construction. Read them away from the
    /// main actor and explicitly materialize iCloud items first; a failed
    /// read is an error, never an empty replacement buffer.
    nonisolated static func readText(at url: URL, allowEmpty: Bool = false) async throws -> String {
        try await materializeIfNeeded(at: url)
        let data = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url)
        }.value
        guard allowEmpty || !data.isEmpty else { throw DraftRecoveryFailure.emptyDraft }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DraftRecoveryFailure.invalidUTF8
        }
        return text
    }

    nonisolated static func preview(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_048) else { return "" }
        // Lossy decode — the 2 KB cut can split a multibyte character.
        let str = String(decoding: data, as: UTF8.self)
        return String(str.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    nonisolated static func metadata(at draftURL: URL) -> DraftMetadata? {
        let sidecar = draftURL.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? JSONDecoder().decode(DraftMetadata.self, from: data)
    }

    nonisolated private static func materializeIfNeeded(at url: URL) async throws {
        let manager = FileManager.default
        guard manager.isUbiquitousItem(at: url) else { return }
        try manager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values.ubiquitousItemDownloadingStatus == .current { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw DraftRecoveryFailure.downloadTimedOut
    }
}

enum DraftRecoveryFailure: LocalizedError {
    case emptyDraft
    case invalidUTF8
    case downloadTimedOut
    case migrationFailed

    var errorDescription: String? {
        switch self {
        case .emptyDraft:
            "The recovery draft is empty. Its original file was left untouched."
        case .invalidUTF8:
            "The recovery draft is damaged and couldn't be decoded. Its original file was left untouched."
        case .downloadTimedOut:
            "The recovery draft couldn't be downloaded from iCloud in time. Try again when it is available locally."
        case .migrationFailed:
            "The local recovery snapshot couldn't be moved into the drafts folder. Its original snapshot was left untouched."
        }
    }
}

/// Metadata for the per-keystroke local crash shadow. The UUID keeps two
/// windows editing the same source from overwriting each other, while the
/// revision key and draft filename reconnect the snapshot to its source and
/// its last committed synced recovery file after a hard process kill.
struct ScratchSidecar: Codable, Sendable {
    let id: UUID
    let revisionKey: String
    let draftFilename: String?
    let metadata: DraftMetadata?
}

enum ScratchStore {
    enum Failure: Error {
        case applicationSupportUnavailable
    }

    nonisolated static var directory: URL? {
        let manager = FileManager.default
        guard let support = try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = support.appendingPathComponent("AutoSavedDocuments", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func url(for id: UUID) throws -> URL {
        guard let directory else { throw Failure.applicationSupportUnavailable }
        return directory.appendingPathComponent(id.uuidString).appendingPathExtension("txt")
    }

    nonisolated static func write(text: String, sidecar: ScratchSidecar) throws {
        let textURL = try url(for: sidecar.id)
        let metadataURL = textURL.deletingPathExtension().appendingPathExtension("json")
        try JSONEncoder().encode(sidecar).write(to: metadataURL, options: .atomic)
        try Data(text.utf8).write(to: textURL, options: .atomic)
    }

    nonisolated static func discard(id: UUID) {
        guard let url = try? url(for: id) else { return }
        discard(url: url)
    }

    nonisolated static func discard(url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(
            at: url.deletingPathExtension().appendingPathExtension("json")
        )
    }

    nonisolated static func discard(replacingDraftFilename filename: String) {
        for record in loadAll() where record.replacesDraftFilename == filename {
            discard(url: record.url)
        }
    }

    nonisolated static func loadAll() -> [DraftRecord] {
        guard let directory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard url.pathExtension == "txt" else { return nil }
            let metadataURL = url.deletingPathExtension().appendingPathExtension("json")
            let sidecar = (try? Data(contentsOf: metadataURL))
                .flatMap { try? JSONDecoder().decode(ScratchSidecar.self, from: $0) }
            let attrs = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            let bytes = attrs?.fileSize ?? 0
            guard bytes > 0 || sidecar?.metadata != nil else { return nil }
            return DraftRecord(
                id: sidecar?.id
                    ?? UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                    ?? UUID(),
                url: url,
                modified: attrs?.contentModificationDate ?? .distantPast,
                bytes: bytes,
                preview: DraftsStore.preview(at: url),
                metadata: sidecar?.metadata,
                origin: .localScratch,
                replacesDraftFilename: sidecar?.draftFilename
            )
        }
        .sorted { $0.modified > $1.modified }
    }
}

private final class ScratchGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0
    private var shouldKeepFile = false

    func note(_ generation: UInt64, shouldKeepFile: Bool) {
        lock.lock()
        if generation >= latest {
            latest = generation
            self.shouldKeepFile = shouldKeepFile
        }
        lock.unlock()
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == latest
    }

    var wantsFile: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldKeepFile
    }
}

/// Serializes writes for one open buffer. The lock-backed generation gate is
/// updated synchronously by Save/Discard, so even a large write already in
/// progress removes its output instead of briefly resurrecting stale bytes.
actor ScratchWriter {
    nonisolated private let generationGate = ScratchGenerationGate()

    nonisolated func noteLatestWrite(_ generation: UInt64) {
        generationGate.note(generation, shouldKeepFile: true)
    }

    nonisolated func noteLatestDiscard(_ generation: UInt64) {
        generationGate.note(generation, shouldKeepFile: false)
    }

    func write(text: String, sidecar: ScratchSidecar, generation: UInt64) {
        guard generationGate.isCurrent(generation) else { return }
        try? ScratchStore.write(text: text, sidecar: sidecar)
        if !generationGate.isCurrent(generation), !generationGate.wantsFile {
            ScratchStore.discard(id: sidecar.id)
        }
    }

    func discard(id: UUID, generation: UInt64) {
        guard generationGate.isCurrent(generation) else { return }
        ScratchStore.discard(id: id)
    }
}

/// Shared adoption path for both recovery UIs. All fallible reads finish
/// before the tab is mutated, so a provider error cannot turn a valid draft
/// into an empty dirty buffer that a later lifecycle flush deletes.
@MainActor
enum DraftRecoveryWorkflow {

    @discardableResult
    static func adopt(_ draft: DraftRecord, into tab: TabModel) async throws -> SourceStaleCheck? {
        guard draft.bytes <= PlainTextDocument.hardSizeCap else {
            throw PlainTextDocument.DocumentError.fileTooLarge(bytes: draft.bytes)
        }
        let text = try await DraftsStore.readText(
            at: draft.url,
            allowEmpty: draft.metadata != nil
        )

        let resolvedSource: (url: URL, isStale: Bool)? = draft.metadata?.sourceBookmark
            .flatMap(resolveBookmark)
        let attrs = resolvedSource.flatMap { PlainTextDocument.diskAttrs(of: $0.url) }
        let sourcePayload: PlainTextDocument.LoadPayload?
        if let source = resolvedSource,
           let payload = try? await PlainTextDocument.readPayload(from: source.url) {
            sourcePayload = payload
        } else {
            sourcePayload = nil
        }

        let adoptedDraftURL: URL
        if draft.origin == .localScratch {
            let existing = draft.replacesDraftFilename.flatMap { filename in
                DraftsStore.shared.readDirectories
                    .map { $0.appendingPathComponent(filename) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            }
            guard let migrated = DraftsStore.shared.save(
                text: text,
                existing: existing,
                metadata: draft.metadata
            ) else {
                throw DraftRecoveryFailure.migrationFailed
            }
            ScratchStore.discard(url: draft.url)
            adoptedDraftURL = migrated
        } else {
            adoptedDraftURL = draft.url
            ScratchStore.discard(replacingDraftFilename: draft.url.lastPathComponent)
        }

        tab.document.text = text
        tab.document.isDirty = true
        tab.document.fileURL = nil
        tab.document.draftURL = adoptedDraftURL
        tab.document.lineEnding = PlainTextDocument.detectLineEnding(in: text) ?? .lf
        tab.state.text = text
        tab.state.fileURL = nil
        tab.state.lineEnding = tab.document.lineEnding
        tab.state.isLargeFile = !SyntaxLimit.current().allows(byteCount: draft.bytes)

        if let resolvedSource {
            tab.document.fileURL = resolvedSource.url
            tab.state.fileURL = resolvedSource.url
            tab.state.languageIdentifier = LanguageRegistry.identifier(for: resolvedSource.url)
            if let rawEncoding = draft.metadata?.sourceEncodingRaw {
                let encoding = String.Encoding(rawValue: rawEncoding)
                tab.document.fileEncoding = FileEncoding(
                    encoding: encoding,
                    withUTF8BOM: encoding == .utf8
                        && (draft.metadata?.sourceHadUTF8BOM ?? false)
                )
            } else if let sourcePayload {
                tab.document.fileEncoding = sourcePayload.encoding
            }
            tab.document.originalData = sourcePayload?.data
            tab.state.fileEncoding = tab.document.fileEncoding
            tab.document.sourceMtimeAtLoad = attrs?.mtime
            tab.document.sourceSizeAtLoad = attrs?.size
            tab.state.savedBaselineText = sourcePayload?.text ?? ""
            tab.kind = .editor
            tab.state.requestEditorFocus()

            guard let attrs else {
                return .missing(tabID: tab.id, displayName: resolvedSource.url.lastPathComponent)
            }
            if sourcePayload == nil || resolvedSource.isStale {
                return .changedOnAdopt(
                    tabID: tab.id,
                    displayName: resolvedSource.url.lastPathComponent
                )
            }
            if let recordedMtime = draft.metadata?.sourceMtime,
               let recordedSize = draft.metadata?.sourceSize,
               attrs.mtime != recordedMtime || attrs.size != recordedSize {
                return .changedOnAdopt(
                    tabID: tab.id,
                    displayName: resolvedSource.url.lastPathComponent
                )
            }
            return nil
        }

        tab.state.savedBaselineText = ""
        tab.kind = .editor
        tab.state.requestEditorFocus()
        return nil
    }

    private static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
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
