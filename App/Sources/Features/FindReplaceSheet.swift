import SwiftUI
import EditorEngine

/// Find, replace, and confirm-each-match workflows.
struct FindReplaceSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable private var bus = AppStateBus.shared
    let editor: EditorState
    @State private var draft: FindContext

    init(editor: EditorState) {
        self.editor = editor
        _draft = State(initialValue: AppStateBus.shared.find.context)
    }

    @State private var showReplace: Bool = false
    @State private var queryMode: Bool = false
    @State private var querySession: QueryReplacementSession?
    private var currentMatch: DocumentSearch.Match? { querySession?.current }
    @State private var queryReplacedCount: Int = 0
    @State private var errorText: String?
    @State private var statusText: String?
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        draft.useRegex ? "Regular expression" : "Find",
                        text: $draft.query
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(draft.useRegex ? .body.monospaced() : .body)
                    .focused($searchFieldFocused)
                    .onSubmit { primaryAction() }

                    if showReplace {
                        TextField(
                            draft.useRegex ? "Replacement (supports $1, $2, …)" : "Replace with",
                            text: $draft.replacement
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(draft.useRegex ? .body.monospaced() : .body)
                    }
                }

                Section("Options") {
                    Toggle("Regular Expression", isOn: $draft.useRegex)
                    Toggle("Case Sensitive",    isOn: $draft.caseSensitive)
                    Toggle("Whole Word",        isOn: $draft.wholeWord)
                        .disabled(draft.useRegex)
                }

                Section {
                    Toggle("Show Replace", isOn: $showReplace)
                    if showReplace {
                        Toggle("Query Mode (confirm each match)", isOn: $queryMode)
                            .onChange(of: queryMode) { _, _ in
                                querySession = nil
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
            .navigationTitle(queryMode && showReplace ? "Query Replace" : (showReplace ? "Find & Replace" : "Find"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: draft) { _, _ in
                querySession = nil
                queryReplacedCount = 0
                clearMessages()
            }
            .onDisappear { bus.find.context = draft }
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
                .disabled(draft.query.isEmpty)
                Button {
                    stepNext()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.query.isEmpty)
            }

            if showReplace {
                HStack(spacing: 12) {
                    Button("Replace") {
                        replaceCurrentAndAdvance()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(draft.query.isEmpty)
                    Button("Replace All", role: .destructive) {
                        replaceAll()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(draft.query.isEmpty)
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
                    .disabled(draft.query.isEmpty)
            }
        } else {
            Section("Current Match") {
                HStack(spacing: 12) {
                    Button("Replace") {
                        queryReplaceCurrent()
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
            }
        } else {
            stepNext()
        }
    }

    private func stepNext() { step(forward: true) }
    private func stepPrevious() { step(forward: false) }

    private func step(forward: Bool) {
        run { statusText = try CommandActions.selectSearchMatch(forward: forward) }
    }

    private func replaceCurrentAndAdvance() {
        run {
            _ = try CommandActions.replaceSelectedMatch()
            statusText = try CommandActions.selectSearchMatch(forward: true)
        }
    }

    private func replaceAll() {
        run { statusText = "Replaced \(try CommandActions.replaceAllMatches()) matches." }
    }

    private func queryAdvance() {
        run {
            guard let textView = editor.textView else { return }
            if querySession == nil {
                querySession = QueryReplacementSession(search: try CommandActions.documentSearch(in: textView),
                                                       startingAt: textView.selectedRange.location)
            } else {
                try validateQuery(in: textView)
                querySession?.skip()
            }
            revealQueryMatch()
        }
    }

    private func queryReplaceCurrent() {
        run {
            guard let textView = editor.textView, let match = currentMatch else { return }
            try validateQuery(in: textView)
            textView.replaceText(in: BatchReplaceSet(replacements: [.init(range: match.range, text: match.replacement)]))
            querySession?.acceptReplacement(actualText: textView.text)
            queryReplacedCount += 1
            revealQueryMatch()
        }
    }

    private func queryReplaceAll() {
        run {
            guard let textView = editor.textView, let session = querySession else { return }
            try validateQuery(in: textView)
            // Collect pending ranges before performing a single undoable edit.
            var walk = session
            var replacements: [BatchReplaceSet.Replacement] = []
            while let match = walk.current {
                replacements.append(.init(range: match.range, text: match.replacement))
                walk.skip()
            }
            textView.replaceText(in: BatchReplaceSet(replacements: replacements))
            queryReplacedCount += replacements.count
            querySession = nil
            statusText = "Replaced \(queryReplacedCount) matches."
        }
    }

    private func validateQuery(in textView: PilcrowTextView) throws {
        guard querySession?.expectedText == textView.text else {
            querySession = nil
            throw QueryError.documentChanged
        }
    }

    private enum QueryError: LocalizedError {
        case documentChanged
        var errorDescription: String? { "The document changed. Find the first match again before replacing." }
    }

    private func revealQueryMatch() {
        if let match = currentMatch {
            CommandActions.revealMatch(match)
        } else {
            querySession = nil
            statusText = "No more matches. Replaced \(queryReplacedCount)."
        }
    }

    private func run(_ action: () throws -> Void) {
        clearMessages()
        claimOwner()
        bus.find.context = draft
        do { try action() }
        catch { errorText = error.localizedDescription }
    }

    private func clearMessages() { statusText = nil; errorText = nil }
    private func claimOwner() { bus.scenes.claimFocus(state: editor) }
}
