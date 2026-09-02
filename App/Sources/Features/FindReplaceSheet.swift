import SwiftUI

/// Find, replace, and confirm-each-match workflows.
struct FindReplaceSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable private var bus = AppStateBus.shared
    let editor: EditorState

    @State private var showReplace: Bool = false
    @State private var queryMode: Bool = false
    @State private var currentMatch: CommandActions.QueryReplaceMatch?
    @State private var queryReplacedCount: Int = 0
    @State private var errorText: String?
    @State private var statusText: String?
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        bus.find.context.useRegex ? "Regular expression" : "Find",
                        text: $bus.find.context.query
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(bus.find.context.useRegex ? .body.monospaced() : .body)
                    .focused($searchFieldFocused)
                    .onSubmit { primaryAction() }

                    if showReplace {
                        TextField(
                            bus.find.context.useRegex ? "Replacement (supports $1, $2, …)" : "Replace with",
                            text: $bus.find.context.replacement
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(bus.find.context.useRegex ? .body.monospaced() : .body)
                    }
                }

                Section("Options") {
                    Toggle("Regular Expression", isOn: $bus.find.context.useRegex)
                    Toggle("Case Sensitive",    isOn: $bus.find.context.caseSensitive)
                    Toggle("Whole Word",        isOn: $bus.find.context.wholeWord)
                        .disabled(bus.find.context.useRegex)
                }

                Section {
                    Toggle("Show Replace", isOn: $showReplace)
                    if showReplace {
                        Toggle("Query Mode (confirm each match)", isOn: $queryMode)
                            .onChange(of: queryMode) { _, _ in
                                currentMatch = nil
                                clearMessages()
                            }
                    }
                }

                if queryMode && showReplace {
                    queryButtons
                } else {
                    classicButtons
                }

                if let statusText {
                    Section { Text(statusText).font(.footnote).foregroundStyle(.secondary) }
                }
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(queryMode ? "Query Replace" : "Find")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                claimOwner()
                searchFieldFocused = true
                if bus.find.pendingShowReplace {
                    showReplace = true
                    bus.find.pendingShowReplace = false
                }
                if bus.find.pendingQueryMode {
                    queryMode = true
                    bus.find.pendingQueryMode = false
                }
            }
        }
    }

    // MARK: - Button rows

    @ViewBuilder
    private var classicButtons: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    stepPrevious()
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(bus.find.context.query.isEmpty)
                Button {
                    stepNext()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(bus.find.context.query.isEmpty)
            }

            if showReplace {
                HStack(spacing: 12) {
                    Button("Replace") {
                        replaceCurrentAndAdvance()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(bus.find.context.query.isEmpty)
                    Button("Replace All", role: .destructive) {
                        replaceAll()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(bus.find.context.query.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var queryButtons: some View {
        if currentMatch == nil {
            Section {
                Button("Find First Match") { queryAdvance() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(bus.find.context.query.isEmpty)
            }
        } else {
            Section("Current Match") {
                HStack(spacing: 12) {
                    Button("Replace") {
                        queryReplaceCurrent()
                        queryAdvance()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    Button("Skip") { queryAdvance() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
                Button("Replace All from Here", role: .destructive) { queryReplaceAll() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Classic mode actions

    private func primaryAction() {
        if queryMode && showReplace {
            if currentMatch == nil {
                queryAdvance()
            } else {
                queryReplaceCurrent()
                queryAdvance()
            }
        } else {
            stepNext()
        }
    }

    private func stepNext() {
        clearMessages()
        claimOwner()
        CommandActions.stepToMatch(forward: true)
    }

    private func stepPrevious() {
        clearMessages()
        claimOwner()
        CommandActions.stepToMatch(forward: false)
    }

    private func replaceCurrentAndAdvance() {
        clearMessages()
        claimOwner()
        guard let textView = editor.textView else { return }
        let ctx = bus.find.context
        if textView.selectedRange.length > 0,
           let selected = textView.text(in: textView.selectedRange),
           currentSelectionMatches(selected, against: ctx) {
            let replacement = ctx.useRegex
                ? evaluatedReplacement(for: selected, context: ctx) ?? ctx.replacement
                : ctx.replacement
            textView.replace(textView.selectedRange, withText: replacement)
            editor.setText?(textView.text)
        }
        CommandActions.stepToMatch(forward: true)
    }

    private func replaceAll() {
        clearMessages()
        claimOwner()
        guard let textView = editor.textView else { return }
        let ctx = bus.find.context
        var cursor = 0
        var count = 0
        do {
            let length = (textView.text as NSString).length
            while cursor < length,
                  let match = try CommandActions.matchInDocument(
                    context: ctx,
                    forward: true,
                    startingAt: cursor,
                    totalLength: (textView.text as NSString).length
                  ) {
                textView.replace(match.range, withText: match.replacement)
                count += 1
                cursor = match.range.location + (match.replacement as NSString).length
                // Zero-width matches (`a*`, `^`) with an empty replacement
                // never move the cursor — force it past the match site.
                if match.range.length == 0 { cursor += 1 }
            }
            editor.setText?(textView.text)
            statusText = "Replaced \(count) match\(count == 1 ? "" : "es")."
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Query mode actions

    private var resolvedQuery: String {
        let ctx = bus.find.context
        if !ctx.wholeWord { return ctx.query }
        let inner = ctx.useRegex ? ctx.query : NSRegularExpression.escapedPattern(for: ctx.query)
        return #"\b"# + inner + #"\b"#
    }

    private var resolvedUseRegex: Bool { bus.find.context.useRegex || bus.find.context.wholeWord }

    private func queryAdvance() {
        errorText = nil
        // `revealMatch` parked the selection at the current match's
        // start, so restarting the search there re-finds the same
        // match and Skip never advances — resume past its end.
        let cursor: Int
        if let match = currentMatch {
            cursor = max(NSMaxRange(match.range), match.range.location + 1)
        } else {
            cursor = editor.selectedRange.location
        }
        do {
            claimOwner()
            if let match = try CommandActions.nextQueryReplaceMatch(
                query: resolvedQuery,
                replacement: bus.find.context.replacement,
                useRegex: resolvedUseRegex,
                caseSensitive: bus.find.context.caseSensitive,
                startingAt: cursor
            ) {
                currentMatch = match
                CommandActions.revealMatch(match)
                statusText = nil
            } else {
                currentMatch = nil
                statusText = queryReplacedCount > 0
                    ? "No more matches. Replaced \(queryReplacedCount)."
                    : "No matches."
            }
        } catch {
            errorText = error.localizedDescription
            currentMatch = nil
        }
    }

    private func queryReplaceCurrent() {
        guard let match = currentMatch else { return }
        claimOwner()
        CommandActions.applyQueryReplaceMatch(match)
        queryReplacedCount += 1
        currentMatch = nil
    }

    private func queryReplaceAll() {
        errorText = nil
        claimOwner()
        var cursor = editor.selectedRange.location
        var count = 0
        do {
            while let match = try CommandActions.nextQueryReplaceMatch(
                query: resolvedQuery,
                replacement: bus.find.context.replacement,
                useRegex: resolvedUseRegex,
                caseSensitive: bus.find.context.caseSensitive,
                startingAt: cursor
            ) {
                CommandActions.applyQueryReplaceMatch(match)
                count += 1
                cursor = match.range.location + (match.replacement as NSString).length
                // Same zero-width guard as replaceAll().
                if match.range.length == 0 { cursor += 1 }
            }
            queryReplacedCount += count
            currentMatch = nil
            statusText = "Replaced \(count) match\(count == 1 ? "" : "es")."
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func clearMessages() {
        statusText = nil
        errorText = nil
    }

    private func claimOwner() {
        bus.scenes.claimFocus(state: editor)
    }

    private func currentSelectionMatches(_ selected: String, against ctx: FindContext) -> Bool {
        if ctx.useRegex || ctx.wholeWord { return true }
        return ctx.caseSensitive
            ? selected == ctx.query
            : selected.compare(ctx.query, options: .caseInsensitive) == .orderedSame
    }

    private func evaluatedReplacement(for selected: String, context: FindContext) -> String? {
        let options: NSRegularExpression.Options = context.caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: context.query, options: options),
              let match = regex.firstMatch(
                in: selected,
                range: NSRange(selected.startIndex..., in: selected)
              )
        else { return nil }
        return regex.replacementString(for: match, in: selected, offset: 0, template: context.replacement)
    }
}
