import Foundation

/// One row in the markdown outline. Captured row index is 0-based; the
/// `level` is the heading depth (1 for `#`, 2 for `##`, …, up to 6).
struct OutlineEntry: Identifiable, Equatable {
    let row: Int
    let level: Int
    let title: String
    var id: Int { row }
}

/// Walks the buffer once and collects symbols suitable for an outline.
/// Code outlines reuse `FoldDiscovery.allFoldableHeaders` so the panel
/// and the gutter agree on what counts as a "section": every foldable
/// region surfaces as one entry titled by its header line. Markdown
/// uses the same heading scan as the sidebar and folding.
@MainActor
enum OutlineDiscovery {

    static func entries(in text: NSString, language: LanguageIdentifier) -> [OutlineEntry] {
        if language == .markdown {
            return OutlineBuilder.build(in: text)
        }
        return codeEntries(in: text, language: language)
    }

    private static func codeEntries(in text: NSString, language: LanguageIdentifier) -> [OutlineEntry] {
        let regions = FoldDiscovery.allFoldableHeaders(in: text, language: language)
        guard !regions.isEmpty else { return [] }

        // One pass over the buffer collects line ranges so we can pull
        // each header's text by row. Cheap relative to the fold scan.
        let lineRanges = collectLineRanges(in: text)
        let sorted = regions.sorted { $0.headerRow < $1.headerRow }

        return sorted.compactMap { region -> OutlineEntry? in
            guard region.headerRow >= 0, region.headerRow < lineRanges.count else { return nil }
            let lr = lineRanges[region.headerRow]
            let raw = text.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            // Nesting level = how many other regions enclose this header row.
            let level = sorted.reduce(into: 1) { acc, other in
                if other.headerRow < region.headerRow,
                   other.bodyRange.contains(region.headerRow) {
                    acc += 1
                }
            }
            return OutlineEntry(row: region.headerRow, level: level, title: raw)
        }
    }

    /// Line ranges keyed by row — `result[row]` is that line's NSRange
    /// (excluding the trailing newline if present).
    private static func collectLineRanges(in text: NSString) -> [NSRange] {
        let length = text.length
        var ranges: [NSRange] = []
        var start = 0
        var i = 0
        while i < length {
            let c = text.character(at: i)
            if c == 0x0A {
                ranges.append(NSRange(location: start, length: i - start))
                i += 1
                start = i
            } else if c == 0x0D {
                ranges.append(NSRange(location: start, length: i - start))
                i += 1
                if i < length, text.character(at: i) == 0x0A { i += 1 }
                start = i
            } else {
                i += 1
            }
        }
        if start < length {
            ranges.append(NSRange(location: start, length: length - start))
        } else if length == 0 || text.character(at: length - 1) == 0x0A || text.character(at: length - 1) == 0x0D {
            ranges.append(NSRange(location: length, length: 0))
        }
        return ranges
    }


}

/// Shared heading and fence rules for navigation, folding, and preview.
/// Rows match the editor's LF, CR, and CRLF line model.
enum OutlineBuilder {
    static func lines(in text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        }).map(String.init)
    }

    static func build(in text: NSString) -> [OutlineEntry] {
        let lines = lines(in: text as String)
        var entries: [OutlineEntry] = []
        var fence: Fence?
        var row = 0
        while row < lines.count {
            let line = lines[row]
            if let open = fence {
                if open.closes(line) { fence = nil }
            } else if let opening = Fence(line) {
                fence = opening
            } else if let heading = heading(line, next: lines.indices.contains(row + 1) ? lines[row + 1] : nil) {
                entries.append(OutlineEntry(row: row, level: heading.level, title: heading.text))
                row += heading.lines
                continue
            }
            row += 1
        }
        return entries
    }

    static func heading(_ line: String, next: String? = nil) -> (level: Int, text: String, lines: Int)? {
        guard let content = blockContent(line), !content.isEmpty else { return nil }
        let hashes = content.prefix { $0 == "#" }.count
        if (1...6).contains(hashes) {
            let rest = content.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            let title = rest.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"(?:^|[ \t]+)#+$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return (hashes, title, 1)
        }
        guard let next, let underline = blockContent(next)?.trimmingCharacters(in: .whitespaces),
              let marker = underline.first, marker == "=" || marker == "-",
              underline.allSatisfy({ $0 == marker }),
              !content.hasPrefix("#"),
              content.range(of: #"^(?:>|[-+*][ \t]|[0-9]+[.)][ \t])"#, options: .regularExpression) == nil
        else { return nil }
        return (marker == "=" ? 1 : 2, content.trimmingCharacters(in: .whitespaces), 2)
    }

    private static func blockContent(_ line: String) -> Substring? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces < 4, !line.dropFirst(spaces).hasPrefix("\t") else { return nil }
        return line.dropFirst(spaces)
    }

    struct Fence {
        let marker: Character
        let count: Int

        init?(_ line: String) {
            guard let content = blockContent(line), let marker = content.first,
                  marker == "`" || marker == "~" else { return nil }
            let count = content.prefix { $0 == marker }.count
            guard count >= 3 else { return nil }
            if marker == "`", content.dropFirst(count).contains("`") { return nil }
            self.marker = marker
            self.count = count
        }

        func closes(_ line: String) -> Bool {
            guard let content = blockContent(line) else { return false }
            let run = content.prefix { $0 == marker }.count
            return run >= count && content.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
