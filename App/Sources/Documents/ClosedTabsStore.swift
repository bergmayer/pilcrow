import Foundation

/// Compact persisted metadata for a closed tab. File contents live in a
/// quota-managed Application Support directory; external locations are held
/// as bookmarks so File Provider URLs remain usable after relaunch.
struct ClosedTabRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let displayName: String
    let sourceBookmark: Data?
    let snapshotFilename: String?
    let draftFilename: String?
    let closedAt: Date

    /// Decode-only migration fields from the original UserDefaults format.
    fileprivate let legacyFileURL: URL?
    fileprivate let legacySnapshot: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        fileURL: URL?,
        unsavedSnapshot: String?,
        draftFilename: String? = nil,
        closedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceBookmark = nil
        self.snapshotFilename = nil
        self.draftFilename = draftFilename
        self.closedAt = closedAt
        self.legacyFileURL = fileURL
        self.legacySnapshot = unsavedSnapshot
    }

    fileprivate init(
        id: UUID,
        displayName: String,
        sourceBookmark: Data?,
        snapshotFilename: String?,
        draftFilename: String?,
        closedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceBookmark = sourceBookmark
        self.snapshotFilename = snapshotFilename
        self.draftFilename = draftFilename
        self.closedAt = closedAt
        self.legacyFileURL = nil
        self.legacySnapshot = nil
    }

    /// Compatibility accessors for call sites and old unit fixtures. New
    /// records resolve their bookmark and load their snapshot through the
    /// store so errors can be surfaced instead of silently becoming empty.
    var fileURL: URL? {
        legacyFileURL ?? sourceBookmark.flatMap(Self.resolveBookmark)
    }

    var unsavedSnapshot: String? { legacySnapshot }
    var hasSnapshot: Bool { snapshotFilename != nil || legacySnapshot != nil }

    var isUnsavedScratch: Bool {
        guard fileURL == nil else { return false }
        if let legacySnapshot { return !legacySnapshot.isEmpty }
        return snapshotFilename != nil
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, sourceBookmark, snapshotFilename, draftFilename, closedAt
        case fileURL, unsavedSnapshot
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        sourceBookmark = try values.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        snapshotFilename = try values.decodeIfPresent(String.self, forKey: .snapshotFilename)
        draftFilename = try values.decodeIfPresent(String.self, forKey: .draftFilename)
        closedAt = try values.decode(Date.self, forKey: .closedAt)
        legacyFileURL = try values.decodeIfPresent(URL.self, forKey: .fileURL)
        legacySnapshot = try values.decodeIfPresent(String.self, forKey: .unsavedSnapshot)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encodeIfPresent(sourceBookmark, forKey: .sourceBookmark)
        try values.encodeIfPresent(snapshotFilename, forKey: .snapshotFilename)
        try values.encodeIfPresent(draftFilename, forKey: .draftFilename)
        try values.encode(closedAt, forKey: .closedAt)
        // Retain legacy payloads only when migration could not externalize
        // them; a later launch can retry instead of silently losing data.
        try values.encodeIfPresent(legacyFileURL, forKey: .fileURL)
        try values.encodeIfPresent(legacySnapshot, forKey: .unsavedSnapshot)
    }
}

enum ClosedTabsFailure: LocalizedError {
    case sourceUnavailable
    case snapshotMissing
    case snapshotUnreadable(any Error)
    case snapshotWriteFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The closed tab's original file is no longer available. The history entry was kept so you can retry."
        case .snapshotMissing:
            "The closed tab's recovery snapshot is missing. The history entry was kept so you can retry."
        case .snapshotUnreadable(let error):
            "The closed tab's recovery snapshot couldn't be read: \(error.localizedDescription)"
        case .snapshotWriteFailed(let error):
            "The closed tab couldn't be archived: \(error.localizedDescription)"
        }
    }
}

/// App-wide recently-closed pool. Metadata stays small enough for
/// UserDefaults; exact dirty buffers live in bounded files.
@MainActor
@Observable
final class ClosedTabsStore {

    static let shared = ClosedTabsStore()
    static let cap = 25
    static let maxStoredBytes = 250 * 1_024 * 1_024

    private let defaults: UserDefaults
    private let storageDirectory: URL
    private(set) var records: [ClosedTabRecord]

    init(defaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.defaults = defaults
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        try? FileManager.default.createDirectory(
            at: self.storageDirectory,
            withIntermediateDirectories: true
        )
        self.records = Self.load(from: defaults) ?? []
        migrateLegacyRecords()
        removeOrphanedPayloads()
        enforceLimits()
        save()
    }

    func record(_ entry: ClosedTabRecord) {
        let hasMeaningfulSnapshot = entry.snapshotFilename != nil
            || (entry.unsavedSnapshot?.isEmpty == false)
        guard entry.fileURL != nil || hasMeaningfulSnapshot else { return }
        do {
            let normalized = try normalize(entry)
            records.insert(normalized, at: 0)
            enforceLimits()
            save()
        } catch {
            AppStateBus.shared.presentation.openErrorMessage = error.localizedDescription
        }
    }

    var first: ClosedTabRecord? { records.first }

    /// Kept for compatibility. The returned value is hydrated before its
    /// backing file is deleted; new reopen code uses `first` + `remove` so a
    /// provider failure does not consume the history entry.
    func popFirst() -> ClosedTabRecord? {
        guard let entry = records.first else { return nil }
        let snapshot: String?
        do {
            snapshot = try loadSnapshotSynchronously(entry)
        } catch {
            AppStateBus.shared.presentation.openErrorMessage = error.localizedDescription
            return nil
        }
        let hydrated = ClosedTabRecord(
            id: entry.id,
            displayName: entry.displayName,
            fileURL: resolveSourceURL(entry),
            unsavedSnapshot: snapshot ?? entry.legacySnapshot,
            draftFilename: entry.draftFilename,
            closedAt: entry.closedAt
        )
        remove(entry.id)
        return hydrated
    }

    func remove(_ id: UUID) {
        let removed = records.filter { $0.id == id }
        records.removeAll { $0.id == id }
        removed.forEach(removePayload)
        save()
    }

    func clear() {
        records.forEach(removePayload)
        records.removeAll()
        save()
    }

    func resolveSourceURL(_ record: ClosedTabRecord) -> URL? {
        if let legacy = record.legacyFileURL { return legacy }
        guard let bookmark = record.sourceBookmark else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    func loadSnapshot(_ record: ClosedTabRecord) async throws -> String? {
        if let legacy = record.legacySnapshot { return legacy }
        guard let filename = record.snapshotFilename else { return nil }
        let url = storageDirectory.appendingPathComponent(filename)
        return try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ClosedTabsFailure.snapshotMissing
            }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw DraftRecoveryFailure.invalidUTF8
                }
                return text
            } catch let error as ClosedTabsFailure {
                throw error
            } catch {
                throw ClosedTabsFailure.snapshotUnreadable(error)
            }
        }.value
    }

    private func normalize(_ entry: ClosedTabRecord) throws -> ClosedTabRecord {
        if entry.legacyFileURL == nil,
           entry.legacySnapshot == nil {
            return entry
        }

        let bookmark: Data?
        if let source = entry.legacyFileURL {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            bookmark = try? source.bookmarkData()
        } else {
            bookmark = entry.sourceBookmark
        }

        var filename = entry.snapshotFilename
        if let snapshot = entry.legacySnapshot {
            filename = "\(entry.id.uuidString).txt"
            let url = storageDirectory.appendingPathComponent(filename!)
            do {
                try Data(snapshot.utf8).write(to: url, options: .atomic)
            } catch {
                throw ClosedTabsFailure.snapshotWriteFailed(error)
            }
        }

        // A clean file with an unbookmarkable URL cannot be restored. Dirty
        // content still remains valuable as an untitled snapshot.
        guard bookmark != nil || filename != nil else {
            throw ClosedTabsFailure.snapshotMissing
        }
        return ClosedTabRecord(
            id: entry.id,
            displayName: entry.displayName,
            sourceBookmark: bookmark,
            snapshotFilename: filename,
            draftFilename: entry.draftFilename,
            closedAt: entry.closedAt
        )
    }

    private func migrateLegacyRecords() {
        for index in records.indices {
            guard records[index].legacyFileURL != nil || records[index].legacySnapshot != nil else {
                continue
            }
            if let normalized = try? normalize(records[index]) {
                records[index] = normalized
            }
        }
    }

    private func enforceLimits() {
        while records.count > Self.cap || storedByteCount > Self.maxStoredBytes {
            guard let removed = records.popLast() else { break }
            removePayload(removed)
        }
    }

    private var storedByteCount: Int {
        records.reduce(into: 0) { total, record in
            guard let filename = record.snapshotFilename else { return }
            let url = storageDirectory.appendingPathComponent(filename)
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
    }

    private func loadSnapshotSynchronously(_ record: ClosedTabRecord) throws -> String? {
        if let legacy = record.legacySnapshot { return legacy }
        guard let filename = record.snapshotFilename else { return nil }
        let data = try Data(contentsOf: storageDirectory.appendingPathComponent(filename))
        guard let text = String(data: data, encoding: .utf8) else {
            throw DraftRecoveryFailure.invalidUTF8
        }
        return text
    }

    private func removePayload(_ record: ClosedTabRecord) {
        guard let filename = record.snapshotFilename else { return }
        try? FileManager.default.removeItem(
            at: storageDirectory.appendingPathComponent(filename)
        )
    }

    private func removeOrphanedPayloads() {
        let referenced = Set(records.compactMap(\.snapshotFilename))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "txt"
            && !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: AppPreferenceKey.closedTabRecords)
    }

    private static func load(from defaults: UserDefaults) -> [ClosedTabRecord]? {
        guard let data = defaults.data(forKey: AppPreferenceKey.closedTabRecords),
              let decoded = try? JSONDecoder().decode([ClosedTabRecord].self, from: data)
        else { return nil }
        return decoded
    }

    private static func defaultStorageDirectory() -> URL {
        let manager = FileManager.default
        let base = (try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? manager.temporaryDirectory
        return base.appendingPathComponent("ClosedTabs", isDirectory: true)
    }
}
