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
            if let n = Int(digits) {
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

    static func open(
        _ url: URL,
        in tab: TabModel,
        goToLine: Int? = nil,
        completion: (@MainActor (Result<Void, any Error>) -> Void)? = nil
    ) {
        let state = tab.state
        let document = tab.document
        let hadRenderableContent = document.fileURL != nil || !document.text.isEmpty

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
            } catch is CancellationError {
                return
            } catch {
                if !hadRenderableContent {
                    tab.kind = .launcher
                    document.fileURL = nil
                    state.fileURL = nil
                }
                AppStateBus.shared.presentation.openErrorMessage =
                    "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
                completion?(.failure(error))
                return
            }

            applyLoadedDocument(document, at: url, to: state)
            RecentFilesStore.shared.record(url)

            let persisted = FoldPersistence.ranges(for: url)
            if !persisted.isEmpty {
                DispatchQueue.main.async { [weak state] in
                    state?.textView?.applyFoldRanges(persisted)
                }
            }
            if let goToLine {
                DispatchQueue.main.async { [weak state] in
                    state?.textView?.goToLine(goToLine)
                }
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
