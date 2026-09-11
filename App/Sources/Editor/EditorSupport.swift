import Foundation
import UIKit
import EditorEngine

/// Cheap text-metric helpers that work on `NSString` so we use utf16 units
/// throughout — selection offsets come from the editor as utf16, so this
/// avoids `String.Index` round-trips on hot paths.
enum TextMetrics {

    /// 1-based (line, column) for a utf16 offset. Stops counting at the
    /// cursor, so cost is linear in `offset`, not in document length.
    static func lineColumn(for utf16Offset: Int, in text: NSString) -> (line: Int, column: Int) {
        let safe = max(0, min(utf16Offset, text.length))
        var line = 1
        var lastBreak = -1   // utf16 index of the most recent line-terminator
        var i = 0
        while i < safe {
            let unit = text.character(at: i)
            if unit == 0x0A {                                   // LF
                line += 1
                lastBreak = i
                i += 1
            } else if unit == 0x0D {                            // CR or CRLF
                line += 1
                lastBreak = i
                i += 1
                if i < safe, text.character(at: i) == 0x0A {
                    lastBreak = i
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return (line, safe - lastBreak)
    }

    /// 1-based total line count.
    static func lineCount(in text: NSString) -> Int {
        let length = text.length
        guard length > 0 else { return 1 }
        var lines = 1
        var i = 0
        while i < length {
            let unit = text.character(at: i)
            if unit == 0x0A {
                lines += 1
                i += 1
            } else if unit == 0x0D {
                lines += 1
                i += 1
                if i < length, text.character(at: i) == 0x0A { i += 1 }
            } else {
                i += 1
            }
        }
        return lines
    }

    /// Detect the first explicit line terminator in `text`. Returns nil for
    /// strings with no line terminators.
    static func firstLineEnding(in text: NSString) -> LineEndingTerminator? {
        let length = text.length
        var i = 0
        while i < length {
            let unit = text.character(at: i)
            if unit == 0x0D {
                if i + 1 < length, text.character(at: i + 1) == 0x0A { return .crlf }
                return .cr
            }
            if unit == 0x0A { return .lf }
            i += 1
        }
        return nil
    }

    enum LineEndingTerminator { case lf, cr, crlf }
}

/// Cursor-position history with a single mutable cursor index into a
/// bounded stack of locations. Records jumps that move the caret far from
/// the last entry; forward history is dropped on a new record.
struct PositionHistory: Equatable {

    private(set) var entries: [Int] = []
    /// 1-based cursor pointing one past the most recently visited entry.
    /// `cursor == entries.count` means we are at the most-recent location.
    private(set) var cursor: Int = 0

    /// Minimum distance (in utf16 units) between consecutive entries.
    static let jumpThreshold = 80
    /// Maximum number of entries retained.
    static let cap = 64

    mutating func record(_ location: Int) {
        if let last = entries.last, abs(last - location) < Self.jumpThreshold {
            return
        }
        // Drop any forward history before appending.
        if cursor < entries.count {
            entries.removeLast(entries.count - cursor)
        }
        entries.append(location)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
        cursor = entries.count
    }

    mutating func back() -> Int? {
        guard cursor > 1 else { return nil }
        cursor -= 1
        return entries[cursor - 1]
    }

    mutating func forward() -> Int? {
        guard cursor < entries.count else { return nil }
        cursor += 1
        return entries[cursor - 1]
    }
}

/// Naive paren/bracket/brace matcher. Doesn't try to skip past strings or
/// comments — language-aware matching would require tree-sitter traversal,
/// which isn't worth the complexity for cursor-position highlighting.
enum BracketMatcher {

    private static let openers: [unichar: unichar] = [
        0x28: 0x29,  // ( → )
        0x5B: 0x5D,  // [ → ]
        0x7B: 0x7D   // { → }
    ]
    private static let closers: [unichar: unichar] = [
        0x29: 0x28,
        0x5D: 0x5B,
        0x7D: 0x7B
    ]

    static func isBracket(_ ch: unichar) -> Bool {
        openers[ch] != nil || closers[ch] != nil
    }

    /// Returns the matching bracket location for the bracket at or adjacent
    /// to `cursor`. Looks at `text[cursor]` first, then `text[cursor - 1]`.
    static func matchingLocation(in text: NSString, cursor: Int) -> Int? {
        let length = text.length
        if cursor < length, isBracket(text.character(at: cursor)) {
            return matchingLocation(in: text, atBracketAt: cursor)
        }
        if cursor > 0, isBracket(text.character(at: cursor - 1)) {
            return matchingLocation(in: text, atBracketAt: cursor - 1)
        }
        return nil
    }

    static func matchingLocation(in text: NSString, atBracketAt index: Int) -> Int? {
        let length = text.length
        guard index >= 0, index < length else { return nil }
        let ch = text.character(at: index)
        if let close = openers[ch] {
            // Forward scan.
            var depth = 1
            var i = index + 1
            while i < length {
                let c = text.character(at: i)
                if c == ch { depth += 1 }
                else if c == close { depth -= 1; if depth == 0 { return i } }
                i += 1
            }
            return nil
        }
        if let open = closers[ch] {
            // Backward scan.
            var depth = 1
            var i = index - 1
            while i >= 0 {
                let c = text.character(at: i)
                if c == ch { depth += 1 }
                else if c == open { depth -= 1; if depth == 0 { return i } }
                i -= 1
            }
            return nil
        }
        return nil
    }
}

/// Markdown list-continuation: on Enter, repeat the current line's list
/// prefix on the new line, or strip it if the prefix is the only content.
enum MarkdownListContinuation {

    /// Outcome of trying to intercept a newline insertion.
    enum Outcome {
        /// The handler did nothing — let the editor process the newline.
        case passThrough
        /// The handler already wrote the continuation; reject the original
        /// insertion.
        case intercepted
    }

    @MainActor
    static func handle(in textView: EditorEngine.TextView, replacing range: NSRange) -> Outcome {
        let nsText = textView.text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let lineUpToCursor = NSRange(location: lineRange.location, length: range.location - lineRange.location)
        guard lineUpToCursor.length >= 0 else { return .passThrough }
        let line = nsText.substring(with: lineUpToCursor)
        guard let marker = listMarker(for: line) else { return .passThrough }
        let trimmedAfterMarker = line.dropFirst(marker.leading.count + marker.body.count)
        if trimmedAfterMarker.allSatisfy({ $0 == " " || $0 == "\t" }) {
            // Empty list item — strip the marker on Enter rather than continue.
            let strip = NSRange(location: lineRange.location, length: range.location - lineRange.location)
            textView.replace(strip, withText: "")
            return .intercepted
        }
        let continuation: String
        if let next = marker.next {
            continuation = "\n" + marker.leading + next
        } else {
            continuation = "\n" + marker.leading + marker.body
        }
        textView.replace(range, withText: continuation)
        return .intercepted
    }

    struct Marker {
        let leading: String   // whitespace before the bullet
        let body: String      // the bullet text including trailing space: "- ", "* ", "1. ", "- [ ] "
        let next: String?     // next ordered marker if the body was numbered; nil for bullets
    }

    private static func listMarker(for line: String) -> Marker? {
        var i = line.startIndex
        var leading = ""
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            leading.append(line[i])
            i = line.index(after: i)
        }
        let rest = line[i...]

        // Task-list bullet: "- [ ] " or "- [x] "
        if let m = rest.range(of: #"^[-*+]\s\[[ xX]\]\s"#, options: .regularExpression) {
            let body = String(rest[m])
            // Continue with a fresh checkbox.
            let bulletChar = body.first!
            return Marker(leading: leading, body: body, next: "\(bulletChar) [ ] ")
        }
        // Plain bullet: "- ", "* ", "+ "
        if let m = rest.range(of: #"^[-*+]\s"#, options: .regularExpression) {
            return Marker(leading: leading, body: String(rest[m]), next: nil)
        }
        // Ordered: "N. " or "N) "
        if let m = rest.range(of: #"^(\d+)([.)])\s"#, options: .regularExpression) {
            let body = String(rest[m])
            // Extract the number, increment.
            let digits = body.prefix { $0.isNumber }
            if let n = Int(digits), n < Int.max {
                let punct = body.dropFirst(digits.count).prefix(1)
                return Marker(leading: leading, body: body, next: "\(n + 1)\(punct) ")
            }
            return Marker(leading: leading, body: body, next: nil)
        }
        return nil
    }
}

// MARK: - Document opening

/// One canonical file-open pipeline for every surface that produces a URL
/// (Files browser, Open Recent, closed-tab restore, external open, and the
/// scene-local importer). Keeping the state mirroring here prevents one
/// entry point from forgetting encoding, large-file, revision-baseline, or
/// error handling work performed by another.
@MainActor
enum DocumentWorkflow {
    /// The native buffer remains editable while file-provider access waits.
    /// Commit only to the same document generation, retaining newer edits.
    static func save(_ tab: TabModel, to url: URL? = nil, overwrite: Bool = false) async throws {
        let document = tab.document
        guard let destination = url ?? document.fileURL else { throw PlainTextDocument.DocumentError.noFileURL }
        guard !document.isSaving else { throw PlainTextDocument.DocumentError.saveInProgress }
        document.isSaving = true
        defer { document.isSaving = false }
        let generation = tab.state.loadGeneration
        let originalURL = document.fileURL
        let input = tab.state.textView?.text ?? document.text
        let saved = try await document.writeSnapshot(to: destination, text: input, overwrite: overwrite)
        guard tab.state.loadGeneration == generation, document.fileURL == originalURL else {
            throw CancellationError()
        }
        adoptSavedSnapshot(saved, into: tab)
    }

    static func adoptSavedSnapshot(_ saved: PlainTextDocument.SavedSnapshot, into tab: TabModel) {
        let document = tab.document
        var current = tab.state.textView?.text ?? document.text
        if current == saved.inputText {
            if current != saved.text, let editor = tab.state.textView {
                editor.replaceText(in: .init(replacements: [
                    .init(range: NSRange(location: 0, length: current.utf16.count), text: saved.text)
                ]))
            }
            current = saved.text
        }
        document.finishExternalSave(to: saved.url, savedText: saved.text, savedData: saved.data,
            currentText: current, modificationDate: saved.modificationDate)
        if document.fileEncoding != saved.encoding || document.lineEnding != saved.lineEnding {
            document.isDirty = true
            document.autoSave()
        }
        tab.state.text = current
        tab.state.fileURL = saved.url
        tab.state.savedBaselineText = saved.text
    }


    nonisolated static func insertionText(from url: URL, folder: Bool, lineEnding: String) async throws -> String {
        try await CoordinatedFileAccess.perform(at: url) { source in
            if !folder {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5 * 1024 * 1024 else { throw InsertionError.fileTooLarge }
                let data = try Data(contentsOf: source)
                guard data.count <= 5 * 1024 * 1024 else { throw InsertionError.fileTooLarge }
                return try PlainTextDocument.decodePayload(from: data).text
            }
            var enumerationError: (any Error)?
            guard let enumerator = FileManager.default.enumerator(at: source,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false })
            else { throw CocoaError(.fileReadUnknown) }
            var entries: [(name: String, directory: Bool)] = []
            for case let entry as URL in enumerator {
                guard entries.count < 10_000 else { throw InsertionError.folderTooLarge }
                let directory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                entries.append((entry.lastPathComponent, directory))
            }
            if let enumerationError { throw enumerationError }
            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            var lines = [source.lastPathComponent + "/"]
            for (index, entry) in entries.enumerated() {
                let branch = index == entries.count - 1 ? "└── " : "├── "
                lines.append(branch + entry.name + (entry.directory ? "/" : ""))
            }
            return lines.joined(separator: lineEnding) + lineEnding
        }
    }

    enum InsertionError: LocalizedError {
        case fileTooLarge, folderTooLarge, documentChanged
        var errorDescription: String? {
            switch self {
            case .fileTooLarge: "Files larger than 5 MB cannot be inserted."
            case .folderTooLarge: "Folders with more than 10,000 entries cannot be inserted at once."
            case .documentChanged: "The document or selection changed while the item was loading. Choose Insert again."
            }
        }
    }

    /// Reloads the source and, only after a successful load, removes every
    /// recovery copy containing the edits the user explicitly discarded.
    static func revert(
        _ url: URL,
        in tab: TabModel,
        completion: (@MainActor (Result<Void, any Error>) -> Void)? = nil
    ) {
        open(url, in: tab) { result in
            if case .success = result {
                tab.document.deleteScratchFile()
            }
            completion?(result)
        }
    }

    static func open(
        _ url: URL,
        in tab: TabModel,
        goToLine: Int? = nil,
        completion: (@MainActor (Result<Void, any Error>) -> Void)? = nil
    ) {
        let state = tab.state
        tab.kind = .editor
        state.loadTask?.cancel()
        state.loadGeneration &+= 1
        let generation = state.loadGeneration
        state.loadTask = Task { @MainActor [weak tab] in
            guard let tab else { return }
            let state = tab.state
            let document = tab.document
            defer {
                if state.loadGeneration == generation {
                    state.loadTask = nil
                }
            }
            do {
                try await document.loadAsync(from: url)
                try Task.checkCancellation()
            } catch {
                // Providers may report cancellation as a URL/Cocoa error.
                // Only the request still owned by this tab may report it.
                guard !Task.isCancelled, state.loadGeneration == generation else { return }
                AppStateBus.shared.presentation.openErrorMessage =
                    "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
                completion?(.failure(error))
                return
            }

            let loadedURL = document.fileURL ?? url
            applyLoadedDocument(document, at: loadedURL, to: state)
            RecentFilesStore.shared.record(loadedURL)

            let persisted = FoldPersistence.ranges(for: loadedURL)
            DispatchQueue.main.async { [weak state] in
                guard let state, state.loadGeneration == generation else { return }
                state.textView?.applyFoldRanges(persisted)
                if let goToLine { state.textView?.goToLine(goToLine) }
            }
            completion?(.success(()))
        }
    }

    static func applyLoadedDocument(
        _ document: PlainTextDocument,
        at url: URL,
        to state: EditorState
    ) {
        state.fileURL = url
        let limit = SyntaxLimit.current()
        let byteCount = document.originalData?.count ?? document.text.utf8.count
        state.isLargeFile = !limit.allows(byteCount: byteCount)
        state.languageIdentifier = LanguageRegistry.identifier(for: url)
        state.text = document.text
        state.savedBaselineText = document.text
        state.fileEncoding = document.fileEncoding
        state.lineEnding = document.lineEnding
        state.requestEditorFocus()
    }
}

/// A line operation targets the touched lines, excluding a following line when
/// the selection ends at its start. With no selection, the scope is explicit.
struct LineEditTarget {
    let source: String
    let range: NSRange
    let isSelection: Bool
    var text: String { (source as NSString).substring(with: range) }

    init(text: String, selection: NSRange) {
        source = text
        let ns = text as NSString
        let start = min(max(0, selection.location), ns.length)
        let length = min(max(0, selection.length), ns.length - start)
        isSelection = length > 0
        range = isSelection
            ? ns.lineRange(for: NSRange(location: start, length: max(0, length - 1)))
            : NSRange(location: 0, length: ns.length)
    }
}

struct WritingStatistics: Sendable {
    struct Request: Equatable, Sendable {
        let text: String
        let selection: NSRange
        let encoding: UInt
        let utf8BOM: Bool
    }

    private let request: Request
    let words: Int
    let characters: Int
    var hasSelection: Bool { request.selection.length > 0 }
    let selectedWords: Int
    let selectedCharacters: Int
    let bufferBytes: Int?

    init(_ request: Request, reusing previous: WritingStatistics? = nil) {
        self.request = request
        let unchanged = previous?.request.text == request.text
            && previous?.request.encoding == request.encoding && previous?.request.utf8BOM == request.utf8BOM
        words = unchanged ? (previous?.words ?? 0) : Self.wordCount(request.text)
        characters = unchanged ? (previous?.characters ?? 0) : request.text.count
        let ns = request.text as NSString
        let start = min(max(0, request.selection.location), ns.length)
        let length = min(max(0, request.selection.length), ns.length - start)
        let selected = ns.substring(with: NSRange(location: start, length: length))
        selectedWords = Self.wordCount(selected)
        selectedCharacters = selected.count
        let encoding = String.Encoding(rawValue: request.encoding)
        if unchanged { bufferBytes = previous?.bufferBytes }
        else {
            let bytes = request.text.data(using: encoding, allowLossyConversion: false)?.count
            bufferBytes = bytes.map { $0 + (encoding == .utf8 && request.utf8BOM ? 3 : 0) }
        }
    }

    private static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, stop in
            if Task.isCancelled { stop = true; return }
            count += 1
        }
        return count
    }
}
