import SwiftUI
import UniformTypeIdentifiers
import FileEncoding
import LineEnding

/// Document model for one open buffer.
///
/// The editor owns its live buffers and local recovery separately from
/// source files. File-provider access is coordinated; opening and saving
/// publish model changes only after their filesystem operation succeeds.
@MainActor
@Observable
final class PlainTextDocument {

    /// Debounced snapshot of the buffer. The engine's `TextView` owns
    /// the live text — read from there when freshness matters (save,
    /// transforms, snippet inserts). This lags by ~300 ms but lets
    /// SwiftUI observers (status-bar counts, markdown preview) update
    /// without paying the per-keystroke cost.
    var text: String = ""

    /// Bumped on every edit. Observers that just need "something
    /// changed" (recovery checkpoints, change-history overlay) watch
    /// this instead of `text` to avoid invalidating the full buffer.
    var bufferRevision: UInt64 = 0

    var fileEncoding: FileEncoding
    var lineEnding: LineEnding
    var fileURL: URL?

    /// Per-document key for `RevisionStore`. UUID-based for untitled
    /// buffers, URL-hash-based once saved.
    var revisionKey: String

    /// Stable identity for this buffer's local crash shadow. It is separate
    /// from `revisionKey` so two windows editing the same URL cannot clobber
    /// each other's unsaved snapshots.
    private let scratchID = UUID()
    var scratchFilename: String { "\(scratchID.uuidString).txt" }
    private let scratchWriter = ScratchWriter()
    private var scratchGeneration: UInt64 = 0
    private var recoveryGeneration: UInt64 = 0
    private var pendingRecoveryWrite: (id: UUID, task: Task<Bool, any Error>)?
    private var revisionTask: Task<Void, Never>?

    /// Stays visible in this document until recovery succeeds or the
    /// buffer is saved/discarded. Repeated failures never stack alerts.
    private(set) var recoveryError: String?

    var externalChangeMessage: String?
    var isDirty: Bool = false
    /// Raw bytes from the last load — kept so the encoding picker can
    /// re-decode with a different encoding without re-reading disk.
    var originalData: Data?
    private(set) var loadTask: Task<Void, Never>?
    private(set) var loadGeneration: UInt64 = 0
    var isLoading: Bool { loadTask != nil }
    var isSaving: Bool = false

    /// Device-local recovery snapshot URL. Set on the first committed
    /// autosave of a dirty doc; cleared on Save-As / Discard.
    var draftURL: URL?

    /// Every filename by which the recovery catalog could recognize this
    /// live buffer. Before the first lifecycle commit there may be only a
    /// scratch shadow; afterward that shadow points at `draftURL`. Excluding
    /// both prevents another window from offering work that is still open.
    var liveRecoveryFilenames: Set<String> {
        var filenames = Set([scratchFilename])
        if let draftURL {
            filenames.insert(draftURL.lastPathComponent)
        }
        return filenames
    }

    /// Monotonic per-launch tag so a window full of fresh "Untitled"
    /// tabs picks up distinct titles ("Untitled", "Untitled 2", …)
    /// — same scheme TextEdit uses. Stays the same after the doc is
    /// saved (becomes irrelevant once `fileURL` is set); numbers
    /// aren't recycled when a tab closes.
    let untitledNumber: Int

    private static var untitledCounter: Int = 0
    private static func nextUntitledNumber() -> Int {
        untitledCounter += 1
        return untitledCounter
    }

    init() {
        self.fileEncoding = Self.defaultFileEncoding()
        self.lineEnding = Self.defaultLineEnding()
        self.revisionKey = RevisionStore.keyForUntitledTab(UUID())
        self.untitledNumber = Self.nextUntitledNumber()
    }

    /// Window/tab pill title. Untitled docs read "Untitled" (n=1)
    /// or "Untitled N" so multiple Untitled windows are visually
    /// distinct in Stage Manager / the App Switcher.
    var displayName: String {
        if let url = fileURL { return url.lastPathComponent }
        return untitledNumber == 1 ? "Untitled" : "Untitled \(untitledNumber)"
    }

    /// Source attributes used to detect changes when restoring recovery.
    /// Explicit saves compare the original bytes inside file coordination.
    var sourceMtimeAtLoad: Date?
    var sourceSizeAtLoad: Int?

    // Internal (not private) so encoding-detection unit tests can
    // exercise it without touching disk or the revision store.
    nonisolated static func decodePayload(from data: Data) throws -> LoadPayload {
        if data.isEmpty {
            return LoadPayload(data: data, text: "", encoding: FileEncoding(encoding: .utf8))
        }
        if data.count > hardSizeCap {
            throw DocumentError.fileTooLarge(bytes: data.count)
        }
        // UTF-16/32 text is full of NUL bytes by construction; a Unicode
        // BOM marks the data as text, so the binary heuristic must only
        // apply to BOM-less data. FF FE also covers UTF-32LE (FF FE 00 00).
        let hasUnicodeBOM = data.starts(with: [0xFF, 0xFE])
            || data.starts(with: [0xFE, 0xFF])
            || data.starts(with: [0x00, 0x00, 0xFE, 0xFF])
        if !hasUnicodeBOM, data.prefix(8192).contains(0) {
            throw DocumentError.binaryFile
        }
        let options = String.DetectionOptions(
            candidates: Self.candidateEncodings,
            xattrEncoding: nil,
            considersDeclaration: true
        )
        do {
            let (decoded, encoding) = try String.string(
                data: data,
                decodingStrategy: .automatic(options)
            )
            return LoadPayload(data: data, text: decoded, encoding: encoding)
        } catch {
            // Never substitute an empty buffer here — with fileURL set
            // and isDirty false, a later ⌘S would truncate the file.
            throw DocumentError.undecodable
        }
    }

    /// Owns loading for opens, session restoration, and explicit draft recovery.
    /// A cancelled or superseded task cannot clear a replacement's handle.
    @discardableResult
    func startLoad(
        onFinish: (@MainActor () -> Void)? = nil,
        _ operation: @escaping @MainActor (UInt64) async -> Void
    ) -> Task<Void, Never> {
        invalidateLoad()
        let generation = loadGeneration
        let task = Task { @MainActor [weak self] in
            await operation(generation)
            if let self, self.loadGeneration == generation {
                self.loadTask = nil
                onFinish?()
            }
        }
        loadTask = task
        return task
    }

    func invalidateLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    func applyPayload(_ payload: LoadPayload, url: URL) {
        externalChangeMessage = nil
        self.text = payload.text
        self.fileEncoding = payload.encoding
        self.originalData = payload.data
        self.lineEnding = Self.detectLineEnding(in: payload.text) ?? .lf
        let sourceURL = payload.sourceURL ?? url
        self.fileURL = sourceURL
        self.isDirty = false
        // Capture the disk snapshot now so the stale-source check
        // on save can spot concurrent writes from other apps /
        // devices.
        self.sourceMtimeAtLoad = payload.modificationDate
        self.sourceSizeAtLoad = payload.data.count
        // Reopening a source uses its existing revision history.
        self.revisionKey = RevisionStore.key(for: sourceURL)
        // Seed an "original on open" revision once per URL so a
        // later Revert-to-Original has an anchor. Best-effort — a
        // sandbox write failure doesn't fail the document load.
        scheduleRevisionRecording(original: payload.text, key: revisionKey)
    }

    /// Re-decodes the exact bytes captured at load time. Mutations happen only
    /// after decoding succeeds, so a failed command leaves both the visible
    /// buffer and its future save encoding unchanged.
    @discardableResult
    func reinterpretOriginalData(as requested: FileEncoding) throws -> String {
        guard let originalData else { throw DocumentError.noOriginalData }
        let (decoded, resolved) = try String.string(
            data: originalData,
            decodingStrategy: .specific(requested.encoding)
        )
        text = decoded
        fileEncoding = FileEncoding(
            encoding: resolved.encoding,
            withUTF8BOM: requested.withUTF8BOM
        )
        return decoded
    }

    struct LoadPayload: Sendable {
        let data: Data
        let text: String
        let encoding: FileEncoding
        var sourceURL: URL?
        var modificationDate: Date?
    }

    nonisolated static func readPayload(from url: URL) async throws -> LoadPayload {
        try await CoordinatedFileAccess.perform(at: url) { coordinatedURL in
            let attributes = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let size = attributes.fileSize, size > hardSizeCap {
                throw DocumentError.fileTooLarge(bytes: size)
            }
            var payload = try decodePayload(from: Data(contentsOf: coordinatedURL))
            payload.sourceURL = coordinatedURL
            payload.modificationDate = attributes.contentModificationDate
            return payload
        }
    }

    struct SavedSnapshot: Sendable {
        let url: URL
        let inputText: String
        let text: String
        let data: Data
        let encoding: FileEncoding
        let lineEnding: LineEnding
        let modificationDate: Date?
    }

    /// Write a captured buffer without adopting it. The owning workflow
    /// reconciles completion with any edits made while access was pending.
    func writeSnapshot(to url: URL, text input: String, overwrite: Bool = false) async throws -> SavedSnapshot {
        let settings = saveSettings
        let isCurrentSource = fileURL?.standardizedFileURL == url.standardizedFileURL
        let expected = originalData
        return try await CoordinatedFileAccess.perform(at: url, writing: true) { destination in
            if !overwrite {
                if isCurrentSource {
                    guard let expected, try Data(contentsOf: destination) == expected else {
                        throw DocumentError.sourceChanged
                    }
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            let (savedText, data) = try settings.prepare(input)
            try data.write(to: destination, options: .atomic)
            let date = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return SavedSnapshot(url: destination, inputText: input, text: savedText, data: data,
                encoding: settings.encoding, lineEnding: settings.lineEnding, modificationDate: date)
        }
    }

    /// Commit model state after either an atomic save or a successful
    /// SwiftUI export. No document bookkeeping happens before the write.
    /// `currentText` may differ from `savedText` if an external keyboard
    /// edit landed while the picker was dismissing. In that rare case the
    /// exported snapshot becomes the disk baseline and the newer buffer
    /// stays dirty and immediately gets a fresh recovery draft.
    func finishExternalSave(
        to url: URL,
        savedText: String,
        savedData: Data,
        currentText: String,
        modificationDate: Date?
    ) {
        deleteScratchFile()

        fileURL = url
        externalChangeMessage = nil
        originalData = savedData
        revisionKey = RevisionStore.key(for: url)
        text = currentText
        isDirty = currentText != savedText
        sourceMtimeAtLoad = modificationDate
        sourceSizeAtLoad = savedData.count

        scheduleRevisionRecording(
            original: savedText,
            revision: (savedText, .manual),
            key: revisionKey
        )

        if isDirty {
            autoSave()
            let generation = recoveryGeneration
            let write = scheduleRecoveryWrite()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.refreshScratch(after: write, generation: generation)
                } catch {
                    AppStateBus.shared.presentation.openErrorMessage =
                        "Couldn't update the recovery draft for \(self.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    /// Writes an exact UTF-8 scratch copy without changing the source file.
    @discardableResult
    func autoSave() -> Task<Void, Never> {
        let snapshot = text
        let key = revisionKey
        scratchGeneration &+= 1
        let generation = scratchGeneration
        scratchWriter.noteLatestWrite(generation)
        let sidecar = ScratchSidecar(
            id: scratchID,
            revisionKey: key,
            draftFilename: draftURL?.lastPathComponent,
            metadata: makeDraftMetadata()
        )
        let task = Task(priority: .utility) { [weak self, scratchWriter] in
            // Scratch is exact UTF-8 buffer state. Save-time whitespace,
            // newline, BOM, and encoding preferences must never alter a
            // crash-recovery copy.
            let failure: String?
            do {
                try await scratchWriter.write(
                    text: snapshot,
                    sidecar: sidecar,
                    generation: generation
                )
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            guard let self, self.scratchGeneration == generation else { return }
            self.recoveryError = failure
        }
        scheduleRevisionRecording(revision: (snapshot, .auto), key: key)
        return task
    }

    /// Serializes checkpoints for this buffer. Discard invalidates queued
    /// writes. Any later write waits for an in-flight write to clean up.
    func scheduleRecoveryWrite() -> Task<Bool, any Error> {
        let generation = recoveryGeneration
        let writeID = UUID()
        let previous = pendingRecoveryWrite?.task
        let snapshot = text
        let shouldWrite = !snapshot.isEmpty || (fileURL != nil && isDirty)
        let metadata = shouldWrite ? makeDraftMetadata() : nil
        let write = Task { @MainActor in
            defer {
                if pendingRecoveryWrite?.id == writeID {
                    pendingRecoveryWrite = nil
                }
            }
            _ = await previous?.result
            guard generation == recoveryGeneration else { return false }
            if !shouldWrite {
                DraftsStore.shared.discard(draftURL)
                draftURL = nil
                return true
            }
            let savedURL = try await DraftsStore.shared.save(
                text: snapshot, existing: draftURL, metadata: metadata
            )
            guard generation == recoveryGeneration else {
                DraftsStore.shared.discard(savedURL)
                return false
            }
            draftURL = savedURL
            return true
        }
        pendingRecoveryWrite = (writeID, write)
        return write
    }

    /// Commits recovery before lifecycle bookkeeping and refreshes its scratch reference.
    func commitRecoverySnapshot() async throws {
        try Task.checkCancellation()
        let generation = recoveryGeneration
        try await refreshScratch(after: scheduleRecoveryWrite(), generation: generation)
    }

    private func refreshScratch(after write: Task<Bool, any Error>, generation: UInt64) async throws {
        let result = await write.result
        guard generation == recoveryGeneration, try result.get(), isDirty else { return }
        autoSave()
    }

    /// Throw away the scratch shadow and draft for this doc — called
    /// by the Discard close path.
    func deleteScratchFile() {
        recoveryGeneration &+= 1
        deleteScratchOnly()
        if let draftURL {
            DraftsStore.shared.discard(draftURL)
            DraftsStore.shared.discardAllCopies(named: draftURL.lastPathComponent)
        }
        draftURL = nil
    }

    /// Last 2-3 path components joined with " / " for the recovery
    /// sheet's row subtitle.
    nonisolated static func displayPath(for url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count <= 2 { return url.path }
        return parts.suffix(3).joined(separator: " / ")
    }

    // MARK: - Recovery metadata and scratch storage

    private func makeDraftMetadata() -> DraftMetadata? {
        guard let source = fileURL else { return nil }
        // Bookmark under an active security scope — without it,
        // file-provider URLs can silently lose their source link.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        return DraftMetadata(
            sourceBookmark: try? source.bookmarkData(),
            sourceDisplay: Self.displayPath(for: source),
            sourceEncodingRaw: fileEncoding.encoding.rawValue,
            sourceMtime: sourceMtimeAtLoad,
            sourceSize: sourceSizeAtLoad,
            sourceHadUTF8BOM: fileEncoding.withUTF8BOM
        )
    }

    private func deleteScratchOnly() {
        recoveryError = nil
        scratchGeneration &+= 1
        let generation = scratchGeneration
        scratchWriter.noteLatestDiscard(generation)
        // Remove immediately for synchronous Save/Discard semantics, then
        // invalidate any older queued writer operation on its own actor.
        ScratchStore.discard(id: scratchID)
        Task(priority: .utility) {
            await scratchWriter.discard(id: scratchID, generation: generation)
        }
    }

    /// Revision I/O is serialized on a background actor. Save/load success
    /// never depends on this convenience history, but failures still surface.
    private func scheduleRevisionRecording(
        original: String? = nil,
        revision: (text: String, kind: RevisionStore.Kind)? = nil,
        key: String
    ) {
        let previous = revisionTask
        revisionTask = Task(priority: .utility) {
            await previous?.value
            do {
                if let original {
                    _ = try await RevisionStore.shared.recordOriginalIfNeeded(
                        original,
                        forKey: key
                    )
                }
                if let revision {
                    _ = try await RevisionStore.shared.recordRevision(
                        revision.text,
                        kind: revision.kind,
                        forKey: key
                    )
                }
            } catch {
                AppStateBus.shared.presentation.openErrorMessage = error.localizedDescription
            }
        }
    }

    struct SaveSettings: Sendable {
        let encoding: FileEncoding
        let lineEnding: LineEnding
        let trimTrailingWhitespace: Bool
        let ensureTrailingNewline: Bool
        let saveUTF8BOM: Bool

        nonisolated func prepare(_ source: String) throws -> (text: String, data: Data) {
            let text = PlainTextDocument.prepareTextForSaving(source, lineEnding: lineEnding,
                trimTrailingWhitespace: trimTrailingWhitespace, ensureTrailingNewline: ensureTrailingNewline)
            let data = try PlainTextDocument.encodePreparedText(text, encoding: encoding, saveUTF8BOM: saveUTF8BOM)
            return (text, data)
        }
    }

    var saveSettings: SaveSettings {
        let defaults = UserDefaults.standard
        return SaveSettings(encoding: fileEncoding, lineEnding: lineEnding,
            trimTrailingWhitespace: defaults.bool(forKey: AppPreferenceKey.trimTrailingWhitespaceOnSave),
            ensureTrailingNewline: defaults.bool(forKey: AppPreferenceKey.ensureTrailingNewline),
            saveUTF8BOM: defaults.bool(forKey: AppPreferenceKey.saveUTF8BOM))
    }

    nonisolated static func prepareTextForSaving(
        _ text: String,
        lineEnding: LineEnding,
        trimTrailingWhitespace: Bool,
        ensureTrailingNewline: Bool
    ) -> String {
        var output = text
        if trimTrailingWhitespace {
            output = trimmingTrailingWhitespace(from: output)
        }
        output = output.replacingLineEndings(with: lineEnding)
        if ensureTrailingNewline, !output.hasSuffix(lineEnding.string) {
            output += lineEnding.string
        }
        return output
    }

    nonisolated static func encode(
        text: String,
        encoding: FileEncoding,
        lineEnding: LineEnding,
        trimTrailingWhitespace: Bool,
        ensureTrailingNewline: Bool,
        saveUTF8BOMPref: Bool
    ) throws -> Data {
        let output = prepareTextForSaving(
            text,
            lineEnding: lineEnding,
            trimTrailingWhitespace: trimTrailingWhitespace,
            ensureTrailingNewline: ensureTrailingNewline
        )
        return try encodePreparedText(output, encoding: encoding, saveUTF8BOM: saveUTF8BOMPref)
    }

    nonisolated private static func encodePreparedText(
        _ text: String, encoding: FileEncoding, saveUTF8BOM: Bool
    ) throws -> Data {
        let rawEncoding = encoding.encoding
        guard var data = text.data(using: rawEncoding, allowLossyConversion: false) else {
            throw CocoaError(
                .fileWriteInapplicableStringEncoding,
                userInfo: [NSStringEncodingErrorKey: rawEncoding.rawValue]
            )
        }
        if rawEncoding == .utf8, encoding.withUTF8BOM || saveUTF8BOM {
            var prefixed = Data([0xEF, 0xBB, 0xBF])
            prefixed.append(data)
            data = prefixed
        }
        return data
    }

    // MARK: - Helpers

    enum DocumentError: LocalizedError {
        case noFileURL
        case noOriginalData
        case sourceChanged
        case saveInProgress
        case fileTooLarge(bytes: Int)
        case binaryFile
        case undecodable
        var errorDescription: String? {
            switch self {
            case .noFileURL:
                return "Save the document first before using Save."
            case .sourceChanged:
                return "The source file changed after it was opened. Reload it or choose Save Anyway."
            case .saveInProgress:
                return "This document is already being saved."
            case .noOriginalData:
                return "There are no original file bytes to reinterpret."
            case .fileTooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                let capMB = Double(PlainTextDocument.hardSizeCap) / 1_048_576
                return String(
                    format: "This file is %.1f MB. Files over %.0f MB can't be opened in this editor on iPad — the engine's initial parse would freeze the app. Try splitting the file or using a desktop editor.",
                    mb, capMB
                )
            case .binaryFile:
                return "This file looks like a binary (it contains NUL bytes). The text editor can only open plain-text files."
            case .undecodable:
                return "This file couldn't be decoded with any supported text encoding."
            }
        }
    }

    /// Hard ceiling above which the editor refuses to open a file.
    /// Below this, the user's `SyntaxLimit` choice gates syntax /
    /// fold / decorator work; above it, even plain-text mode would
    /// freeze the UI during the engine's line-manager init.
    nonisolated static let hardSizeCap: Int = 100 * 1024 * 1024  // 100 MB

    /// File picker / Recents are gated on these types so the user
    /// only sees files Pilcrow can actually open. Dropping `.data`
    /// removes the over-broad fallback — it matches every file. Add
    /// custom UTIs (markdown / TeX / Typst) when registered.
    static let supportedReadTypes: [UTType] = {
        var types: [UTType] = [
            .plainText, .utf8PlainText, .utf16PlainText, .sourceCode, .text,
            .delimitedText, .commaSeparatedText, .tabSeparatedText,
            .yaml, .json, .xml, .html
        ]
        for identifier in ["net.daringfireball.markdown", "org.tug.tex", "app.typst.typst"] {
            if let custom = UTType(identifier) { types.append(custom) }
        }
        return types
    }()
    nonisolated static let candidateEncodings: [String.Encoding] = [
        .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32,
        .windowsCP1252, .isoLatin1, .isoLatin2, .macOSRoman,
        .shiftJIS, .japaneseEUC, .iso2022JP
    ]

    nonisolated static func detectLineEnding(in string: String) -> LineEnding? {
        switch TextMetrics.firstLineEnding(in: string as NSString) {
        case .lf?:   return .lf
        case .cr?:   return .cr
        case .crlf?: return .crlf
        case nil:    return nil
        }
    }

    static func defaultFileEncoding() -> FileEncoding {
        let raw = UInt(UserDefaults.standard.integer(forKey: AppPreferenceKey.defaultEncodingRaw))
        let encoding = String.Encoding(rawValue: raw == 0 ? String.Encoding.utf8.rawValue : raw)
        return FileEncoding(encoding: encoding)
    }

    static func defaultLineEnding() -> LineEnding {
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.defaultLineEndingRaw) ?? "\n"
        return LineEnding(rawValue: raw.first ?? "\n") ?? .lf
    }

    /// Operates on Unicode scalars because Swift treats `\r\n` as a
    /// single extended grapheme cluster — the prior Character-level
    /// split silently failed on CRLF buffers.
    nonisolated private static func trimmingTrailingWhitespace(from input: String) -> String {
        var output = ""
        output.reserveCapacity(input.unicodeScalars.count)
        var line = ""
        line.reserveCapacity(80)
        func flushLine() {
            while let last = line.unicodeScalars.last, last == " " || last == "\t" {
                line.unicodeScalars.removeLast()
            }
            output.append(line)
            line.removeAll(keepingCapacity: true)
        }
        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\r" {
                flushLine()
                output.append("\n")
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 2 } else { i += 1 }
            } else if s == "\n" {
                flushLine()
                output.append("\n")
                i += 1
            } else {
                line.unicodeScalars.append(s)
                i += 1
            }
        }
        flushLine()
        return output
    }
}
