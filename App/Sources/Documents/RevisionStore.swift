import Foundation
import CryptoKit

/// Bounded per-document snapshot history stored in Application Support.
actor RevisionStore {

    static let shared = RevisionStore()

    /// Per-file cap, excluding the original snapshot.
    let maxRevisions: Int
    /// Consecutive automatic revisions inside this window coalesce.
    let autoCoalesceWindow: TimeInterval
    let maxSnapshotBytes: Int
    let maxBytesPerDocument: Int
    let maxTotalBytes: Int

    /// Tests pass an isolated temp directory; production leaves it nil
    /// and we resolve through `applicationSupportDirectory`.
    private let supportDirOverride: URL?

    init(
        supportDirOverride: URL? = nil,
        maxRevisions: Int = 50,
        autoCoalesceWindow: TimeInterval = 60,
        maxSnapshotBytes: Int = 8 * 1_024 * 1_024,
        maxBytesPerDocument: Int = 50 * 1_024 * 1_024,
        maxTotalBytes: Int = 500 * 1_024 * 1_024
    ) {
        self.supportDirOverride = supportDirOverride
        self.maxRevisions = maxRevisions
        self.autoCoalesceWindow = autoCoalesceWindow
        self.maxSnapshotBytes = max(0, maxSnapshotBytes)
        self.maxBytesPerDocument = max(0, maxBytesPerDocument)
        self.maxTotalBytes = max(0, maxTotalBytes)
    }

    enum Kind: String, Codable, Sendable {
        case original
        case auto
        case manual
    }

    enum Failure: LocalizedError {
        case directoryCreateFailed(URL, any Error)
        case snapshotWriteFailed(URL, any Error)
        case manifestWriteFailed(URL, any Error)

        var errorDescription: String? {
            switch self {
            case .directoryCreateFailed(let url, let err):
                return "Couldn't create revisions folder at \(url.lastPathComponent): \(err.localizedDescription)"
            case .snapshotWriteFailed(let url, let err):
                return "Couldn't write revision snapshot \(url.lastPathComponent): \(err.localizedDescription)"
            case .manifestWriteFailed(let url, let err):
                return "Couldn't write revision manifest \(url.lastPathComponent): \(err.localizedDescription)"
            }
        }
    }

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let index: Int
        let timestamp: Date
        let kind: Kind
        let byteSize: Int
        let preview: String

        init(
            id: UUID = UUID(),
            index: Int,
            timestamp: Date = Date(),
            kind: Kind,
            byteSize: Int,
            preview: String
        ) {
            self.id = id
            self.index = index
            self.timestamp = timestamp
            self.kind = kind
            self.byteSize = byteSize
            self.preview = preview
        }
    }

    private struct Manifest: Codable {
        var entries: [Entry]
        var nextIndex: Int

        static let empty = Manifest(entries: [], nextIndex: 0)
    }

    // MARK: - Public API

    /// Compute the on-disk key for a URL. Used by saved docs so a
    /// reopen of the same file finds its history.
    nonisolated static func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "url-\(hex)"
    }

    /// Untitled docs use a per-tab UUID so revisions follow the tab
    /// across its lifetime even before the user picks a save location.
    nonisolated static func keyForUntitledTab(_ uuid: UUID) -> String {
        "tab-\(uuid.uuidString)"
    }

    func entries(forKey key: String) -> [Entry] {
        loadManifest(forKey: key).entries.sorted { $0.timestamp < $1.timestamp }
    }

    /// Capture the file's on-disk state when opened. No-op if an
    /// original already exists for this key (so a re-open doesn't
    /// overwrite the anchor). Returns the new entry, `nil` if the
    /// anchor was already present.
    @discardableResult
    func recordOriginalIfNeeded(_ text: String, forKey key: String) throws -> Entry? {
        var manifest = loadManifest(forKey: key)
        if manifest.entries.contains(where: { $0.kind == .original }) { return nil }
        return try appendEntry(text: text, kind: .original, manifest: &manifest, key: key)
    }

    /// Append a new revision. Auto revisions within the coalesce
    /// window collapse onto the previous auto entry instead of
    /// adding a new one.
    @discardableResult
    func recordRevision(_ text: String, kind: Kind, forKey key: String) throws -> Entry? {
        precondition(kind != .original, "Use recordOriginalIfNeeded for the original snapshot.")
        var manifest = loadManifest(forKey: key)

        // Coalesce consecutive auto revisions.
        if kind == .auto,
           let last = manifest.entries.last,
           last.kind == .auto,
           Date().timeIntervalSince(last.timestamp) < autoCoalesceWindow {
            return try replaceEntry(at: last.index, text: text, kind: .auto, manifest: &manifest, key: key)
        }

        return try appendEntry(text: text, kind: kind, manifest: &manifest, key: key)
    }

    /// Load a revision's full text. Returns nil if the snapshot file
    /// is missing (manual sandbox cleanup, disk corruption, etc.).
    func loadText(of entry: Entry, forKey key: String) -> String? {
        let snapshotURL = snapshotsDirectory(forKey: key).appendingPathComponent("\(entry.index).bin")
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Wipe every revision for a key — used when the user
    /// permanently disowns the history for a file/tab.
    func clearAll(forKey key: String) {
        try? FileManager.default.removeItem(at: directory(forKey: key))
    }

    // MARK: - Internals

    private func appendEntry(text: String, kind: Kind, manifest: inout Manifest, key: String) throws -> Entry? {
        let data = Data(text.utf8)
        guard data.count <= maxSnapshotBytes else { return nil }
        let dir = snapshotsDirectory(forKey: key)
        try ensureDirectory(at: dir)
        let index = manifest.nextIndex
        let snapshotURL = dir.appendingPathComponent("\(index).bin")
        do {
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            throw Failure.snapshotWriteFailed(snapshotURL, error)
        }
        let entry = Entry(
            index: index,
            kind: kind,
            byteSize: data.count,
            preview: makePreview(from: text)
        )
        manifest.entries.append(entry)
        manifest.nextIndex += 1
        evictIfNeeded(&manifest, key: key)
        try saveManifest(manifest, forKey: key)
        enforceGlobalLimit()
        return entry
    }

    private func replaceEntry(at index: Int, text: String, kind: Kind, manifest: inout Manifest, key: String) throws -> Entry? {
        guard let i = manifest.entries.firstIndex(where: { $0.index == index }) else {
            // Coalesce target vanished — fall through and treat this
            // as a normal append rather than failing the caller.
            return try appendEntry(text: text, kind: kind, manifest: &manifest, key: key)
        }
        let dir = snapshotsDirectory(forKey: key)
        let data = Data(text.utf8)
        guard data.count <= maxSnapshotBytes else { return nil }
        let snapshotURL = dir.appendingPathComponent("\(index).bin")
        do {
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            throw Failure.snapshotWriteFailed(snapshotURL, error)
        }
        let updated = Entry(
            id: manifest.entries[i].id,
            index: index,
            timestamp: Date(),
            kind: kind,
            byteSize: data.count,
            preview: makePreview(from: text)
        )
        manifest.entries[i] = updated
        evictIfNeeded(&manifest, key: key)
        try saveManifest(manifest, forKey: key)
        enforceGlobalLimit()
        return updated
    }

    private func evictIfNeeded(_ manifest: inout Manifest, key: String) {
        let dir = snapshotsDirectory(forKey: key)
        // Always keep the original. Cap counts the *non-original* tail.
        var nonOriginal = manifest.entries.filter { $0.kind != .original }
        nonOriginal.sort { $0.timestamp < $1.timestamp }
        var byteCount = manifest.entries.reduce(0) { $0 + $1.byteSize }
        while nonOriginal.count > maxRevisions || byteCount > maxBytesPerDocument,
              let entry = nonOriginal.first {
            nonOriginal.removeFirst()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(entry.index).bin"))
            if let idx = manifest.entries.firstIndex(where: { $0.id == entry.id }) {
                manifest.entries.remove(at: idx)
            }
            byteCount -= entry.byteSize
        }
    }

    private struct EvictionCandidate {
        let key: String
        let entry: Entry
        let bytes: Int
    }

    private struct GlobalUsage {
        var manifests: [String: Manifest] = [:]
        var totalBytes = 0
        var candidates: [EvictionCandidate] = []
    }

    private func enforceGlobalLimit() {
        var usage = collectGlobalUsage()
        guard usage.totalBytes > maxTotalBytes else { return }

        evictNonOriginals(from: &usage)
        guard usage.totalBytes > maxTotalBytes else { return }
        evictOldestHistories(from: &usage)
    }

    private func collectGlobalUsage() -> GlobalUsage {
        let manager = FileManager.default
        let directories = (try? manager.contentsOfDirectory(
            at: revisionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var usage = GlobalUsage()

        for directory in directories {
            let key = directory.lastPathComponent
            let manifest = reconcileManifest(in: directory, key: key, manager: manager)
            usage.manifests[key] = manifest
            for entry in manifest.entries {
                let snapshot = directory.appendingPathComponent("\(entry.index).bin")
                let bytes = (try? snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    ?? entry.byteSize
                usage.totalBytes += bytes
                if entry.kind != .original {
                    usage.candidates.append(EvictionCandidate(
                        key: key,
                        entry: entry,
                        bytes: bytes
                    ))
                }
            }
        }
        return usage
    }

    private func reconcileManifest(
        in directory: URL,
        key: String,
        manager: FileManager
    ) -> Manifest {
        var manifest = loadManifest(forKey: key)
        let snapshotFiles = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "bin" } ?? []
        let existingNames = Set(snapshotFiles.map(\.lastPathComponent))
        let knownNames = Set(manifest.entries.map { "\($0.index).bin" })

        for orphan in snapshotFiles where !knownNames.contains(orphan.lastPathComponent) {
            try? manager.removeItem(at: orphan)
        }
        let previousCount = manifest.entries.count
        manifest.entries.removeAll { !existingNames.contains("\($0.index).bin") }
        if manifest.entries.count != previousCount {
            try? saveManifest(manifest, forKey: key)
        }
        return manifest
    }

    private func evictNonOriginals(from usage: inout GlobalUsage) {
        usage.candidates.sort { $0.entry.timestamp < $1.entry.timestamp }
        for candidate in usage.candidates where usage.totalBytes > maxTotalBytes {
            guard var manifest = usage.manifests[candidate.key],
                  let index = manifest.entries.firstIndex(where: { $0.id == candidate.entry.id })
            else { continue }
            try? FileManager.default.removeItem(
                at: snapshotsDirectory(forKey: candidate.key)
                    .appendingPathComponent("\(candidate.entry.index).bin")
            )
            manifest.entries.remove(at: index)
            usage.manifests[candidate.key] = manifest
            usage.totalBytes -= candidate.bytes
            try? saveManifest(manifest, forKey: candidate.key)
        }
    }

    private func evictOldestHistories(from usage: inout GlobalUsage) {
        let histories = usage.manifests.map { key, manifest in
            (
                key: key,
                latest: manifest.entries.map(\.timestamp).max() ?? .distantPast,
                bytes: manifest.entries.reduce(0) { $0 + $1.byteSize }
            )
        }
        .sorted { $0.latest < $1.latest }
        for history in histories where usage.totalBytes > maxTotalBytes {
            try? FileManager.default.removeItem(at: directory(forKey: history.key))
            usage.totalBytes -= history.bytes
        }
    }

    /// Builds a bounded single-line preview without scanning a large buffer.
    private func makePreview(from text: String) -> String {
        var out = ""
        out.reserveCapacity(Self.previewCharLimit)
        for scalar in text.unicodeScalars {
            if out.count >= Self.previewCharLimit {
                let trimmed = out.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? "" : trimmed + "…"
            }
            if scalar == "\n" || scalar == "\r" {
                out.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let previewCharLimit = 80

    // MARK: - Filesystem layout

    private func directory(forKey key: String) -> URL {
        revisionsRoot.appendingPathComponent(key)
    }

    private func snapshotsDirectory(forKey key: String) -> URL {
        directory(forKey: key)
    }

    private func manifestURL(forKey key: String) -> URL {
        directory(forKey: key).appendingPathComponent("meta.json")
    }

    private var revisionsRoot: URL {
        if let supportDirOverride {
            return supportDirOverride.appendingPathComponent("Revisions", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Pilcrow/Revisions", isDirectory: true)
    }

    private func ensureDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw Failure.directoryCreateFailed(url, error)
        }
    }

    private func loadManifest(forKey key: String) -> Manifest {
        let path = manifestURL(forKey: key)
        guard let data = try? Data(contentsOf: path) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            return .empty
        }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest, forKey key: String) throws {
        let path = manifestURL(forKey: key)
        try ensureDirectory(at: path.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: path, options: .atomic)
        } catch {
            throw Failure.manifestWriteFailed(path, error)
        }
    }
}
