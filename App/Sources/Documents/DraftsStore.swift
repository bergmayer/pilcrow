import Foundation
import FileEncoding

/// Metadata embedded in each committed recovery file. Untitled drafts leave
/// the fields nil and recover as fresh Untitled tabs. Legacy builds stored the
/// same value in a JSON sidecar, which the reader still accepts.
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

/// A committed recovery snapshot is one atomic file. Older versions wrote
/// UTF-8 text plus a JSON sidecar; those files remain readable and are
/// upgraded the next time they are saved.
private enum RecoveryFile {
    // Starts with an invalid UTF-8 byte so a legacy plain-text draft cannot
    // accidentally be mistaken for the envelope format.
    private static let magic = Data([0x89, 0x57, 0x52, 0x54, 0x44, 0x0D, 0x0A, 0x1A])
    private static let fixedHeaderSize = 16
    private static let maximumMetadataBytes = 1 * 1024 * 1024

    struct Header {
        let metadata: DraftMetadata?
        let textOffset: Int
    }

    static func encoded(text: String, metadata: DraftMetadata?) throws -> Data {
        let metadataData = try metadata.map { try JSONEncoder().encode($0) } ?? Data()
        var data = Data()
        let textData = Data(text.utf8)
        data.reserveCapacity(fixedHeaderSize + metadataData.count + textData.count)
        data.append(magic)

        let length = UInt64(metadataData.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((length >> UInt64(shift)) & 0xff))
        }
        data.append(metadataData)
        data.append(textData)
        return data
    }

    static func decoded(from data: Data) throws -> (text: String, metadata: DraftMetadata?)? {
        guard let header = try header(from: data) else { return nil }
        guard let text = String(data: data[header.textOffset...], encoding: .utf8) else {
            throw DraftRecoveryFailure.invalidUTF8
        }
        return (text, header.metadata)
    }

    static func header(at url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fixed = try? handle.read(upToCount: fixedHeaderSize),
              let metadataLength = metadataLength(in: fixed)
        else { return nil }
        guard metadataLength <= maximumMetadataBytes else { return nil }

        let metadata: DraftMetadata?
        if metadataLength == 0 {
            metadata = nil
        } else {
            guard let blob = try? handle.read(upToCount: metadataLength),
                  blob.count == metadataLength,
                  let decoded = try? JSONDecoder().decode(DraftMetadata.self, from: blob)
            else { return nil }
            metadata = decoded
        }
        return Header(
            metadata: metadata,
            textOffset: fixedHeaderSize + metadataLength
        )
    }

    static func preview(at url: URL, textOffset: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(textOffset))
            guard let data = try handle.read(upToCount: 2_048) else { return "" }
            return String(String(decoding: data, as: UTF8.self).prefix(80))
                .replacingOccurrences(of: "\n", with: " ")
        } catch {
            return ""
        }
    }

    private static func header(from data: Data) throws -> Header? {
        guard let metadataLength = metadataLength(in: data) else { return nil }
        guard metadataLength <= maximumMetadataBytes else {
            throw DraftRecoveryFailure.invalidUTF8
        }
        let textOffset = fixedHeaderSize + metadataLength
        guard data.count >= textOffset else { throw DraftRecoveryFailure.invalidUTF8 }

        let metadata: DraftMetadata?
        if metadataLength == 0 {
            metadata = nil
        } else {
            metadata = try JSONDecoder().decode(
                DraftMetadata.self,
                from: data[fixedHeaderSize..<textOffset]
            )
        }
        return Header(metadata: metadata, textOffset: textOffset)
    }

    private static func metadataLength(in data: Data) -> Int? {
        guard data.count >= fixedHeaderSize,
              data.prefix(magic.count) == magic
        else { return nil }
        var length: UInt64 = 0
        for byte in data[magic.count..<fixedHeaderSize] {
            length = (length << 8) | UInt64(byte)
        }
        guard length <= UInt64(Int.max) else { return nil }
        return Int(length)
    }
}

private actor RecoveryWriter {
    func write(text: String, metadata: DraftMetadata?, to url: URL) throws {
        let data = try RecoveryFile.encoded(text: text, metadata: metadata)
        try data.write(to: url, options: .atomic)

        // The atomic file is authoritative. A leftover legacy sidecar is
        // harmless, but remove it after the replacement succeeds.
        let legacySidecar = url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: legacySidecar)
    }
}

/// One recoverable dirty buffer from a previous session.
/// `Application Support/Recovery/Drafts/<UUID>.txt`. Older builds may still
/// contribute plain UTF-8 files with JSON sidecars from their former
/// Documents location until opened.
struct DraftRecord: Identifiable, Sendable {
    enum Origin: Sendable {
        case storedRecovery
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
    /// A local scratch may be newer than an existing committed recovery
    /// snapshot. When adopted, overwrite that snapshot instead of creating
    /// a duplicate.
    let replacesDraftFilename: String?

    init(
        id: UUID,
        url: URL,
        modified: Date,
        bytes: Int,
        preview: String,
        metadata: DraftMetadata?,
        origin: Origin = .storedRecovery,
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

    /// Stable ownership key used by closed-window metadata. A newer scratch
    /// row shadows its committed recovery file but still belongs to the same
    /// logical recovery item.
    var recoveryFilename: String {
        replacesDraftFilename ?? url.lastPathComponent
    }
}

/// Mac-style recovery for every dirty buffer. Writes live text to a
/// device-local Application Support directory so a system-gesture close
/// (3-finger pinch, App Switcher swipe, Stage Manager close) can't
/// lose typed bytes, with or without a save location. Legacy Documents
/// drafts are copied into Application Support and removed from their former
/// location after a verified write.
///
/// UUID-per-doc + back-reference on `PlainTextDocument.draftURL` so
/// repeat autosaves overwrite the same file — no orphan accumulation.
@MainActor
final class DraftsStore {

    static let shared = DraftsStore()

    /// A generous ceiling for unreferenced legacy/orphan snapshots. Drafts
    /// referenced by open sessions, closed windows, or recently-closed tabs
    /// are protected and may take the store above this count rather than be
    /// deleted silently.
    static let maxDrafts = 25

    /// Tests pass isolated roots. Production writes to Application Support
    /// and treats the old Documents roots as migration sources.
    private let rootOverride: URL?
    private let legacyRootOverrides: [URL]

    /// Draft filenames the cap must never evict. Defaults to every
    /// draft referenced by a persisted session/closed-item record: when several
    /// dirty tabs commit drafts on backgrounding, FIFO eviction would
    /// otherwise delete drafts just written for other still-open tabs
    /// — permanent data loss on restore. Injectable for tests.
    private let protectedDraftFilenames: @MainActor () -> Set<String>
    private var capSuspensionDepth = 0
    private let writer = RecoveryWriter()

    init(
        rootOverride: URL? = nil,
        legacyRootOverrides: [URL] = [],
        protectedDraftFilenames: (@MainActor () -> Set<String>)? = nil
    ) {
        self.rootOverride = rootOverride
        self.legacyRootOverrides = legacyRootOverrides
        self.protectedDraftFilenames = protectedDraftFilenames ?? {
            let open = SessionsStore.shared.records.flatMap { record in
                record.tabs.compactMap(\.draftFilename)
            }
            let closedWindows = ClosedWindowsStore.shared.records.flatMap { record in
                record.tabs.compactMap(\.draftFilename)
            }
            let closedTabs = ClosedTabsStore.shared.records.compactMap(\.draftFilename)
            return Set(open + closedWindows + closedTabs)
        }
        // Eagerly create only the device-local write directory. The legacy
        // Documents root is never a target for new writes.
        _ = directory
    }

    /// Where every new or updated recovery snapshot is written.
    var directory: URL {
        let root = rootOverride ?? Self.localRecoveryRoot
        let dir = root.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Device-local storage first, followed by legacy locations from older
    /// builds. Keeping them readable makes migration failure non-destructive.
    var readDirectories: [URL] {
        var directories = [directory]
        let legacyRoots: [URL]
        if rootOverride != nil {
            legacyRoots = legacyRootOverrides
        } else {
            legacyRoots = [Self.localDocumentsRoot]
        }
        directories.append(contentsOf: legacyRoots.map {
            $0.appendingPathComponent("Drafts", isDirectory: true)
        })
        var seen = Set<String>()
        return directories.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    private static var localRecoveryRoot: URL {
        let manager = FileManager.default
        let support = (try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = support.appendingPathComponent("Recovery", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let localDocumentsRoot = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    /// Creates a new UUID-named file on first write and overwrites it in
    /// place afterward. If `existing` points into the old Documents
    /// root, the bytes are first committed locally under the same filename;
    /// only then is the legacy copy removed.
    @discardableResult
    func save(text: String, existing: URL?, metadata: DraftMetadata? = nil) async throws -> URL {
        let legacyExisting = existing.flatMap { isLocalRecoveryURL($0) ? nil : $0 }
        let filename = existing?.lastPathComponent ?? "\(UUID().uuidString).txt"
        let url = legacyExisting == nil
            ? (existing ?? directory.appendingPathComponent(filename))
            : directory.appendingPathComponent(filename)
        try await writer.write(text: text, metadata: metadata, to: url)
        if capSuspensionDepth == 0 {
            enforceCap(keeping: url)
        }
        if let legacyExisting,
           legacyExisting.standardizedFileURL != url.standardizedFileURL {
            discard(legacyExisting)
        }
        return url
    }

    private func isLocalRecoveryURL(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL
    }

    /// FIFO eviction. `freshlySaved` is exempt even if its mtime
    /// is older — an in-place overwrite doesn't always bump
    /// `contentModificationDate`, and we don't want to evict the
    /// caller's brand-new write. Drafts referenced by a persisted
    /// session record are exempt too.
    private func enforceCap(keeping freshlySaved: URL?) {
        let records = loadStoredDrafts(in: [directory])
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

    func withCapEnforcementSuspended<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        capSuspensionDepth += 1
        defer { capSuspensionDepth -= 1 }
        return try await body()
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

    /// Explicit user discard removes every local/legacy copy carrying the
    /// same recovery UUID, plus any scratch shadow that points back to it.
    func discardAllCopies(named filename: String) {
        for dir in readDirectories {
            discard(dir.appendingPathComponent(filename))
        }
        ScratchStore.discard(replacingDraftFilename: filename)
    }

    /// Explicit discard from a recovery UI. A scratch row may shadow a
    /// committed snapshot with a different filename; discard both so the
    /// older copy does not reappear immediately after the newer row vanishes.
    func discard(_ record: DraftRecord) {
        if record.origin == .localScratch {
            if let replaced = record.replacesDraftFilename {
                discardAllCopies(named: replaced)
            } else {
                ScratchStore.discard(url: record.url)
            }
        } else {
            discardAllCopies(named: record.url.lastPathComponent)
        }
    }

    /// Used when discarding a closed window. A filename shared with another
    /// open/closed recovery record remains intact.
    func discardIfUnreferenced(named filename: String) {
        guard !protectedDraftFilenames().contains(filename) else { return }
        discardAllCopies(named: filename)
    }

    /// Resolves a filename across the local store and any still-present
    /// migration sources. The preferred URL wins while it exists; callers
    /// holding a pre-migration record transparently fall through to its new
    /// local location.
    func existingRecoveryURL(named filename: String, preferred: URL? = nil) -> URL? {
        var candidates: [URL] = []
        if let preferred { candidates.append(preferred) }
        candidates.append(contentsOf: readDirectories.map {
            $0.appendingPathComponent(filename)
        })
        var seen = Set<String>()
        return candidates.first {
            let path = $0.standardizedFileURL.path
            return seen.insert(path).inserted
                && FileManager.default.fileExists(atPath: path)
        }
    }

    /// One-way upgrade from the old Documents recovery folder. For
    /// each filename, preserve the newest copy: write it atomically to local
    /// Application Support, then remove all legacy copies. A download,
    /// decode, or write failure leaves the old item untouched and visible to
    /// the recovery UI for a later retry.
    func migrateLegacyRecovery() async {
        let legacyDirectories = Array(readDirectories.dropFirst())
        guard !legacyDirectories.isEmpty else { return }

        let localByFilename = Dictionary(
            uniqueKeysWithValues: loadStoredDrafts(in: [directory]).map {
                ($0.url.lastPathComponent, $0)
            }
        )
        let legacyRecords = loadStoredDrafts(in: legacyDirectories)

        for record in legacyRecords {
            let filename = record.url.lastPathComponent
            if let local = localByFilename[filename],
               local.modified >= record.modified {
                discardLegacyCopies(named: filename, in: legacyDirectories)
                continue
            }
            do {
                let text = try await Self.readText(
                    at: record.url,
                    allowEmpty: record.metadata != nil
                )
                _ = try await save(
                    text: text,
                    existing: record.url,
                    metadata: record.metadata
                )
                discardLegacyCopies(named: filename, in: legacyDirectories)
            } catch {
                // Best effort. loadAll() continues to surface the legacy
                // record, and the next app launch retries the migration.
                continue
            }
        }
    }

    private func discardLegacyCopies(named filename: String, in directories: [URL]) {
        for legacyDirectory in directories {
            discard(legacyDirectory.appendingPathComponent(filename))
        }
    }

    /// Every recoverable snapshot from local storage plus legacy migration
    /// roots, newest first, with empty untitled records filtered.
    func loadAll() -> [DraftRecord] {
        let stored = loadStoredDrafts(in: readDirectories)
        guard rootOverride == nil else { return stored }

        let scratch = ScratchStore.loadAll()
        let storedByFilename = Dictionary(
            uniqueKeysWithValues: stored.map { ($0.url.lastPathComponent, $0) }
        )
        var hiddenStoredFilenames = Set<String>()
        var visibleScratch: [DraftRecord] = []

        for record in scratch {
            guard let filename = record.replacesDraftFilename,
                  let storedRecord = storedByFilename[filename]
            else {
                visibleScratch.append(record)
                continue
            }
            if record.modified >= storedRecord.modified {
                hiddenStoredFilenames.insert(filename)
                visibleScratch.append(record)
            }
            // If the committed copy is newer, the scratch is an obsolete
            // shadow from before the last committed lifecycle flush.
        }

        return (stored.filter { !hiddenStoredFilenames.contains($0.url.lastPathComponent) }
            + visibleScratch)
            .sorted { $0.modified > $1.modified }
    }

    private func loadStoredDrafts(in directories: [URL]) -> [DraftRecord] {
        var records: [DraftRecord] = []
        var seen = Set<String>()
        for dir in directories {
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
                let storedBytes = attrs?.fileSize ?? 0
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                let envelopeHeader = RecoveryFile.header(at: url)
                let metadata: DraftMetadata?
                if let envelopeHeader {
                    metadata = envelopeHeader.metadata
                } else if let blob = try? Data(contentsOf: sidecar) {
                    metadata = try? JSONDecoder().decode(DraftMetadata.self, from: blob)
                } else {
                    metadata = nil
                }
                let bytes = max(0, storedBytes - (envelopeHeader?.textOffset ?? 0))
                // A zero-byte file-backed draft means the user deleted
                // everything. Preserve it. Empty untitled drafts carry no
                // useful state and remain filtered from the launcher.
                guard bytes > 0 || metadata != nil else { continue }
                records.append(DraftRecord(
                    id: id,
                    url: url,
                    modified: modified,
                    bytes: bytes,
                    preview: envelopeHeader.map {
                        RecoveryFile.preview(at: url, textOffset: $0.textOffset)
                    } ?? Self.legacyPreview(at: url),
                    metadata: metadata
                ))
            }
        }
        // The same UUID may exist in local and legacy roots during migration.
        // Surface only the newest copy; constructing a
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
        if let decoded = try RecoveryFile.decoded(from: data) {
            guard allowEmpty || !decoded.text.isEmpty else {
                throw DraftRecoveryFailure.emptyDraft
            }
            return decoded.text
        }
        guard allowEmpty || !data.isEmpty else { throw DraftRecoveryFailure.emptyDraft }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DraftRecoveryFailure.invalidUTF8
        }
        return text
    }

    nonisolated static func preview(at url: URL) -> String {
        if let header = RecoveryFile.header(at: url) {
            return RecoveryFile.preview(at: url, textOffset: header.textOffset)
        }
        return legacyPreview(at: url)
    }

    nonisolated private static func legacyPreview(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_048) else { return "" }
        // Lossy decode — the 2 KB cut can split a multibyte character.
        let str = String(decoding: data, as: UTF8.self)
        return String(str.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    nonisolated static func metadata(at draftURL: URL) -> DraftMetadata? {
        if let header = RecoveryFile.header(at: draftURL) {
            return header.metadata
        }
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

/// Metadata for the debounced local crash shadow. The UUID keeps two
/// windows editing the same source from overwriting each other, while the
/// revision key and draft filename reconnect the snapshot to its source and
/// its last committed local recovery file after a hard process kill.
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

    private typealias ResolvedSource = (url: URL, isStale: Bool)
    private typealias DiskAttributes = (mtime: Date, size: Int)

    private struct SourceRecovery {
        let source: ResolvedSource
        let attributes: DiskAttributes?
        let payload: PlainTextDocument.LoadPayload?
    }

    @discardableResult
    static func adopt(
        _ draft: DraftRecord,
        into tab: TabModel,
        store: DraftsStore = .shared
    ) async throws -> SourceStaleCheck? {
        guard draft.bytes <= PlainTextDocument.hardSizeCap else {
            throw PlainTextDocument.DocumentError.fileTooLarge(bytes: draft.bytes)
        }
        let readableURL = readableURL(for: draft, store: store)
        let text = try await DraftsStore.readText(
            at: readableURL,
            allowEmpty: draft.metadata != nil
        )
        let source = await loadSource(from: draft.metadata)
        let existing = existingDraftURL(for: draft, readableURL: readableURL, store: store)
        let adoptedDraftURL = try await store.save(
            text: text,
            existing: existing,
            metadata: draft.metadata
        )
        discardOriginal(draft)
        applyDraft(text, at: adoptedDraftURL, byteCount: draft.bytes, to: tab)

        guard let source else {
            tab.state.savedBaselineText = ""
            tab.kind = .editor
            tab.state.requestEditorFocus()
            return nil
        }
        applySource(source, metadata: draft.metadata, to: tab)
        let staleCheck = staleCheck(for: source, metadata: draft.metadata, tabID: tab.id)
        tab.kind = .editor
        tab.state.requestEditorFocus()
        return staleCheck
    }

    private static func readableURL(for draft: DraftRecord, store: DraftsStore) -> URL {
        guard draft.origin != .localScratch else { return draft.url }
        return store.existingRecoveryURL(
            named: draft.url.lastPathComponent,
            preferred: draft.url
        ) ?? draft.url
    }

    private static func loadSource(from metadata: DraftMetadata?) async -> SourceRecovery? {
        guard let source = metadata?.sourceBookmark.flatMap(resolveBookmark) else { return nil }
        let attributes = PlainTextDocument.diskAttrs(of: source.url)
        let payload = try? await PlainTextDocument.readPayload(from: source.url)
        return SourceRecovery(source: source, attributes: attributes, payload: payload)
    }

    private static func existingDraftURL(
        for draft: DraftRecord,
        readableURL: URL,
        store: DraftsStore
    ) -> URL? {
        guard draft.origin == .localScratch else { return readableURL }
        return draft.replacesDraftFilename.flatMap { filename in
            store.readDirectories
                .map { $0.appendingPathComponent(filename) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private static func discardOriginal(_ draft: DraftRecord) {
        if draft.origin == .localScratch {
            ScratchStore.discard(url: draft.url)
        } else {
            ScratchStore.discard(replacingDraftFilename: draft.url.lastPathComponent)
        }
    }

    private static func applyDraft(
        _ text: String,
        at draftURL: URL,
        byteCount: Int,
        to tab: TabModel
    ) {
        tab.document.text = text
        tab.document.isDirty = true
        tab.document.fileURL = nil
        tab.document.draftURL = draftURL
        tab.document.lineEnding = PlainTextDocument.detectLineEnding(in: text) ?? .lf
        tab.state.text = text
        tab.state.fileURL = nil
        tab.state.lineEnding = tab.document.lineEnding
        tab.state.isLargeFile = !SyntaxLimit.current().allows(byteCount: byteCount)
    }

    private static func applySource(
        _ recovery: SourceRecovery,
        metadata: DraftMetadata?,
        to tab: TabModel
    ) {
        let sourceURL = recovery.source.url
        tab.document.fileURL = sourceURL
        tab.state.fileURL = sourceURL
        tab.state.languageIdentifier = LanguageRegistry.identifier(for: sourceURL)
        if let rawEncoding = metadata?.sourceEncodingRaw {
            let encoding = String.Encoding(rawValue: rawEncoding)
            tab.document.fileEncoding = FileEncoding(
                encoding: encoding,
                withUTF8BOM: encoding == .utf8 && (metadata?.sourceHadUTF8BOM ?? false)
            )
        } else if let payload = recovery.payload {
            tab.document.fileEncoding = payload.encoding
        }
        tab.document.originalData = recovery.payload?.data
        tab.state.fileEncoding = tab.document.fileEncoding
        tab.document.sourceMtimeAtLoad = recovery.attributes?.mtime
        tab.document.sourceSizeAtLoad = recovery.attributes?.size
        tab.state.savedBaselineText = recovery.payload?.text ?? ""
    }

    private static func staleCheck(
        for recovery: SourceRecovery,
        metadata: DraftMetadata?,
        tabID: UUID
    ) -> SourceStaleCheck? {
        let displayName = recovery.source.url.lastPathComponent
        guard let attributes = recovery.attributes else {
            return .missing(tabID: tabID, displayName: displayName)
        }
        guard recovery.payload != nil, !recovery.source.isStale else {
            return .changedOnAdopt(tabID: tabID, displayName: displayName)
        }
        if let recordedMtime = metadata?.sourceMtime,
           let recordedSize = metadata?.sourceSize,
           attributes.mtime != recordedMtime || attributes.size != recordedSize {
            return .changedOnAdopt(tabID: tabID, displayName: displayName)
        }
        return nil
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
