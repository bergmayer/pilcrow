import Foundation
import EditorEngine

/// Language-aware foldable-range discovery for a buffer of plain text.
///
/// The engine layer holds the buffer (`text as NSString`) and the
/// 0-based line index. The app layer dispatches by language:
///
///   - Markdown: a heading at level `N` opens a fold that spans every
///     line until the next heading of level `≤ N` (or end of document).
///   - Anything else: indent-based — body is the run of lines whose
///     leading whitespace is strictly greater than the header's.
@MainActor
enum FoldDiscovery {

    /// Returns the body range of the fold opened at `header`, or nil if
    /// the header doesn't open one.
    static func bodyRange(
        forHeaderRow header: Int,
        in text: NSString,
        language: LanguageIdentifier
    ) -> ClosedRange<Int>? {
        switch language {
        case .markdown:
            return markdownBodyRange(forHeaderRow: header, in: text)
        default:
            return indentBodyRange(forHeaderRow: header, in: text)
        }
    }

    /// Find every fold-opening line in the buffer (for Fold All).
    ///
    /// **O(N) single-pass implementation.** The naive version walked the
    /// buffer N times (once per call to `lineStart`/`atxHeadingLevel`),
    /// which was O(N³) on a markdown file — a 634 KB doc with 5 K lines
    /// was *trillions* of operations and froze main thread permanently.
    /// This version walks the buffer once, recording header rows + levels
    /// as it goes, then does a second O(H) pass to pair each header
    /// with its body range.
    static func allFoldableHeaders(
        in text: NSString,
        language: LanguageIdentifier
    ) -> [EditorEngine.TextView.FoldableRegion] {
        switch language {
        case .markdown: return markdownFoldableHeaders(in: text)
        default:        return indentFoldableHeaders(in: text)
        }
    }

    // MARK: - Markdown (O(N))

    private static func markdownFoldableHeaders(in text: NSString) -> [EditorEngine.TextView.FoldableRegion] {
        let headers = OutlineBuilder.build(in: text)
        let totalRows = lineCount(in: text)

        // Pair each header with its body end: the row before the next
        // header whose level is ≤ this header's, or the last row.
        var out: [EditorEngine.TextView.FoldableRegion] = []
        for (idx, header) in headers.enumerated() {
            var endRow = totalRows - 1
            for next in headers[(idx + 1)...] where next.level <= header.level {
                endRow = next.row - 1
                break
            }
            guard endRow > header.row else { continue }
            out.append(.init(headerRow: header.row, bodyRange: (header.row + 1)...endRow))
        }
        return out
    }

    // MARK: - Indent (O(N))

    private static func indentFoldableHeaders(in text: NSString) -> [EditorEngine.TextView.FoldableRegion] {
        let length = text.length
        guard length > 0 else { return [] }
        // Single pass collects (row, indent, isBlank) for every line.
        struct LineInfo { let row: Int; let indent: Int; let isBlank: Bool }
        var lines: [LineInfo] = []
        var row = 0
        var indent = 0
        var sawNonWhitespace = false
        var atLineStart = true
        var i = 0
        func closeLine() {
            lines.append(LineInfo(row: row, indent: indent, isBlank: !sawNonWhitespace))
        }
        while i < length {
            if atLineStart {
                indent = 0
                sawNonWhitespace = false
                atLineStart = false
            }
            let c = text.character(at: i)
            switch c {
            case 0x20: if !sawNonWhitespace { indent += 1 }
            case 0x09: if !sawNonWhitespace { indent += 8 }
            case 0x0A:
                closeLine()
                row += 1; atLineStart = true; i += 1
                continue
            case 0x0D:
                closeLine()
                row += 1; atLineStart = true; i += 1
                if i < length, text.character(at: i) == 0x0A { i += 1 }
                continue
            default: sawNonWhitespace = true
            }
            i += 1
        }
        closeLine()  // final line (no trailing newline)

        // For each non-blank line, fold body = run of subsequent
        // non-blank lines with greater indent.
        var out: [EditorEngine.TextView.FoldableRegion] = []
        for (idx, line) in lines.enumerated() where !line.isBlank {
            var bodyStart = -1
            var bodyEnd = -1
            for j in (idx + 1)..<lines.count {
                let candidate = lines[j]
                if candidate.isBlank {
                    if bodyStart >= 0 { continue } else { continue }
                }
                if candidate.indent <= line.indent { break }
                if bodyStart < 0 { bodyStart = j }
                bodyEnd = j
            }
            guard bodyStart >= 0, bodyEnd >= bodyStart else { continue }
            out.append(.init(headerRow: line.row, bodyRange: lines[bodyStart].row...lines[bodyEnd].row))
        }
        return out
    }

    // MARK: - Markdown

    private static func markdownBodyRange(
        forHeaderRow header: Int,
        in text: NSString
    ) -> ClosedRange<Int>? {
        markdownFoldableHeaders(in: text).first { $0.headerRow == header }?.bodyRange
    }

    // MARK: - Indent-based

    private static func indentBodyRange(
        forHeaderRow header: Int,
        in text: NSString
    ) -> ClosedRange<Int>? {
        let total = lineCount(in: text)
        guard header < total - 1 else { return nil }
        let headerIndent = indentLevel(row: header, in: text)
        var probe = header + 1
        while probe < total, isBlankLine(row: probe, in: text) { probe += 1 }
        guard probe < total else { return nil }
        let bodyIndent = indentLevel(row: probe, in: text)
        guard bodyIndent > headerIndent else { return nil }
        var lastBody = probe
        var row = probe + 1
        while row < total {
            if isBlankLine(row: row, in: text) {
                row += 1
                continue
            }
            let indent = indentLevel(row: row, in: text)
            if indent <= headerIndent { break }
            lastBody = row
            row += 1
        }
        return probe...lastBody
    }

    // MARK: - Shared helpers

    private static func indentLevel(row: Int, in text: NSString) -> Int {
        guard let start = lineStart(row: row, in: text) else { return 0 }
        let length = text.length
        var i = start
        var indent = 0
        while i < length {
            let c = text.character(at: i)
            if c == 0x20 { indent += 1; i += 1 }
            else if c == 0x09 { indent += 8; i += 1 }
            else { break }
        }
        return indent
    }

    private static func isBlankLine(row: Int, in text: NSString) -> Bool {
        guard let start = lineStart(row: row, in: text) else { return true }
        let length = text.length
        var i = start
        while i < length {
            let c = text.character(at: i)
            if c == 0x0A || c == 0x0D { return true }
            if c != 0x20 && c != 0x09 { return false }
            i += 1
        }
        return true
    }

    /// Returns the utf16 location where `row` begins, or nil for an
    /// out-of-range row.
    private static func lineStart(row: Int, in text: NSString) -> Int? {
        let length = text.length
        guard row >= 0 else { return nil }
        if row == 0 { return 0 }
        var i = 0
        var currentRow = 0
        while i < length {
            let c = text.character(at: i)
            if c == 0x0A {
                currentRow += 1
                i += 1
            } else if c == 0x0D {
                currentRow += 1
                i += 1
                if i < length, text.character(at: i) == 0x0A { i += 1 }
            } else {
                i += 1
                continue
            }
            if currentRow == row { return i }
        }
        return nil
    }

    private static func lineCount(in text: NSString) -> Int {
        TextMetrics.lineCount(in: text)
    }
}

