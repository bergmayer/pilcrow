import Foundation

@MainActor
extension CommandActions {

    // MARK: - Markdown formatting

    static func markdownBold()    { markdownSurround(open: "**", close: "**") }
    static func markdownItalic()  { markdownSurround(open: "*",  close: "*")  }
    static func markdownCode()    { markdownSurround(open: "`",  close: "`")  }
    static func markdownStrike()  { markdownSurround(open: "~~", close: "~~") }

    /// Re-running stacks markers — users who want to demote re-run
    /// the action. Levels 1–6.
    static func markdownHeader(level: Int) {
        let clamped = max(1, min(6, level))
        let marker = String(repeating: "#", count: clamped) + " "
        applyLinePrefix { _ in marker }
    }

    static func markdownBlockquote() {
        applyLinePrefix { _ in "> " }
    }

    /// Inserts a newline first if mid-line so `---` lives on its own.
    static func markdownHorizontalRule() {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let cursor = textView.selectedRange.location
        let lineEnding = state?.lineEnding.string ?? "\n"
        let line = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let lineText = nsText.substring(with: line)
        let onBlankLine = lineText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let insertion: String
        if onBlankLine {
            insertion = "---\(lineEnding)"
            // Whitespace-only lines: replace the whole line so the
            // stray spaces don't survive after the rule.
            let target = lineText.trimmingCharacters(in: .newlines).isEmpty
                ? NSRange(location: line.location, length: 0)
                : line
            textView.replace(target, withText: insertion)
            textView.setSelection(NSRange(location: line.location + (insertion as NSString).length, length: 0))
        } else {
            insertion = "\(lineEnding)---\(lineEnding)"
            let endOfLine = line.location + line.length
            textView.replace(NSRange(location: endOfLine, length: 0), withText: insertion)
            textView.setSelection(NSRange(location: endOfLine + (insertion as NSString).length, length: 0))
        }
        commitTextChange()
    }

    /// Empty selection: cursor lands inside `[]` for the link text.
    /// With selection: selection becomes the text, `url` is highlighted.
    static func markdownLink() {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            textView.replace(range, withText: "[](url)")
            textView.setSelection(NSRange(location: range.location + 1, length: 0))
        } else {
            let selected = (textView.text as NSString).substring(with: range)
            let wrapped = "[\(selected)](url)"
            textView.replace(range, withText: wrapped)
            // Highlight "url" so the user can replace it immediately.
            let urlStart = range.location + (selected as NSString).length + 3
            textView.setSelection(NSRange(location: urlStart, length: 3))
        }
        commitTextChange()
    }

    /// Mirrors `markdownLink` with `![alt](url)`.
    static func markdownImage() {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            textView.replace(range, withText: "![alt](url)")
            textView.setSelection(NSRange(location: range.location + 2, length: 3))
        } else {
            let selected = (textView.text as NSString).substring(with: range)
            let wrapped = "![\(selected)](url)"
            textView.replace(range, withText: wrapped)
            let urlStart = range.location + (selected as NSString).length + 4
            textView.setSelection(NSRange(location: urlStart, length: 3))
        }
        commitTextChange()
    }

    static func presentMarkdownTable() {
        presentSheet(.markdownTable)
    }

    /// iPad gets a real scene (Stage Manager-friendly, side-by-side
    /// with the editor). iPhone is single-window so it gets a sheet
    /// — opening a new scene there would silently no-op.
    static func presentMarkdownPreview() {
        if DeviceIdiom.supportsMultipleWindows {
            guard let tab = Self.context.scenes.currentSession?.activeTab else { return }
            Self.context.scenes.openPreviewWindow?(tab.id)
        } else {
            presentSheet(.markdownPreview)
        }
    }

    /// No-op when the slot is empty or out of range. Script errors
    /// surface via the standard error alert.
    static func runJSTransform(slotID: Int) {
        guard let slot = JSTransformStore.shared.slot(id: slotID) else { return }
        JSTransformRunner.run(slot)
    }

    /// `N` is the smallest unused integer in the buffer. Cursor
    /// lands at the end of the `[^N]: ` definition so the user can
    /// type the body immediately.
    static func markdownFootnote() {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let lineEnding = state?.lineEnding.string ?? "\n"

        var used = Set<Int>()
        if let pattern = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#) {
            let matches = pattern.matches(in: textView.text,
                                          range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges >= 2 {
                if let n = Int(nsText.substring(with: match.range(at: 1))) {
                    used.insert(n)
                }
            }
        }
        var nextId = 1
        while used.contains(nextId) { nextId += 1 }

        let ref = "[^\(nextId)]"
        let cursor = textView.selectedRange
        textView.replace(cursor, withText: ref)
        // Pad to a fresh line so the definition lands at the footer,
        // not wedged into the last paragraph.
        let textNow = textView.text as NSString
        let nlLength = (lineEnding as NSString).length
        let endsWithNL = textNow.length >= nlLength
            && textNow.substring(from: textNow.length - nlLength) == lineEnding
        let prefix = endsWithNL ? lineEnding : lineEnding + lineEnding
        let definition = "\(prefix)[^\(nextId)]: "
        let appendAt = textNow.length
        textView.replace(NSRange(location: appendAt, length: 0), withText: definition)
        // Land at the end of the new definition.
        let defEnd = appendAt + (definition as NSString).length
        textView.setSelection(NSRange(location: defEnd, length: 0))
        textView.scrollSelectionToVisible()
        commitTextChange()
    }

    /// Placement options for the Organize Footnotes flow — picked
    /// in `OrganizeFootnotesSheet`.
    enum FootnotePlacement {
        case endOfDocument
        case endOfParagraph
    }

    /// Re-number every footnote reference (`[^id]`) in the buffer
    /// based on appearance order in the body — the user may have
    /// inserted footnotes out of order — and move the matching
    /// definitions either to the end of the document or to the end
    /// of each paragraph that references them. Idempotent on a
    /// well-organized buffer.
    static func organizeFootnotes(placement: FootnotePlacement) {
        guard let textView = actions else { return }
        let original = textView.text
        let (body, defs) = Self.extractFootnoteDefinitions(from: original)
        // Build remap: old id → new sequential number based on first
        // appearance in body. Refs without a matching definition still
        // get renumbered (so a `[^foo]` typo stays consistent).
        let refOrder = Self.footnoteReferenceOrder(in: body)
        var remap: [String: String] = [:]
        for id in refOrder where remap[id] == nil {
            remap[id] = "\(remap.count + 1)"
        }
        let rewrittenBody = Self.applyFootnoteRemap(remap, to: body)
        let renamedDefs: [(id: String, content: String)] = defs.map { def in
            (remap[def.id] ?? def.id, def.content)
        }
        let defLookup = Dictionary(renamedDefs.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })

        let output: String
        switch placement {
        case .endOfDocument:
            let sorted = renamedDefs.sorted {
                (Int($0.id) ?? .max) < (Int($1.id) ?? .max)
            }
            let defsText = sorted.map { "[^\($0.id)]: \($0.content)" }.joined(separator: "\n")
            let trimmedBody = rewrittenBody.trimmingCharacters(in: .whitespacesAndNewlines)
            output = defsText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(defsText)\n"
        case .endOfParagraph:
            output = Self.placeFootnotesAfterParagraphs(body: rewrittenBody, defs: defLookup)
        }

        let full = NSRange(location: 0, length: (original as NSString).length)
        textView.replace(full, withText: output)
        commitTextChange()
    }

    /// Continuation lines (indented by 4 spaces or a tab) attach to
    /// their definition. Returns the cleaned body + definitions in
    /// source order.
    private static func extractFootnoteDefinitions(from text: String) -> (body: String, defs: [(id: String, content: String)]) {
        let lines = text.components(separatedBy: "\n")
        var keep: [String] = []
        var defs: [(id: String, content: String)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let match = Self.footnoteDefinitionMatch(line) {
                var content = match.body
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    if next.hasPrefix("    ") || next.hasPrefix("\t") {
                        let trimmed = next.drop(while: { $0 == " " || $0 == "\t" })
                        content += "\n" + String(trimmed)
                        j += 1
                    } else { break }
                }
                defs.append((match.id, content))
                i = j
                continue
            }
            keep.append(line)
            i += 1
        }
        return (keep.joined(separator: "\n"), defs)
    }

    private static func footnoteDefinitionMatch(_ line: String) -> (id: String, body: String)? {
        guard line.hasPrefix("[^"), let closeBracket = line.range(of: "]:") else { return nil }
        let id = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket.lowerBound])
        let body = String(line[closeBracket.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (id, body)
    }

    /// In source order, duplicates kept — dedupe is the caller's call.
    private static func footnoteReferenceOrder(in body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Ids missing from the remap pass through. Skips any match
    /// whose NSRange can't bridge back to a Swift Range — better
    /// to drop one rewrite than crash on a surrogate-pair edge case.
    private static func applyFootnoteRemap(_ remap: [String: String], to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let id = ns.substring(with: match.range(at: 1))
            guard let mapped = remap[id] else { continue }
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: "[^\(mapped)]")
        }
        return result
    }

    /// Inserts each definition after the paragraph that first
    /// references it; duplicate refs across later paragraphs don't
    /// re-emit the definition.
    private static func placeFootnotesAfterParagraphs(body: String, defs: [String: String]) -> String {
        let paragraphs = body.components(separatedBy: "\n\n")
        var placed = Set<String>()
        var output: [String] = []
        for para in paragraphs {
            output.append(para)
            let ids = Self.footnoteReferenceOrder(in: para)
            var newIds: [String] = []
            for id in ids where !placed.contains(id) && defs[id] != nil {
                placed.insert(id)
                newIds.append(id)
            }
            if !newIds.isEmpty {
                let defLines = newIds.map { "[^\($0)]: \(defs[$0] ?? "")" }
                output.append(defLines.joined(separator: "\n"))
            }
        }
        return output.joined(separator: "\n\n")
    }

    // Empty selection: cursor lands between the markers so the user
    // types the content directly.
    private static func markdownSurround(open: String, close: String) {
        guard let textView = actions else { return }
        let range = textView.selectedRange
        let openLen = (open as NSString).length
        if range.length == 0 {
            textView.replace(range, withText: open + close)
            textView.setSelection(NSRange(location: range.location + openLen, length: 0))
        } else {
            let selected = (textView.text as NSString).substring(with: range)
            let wrapped = open + selected + close
            textView.replace(range, withText: wrapped)
            textView.setSelection(NSRange(location: range.location + openLen,
                                          length: (selected as NSString).length))
        }
        commitTextChange()
    }

    // MARK: - Markdown list conversion

    /// Always applies — distinct from the accessory bar's toggle.
    static func convertToBulletListDash() {
        applyLinePrefix { _ in "- " }
    }

    static func convertToBulletListStar() {
        applyLinePrefix { _ in "* " }
    }

    /// Numbers based on position within the selection, not the file.
    /// Rerunning on an existing numbered list re-numbers it.
    static func convertToNumberedList() {
        applyLinePrefix { idx in "\(idx + 1). " }
    }

    /// Applies bottom-up so line-start offsets stay valid as we go.
    private static func applyLinePrefix(_ prefixForLine: (Int) -> String) {
        guard let textView = actions else { return }
        let nsText = textView.text as NSString
        let selection = textView.selectedRange
        let block = nsText.lineRange(for: selection)

        var lineStarts: [Int] = []
        var scan = block.location
        while scan < block.location + block.length {
            lineStarts.append(scan)
            let lr = nsText.lineRange(for: NSRange(location: scan, length: 0))
            scan = lr.location + lr.length
        }
        if lineStarts.isEmpty { lineStarts = [block.location] }

        var totalInserted = 0
        var firstLineInserted = 0
        for (i, start) in lineStarts.enumerated().reversed() {
            let prefix = prefixForLine(i)
            let prefixLen = (prefix as NSString).length
            textView.replace(NSRange(location: start, length: 0), withText: prefix)
            totalInserted += prefixLen
            if i == 0 { firstLineInserted = prefixLen }
        }
        // Keep the selection aligned with the inserted text — anchor
        // shifts by the first line's prefix; length grows by the
        // total minus that anchor shift (so trailing edge tracks).
        let newLocation = selection.location + firstLineInserted
        let newLength = selection.length + (totalInserted - firstLineInserted)
        textView.setSelection(NSRange(location: newLocation, length: newLength))
        commitTextChange()
    }

    /// Unwraps email / Markdown quote indentation from every line.
    static func stripQuoteLevel() {
        transformSelection { text in
            let nl = state?.lineEnding.string ?? "\n"
            let lines = text.components(separatedBy: nl)
            let stripped = lines.map { line -> String in
                var s = line
                // Strip every quote level.
                while s.hasPrefix("> ") { s.removeFirst(2) }
                while s.hasPrefix(">")  { s.removeFirst() }
                return s
            }
            return stripped.joined(separator: nl)
        }
    }
}
