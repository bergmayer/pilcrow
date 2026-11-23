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

    /// Finds fold bodies in document order.
    static func allFoldableHeaders(
        in text: NSString,
        language: LanguageIdentifier
    ) -> [EditorEngine.TextView.FoldableRegion] {
        switch language {
        case .markdown: return markdownFoldableHeaders(in: text)
        default: return indentFoldableHeaders(in: text)
        }
    }

    private static func markdownFoldableHeaders(in text: NSString) -> [EditorEngine.TextView.FoldableRegion] {
        let headers = OutlineBuilder.build(in: text)
        let lastRow = TextMetrics.lineCount(in: text) - 1
        var boundaries: [Int] = []
        var regions: [EditorEngine.TextView.FoldableRegion] = []

        for index in headers.indices.reversed() {
            let header = headers[index]
            while let next = boundaries.last, headers[next].level > header.level {
                boundaries.removeLast()
            }
            let end = boundaries.last.map { headers[$0].row - 1 } ?? lastRow
            if end > header.row {
                regions.append(.init(headerRow: header.row, bodyRange: (header.row + 1)...end))
            }
            boundaries.append(index)
        }
        return regions.reversed()
    }

    private struct IndentedLine {
        let indent: Int
        let isBlank: Bool
    }

    private static func indentedLines(in text: NSString) -> [IndentedLine] {
        var lines: [IndentedLine] = []
        var indent = 0
        var isBlank = true
        var offset = 0
        let length = text.length
        while offset < length {
            let character = text.character(at: offset)
            offset += 1
            switch character {
            case 0x0A, 0x0D:
                lines.append(IndentedLine(indent: indent, isBlank: isBlank))
                indent = 0
                isBlank = true
                if character == 0x0D, offset < length, text.character(at: offset) == 0x0A {
                    offset += 1
                }
            case 0x20:
                if isBlank { indent += 1 }
            case 0x09:
                if isBlank { indent += 8 }
            default:
                isBlank = false
            }
        }
        lines.append(IndentedLine(indent: indent, isBlank: isBlank))
        return lines
    }

    private static func indentFoldableHeaders(in text: NSString) -> [EditorEngine.TextView.FoldableRegion] {
        let lines = indentedLines(in: text)
        let rows = lines.indices.filter { !lines[$0].isBlank }
        var boundaries: [Int] = []
        var regions: [EditorEngine.TextView.FoldableRegion] = []

        // The closest following line at equal or lower indent ends the fold.
        // Each nonblank line is pushed once and removed at most once.
        for index in rows.indices.reversed() {
            let row = rows[index]
            while let next = boundaries.last, lines[rows[next]].indent > lines[row].indent {
                boundaries.removeLast()
            }
            let end = (boundaries.last ?? rows.endIndex) - 1
            if end > index {
                regions.append(.init(headerRow: row, bodyRange: rows[index + 1]...rows[end]))
            }
            boundaries.append(index)
        }
        return regions.reversed()
    }

    private static func markdownBodyRange(
        forHeaderRow header: Int,
        in text: NSString
    ) -> ClosedRange<Int>? {
        markdownFoldableHeaders(in: text).first { $0.headerRow == header }?.bodyRange
    }

    private static func indentBodyRange(
        forHeaderRow header: Int,
        in text: NSString
    ) -> ClosedRange<Int>? {
        let lines = indentedLines(in: text)
        guard lines.indices.contains(header) else { return nil }
        var first: Int?
        var last = header
        for row in (header + 1)..<lines.count where !lines[row].isBlank {
            guard lines[row].indent > lines[header].indent else { break }
            if first == nil { first = row }
            last = row
        }
        return first.map { $0...last }
    }
}
