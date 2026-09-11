import SwiftUI

/// Fuzzy-search command palette. Presented as a sheet attached to
/// the active editor scene; opens with ⌘; (next to ⌘, Settings),
/// dismissed by ⎋, the Cancel toolbar button, or running a command.
///
/// Browse mode (empty query) shows the same top-level groups as the
/// iPad menu bar (File, Edit, View, Search, Text, Markdown) so
/// iPhone users can discover features by clicking through where they
/// live. Tap a group → command list with a back button. Type
/// anything → flat fuzzy search across every command, regardless of
/// the current drill-down.
struct CommandPaletteSheet: View {

    let onSelect: (EditorCommandSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedGroup: MenuGroup?
    @FocusState private var fieldFocused: Bool
    @State private var selectionIndex: Int = 0

    private let allCommands: [EditorCommandSpec] = CommandRegistry.all()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                Divider()

                // ↑/↓ moves the highlight while focus stays in the
                // text field — without an explicit scrollTo the
                // selection walks off-screen.
                ScrollViewReader { proxy in
                    Group {
                        if isSearching {
                            flatResultsList
                        } else if let group = selectedGroup {
                            groupCommandsList(group: group)
                        } else {
                            groupBrowseList
                        }
                    }
                    .onChange(of: selectionIndex) { _, newValue in
                        if let id = rowID(at: newValue) {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Leading slot toggles between Back (when inside a
                // group) and Cancel (at root). Showing both at once
                // was confusing — they sat in the same pill chrome at
                // the same edge, indistinguishable at a glance. The
                // swipe-down indicator still dismisses the whole sheet
                // when the user is mid-drill-down, so they don't lose
                // a way out.
                ToolbarItem(placement: .topBarLeading) {
                    if !isSearching, selectedGroup != nil {
                        Button {
                            withAnimation(.snappy) { selectedGroup = nil }
                            selectionIndex = 0
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            // `.defaultFocus` (iOS 17+) claims focus as the scope mounts,
            // not via `.onAppear` which fires AFTER the sheet's slide-up
            // animation. The earlier focus claim is what stops the
            // keyboard from dismissing-then-re-presenting when the
            // palette opens over an editor whose text view is already
            // first responder — the system reads it as a transfer
            // between two text fields and the keyboard slides directly
            // from one to the other.
            .defaultFocus($fieldFocused, true)
            .onChange(of: query) { _, _ in selectionIndex = 0 }
            .onChange(of: selectedGroup) { _, _ in selectionIndex = 0 }
        }
        // Sized roughly like a Spotlight panel — comfortable for
        // typing and a list of ~10 visible matches.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Subviews

    private var searchField: some View {
        TextField(searchPrompt, text: $query)
            .textFieldStyle(.plain)
            .font(.title3)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .focused($fieldFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit { runSelected() }
            .onKeyPress(.upArrow) {
                selectionIndex = max(0, selectionIndex - 1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                selectionIndex = min(currentRowCount - 1, selectionIndex + 1)
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
    }

    /// Search box prompt mirrors current view — generic at root, scoped
    /// when inside a group, "Search all commands…" when typing has
    /// already escaped the drill-down.
    private var searchPrompt: String {
        if let group = selectedGroup, !isSearching {
            return "Search \(group.rawValue) commands…"
        }
        return "Type a command…"
    }

    private var navTitle: String {
        if isSearching { return "Command Palette" }
        return selectedGroup?.rawValue ?? "Command Palette"
    }

    /// Root browse view: list of top-level menu groups. Each row
    /// drills into the group's commands. Modelled after the iPad
    /// menu-bar order so muscle memory transfers.
    private var groupBrowseList: some View {
        List {
            ForEach(Array(MenuGroup.allCases.enumerated()), id: \.element.id) { index, group in
                Button {
                    selectionIndex = 0
                    withAnimation(.snappy) { selectedGroup = group }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: group.icon)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.rawValue).foregroundStyle(.primary)
                            Text("\(commandCount(in: group)) commands")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(index == selectionIndex ? Color.accentColor.opacity(0.15) : Color.clear)
            }
        }
        .listStyle(.plain)
    }

    /// Drilled-into-group view: list of commands in the chosen group,
    /// rendered the same way as the flat search results so the row
    /// styling stays consistent.
    private func groupCommandsList(group: MenuGroup) -> some View {
        List(Array(commands(in: group).enumerated()), id: \.element.id) { index, command in
            commandRow(command: command, index: index)
        }
        .listStyle(.plain)
    }

    private var flatResultsList: some View {
        List(Array(filtered.enumerated()), id: \.element.id) { index, command in
            commandRow(command: command, index: index)
        }
        .listStyle(.plain)
    }

    private func commandRow(command: EditorCommandSpec, index: Int) -> some View {
        Button {
            selectionIndex = index
            run(command)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title).foregroundStyle(.primary)
                    Text(command.category.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let hint = command.shortcutHint {
                    Text(hint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                }
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(index == selectionIndex ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    // MARK: - Data

    private var isSearching: Bool { !query.isEmpty }

    /// Row identity at `index` in whichever list is showing — the
    /// scrollTo target for keyboard navigation.
    private func rowID(at index: Int) -> String? {
        if isSearching {
            let list = filtered
            return list.indices.contains(index) ? list[index].id : nil
        }
        if let group = selectedGroup {
            let list = commands(in: group)
            return list.indices.contains(index) ? list[index].id : nil
        }
        let groups = MenuGroup.allCases
        return groups.indices.contains(index) ? groups[index].id : nil
    }

    /// Active row count for ↑/↓ keyboard navigation bounds. Different
    /// list per mode (groups vs. group commands vs. flat search).
    private var currentRowCount: Int {
        if isSearching { return filtered.count }
        if let group = selectedGroup { return commands(in: group).count }
        return MenuGroup.allCases.count
    }

    private var filtered: [EditorCommandSpec] {
        // The palette intentionally ignores `isEnabled()` so every
        // registered command is reachable, even when the active
        // editor is detached.
        if query.isEmpty { return allCommands }
        return allCommands
            .compactMap { cmd -> (EditorCommandSpec, Int)? in
                guard let score = FuzzyMatcher.bestScore(query, against: cmd) else { return nil }
                return (cmd, score)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    private func commands(in group: MenuGroup) -> [EditorCommandSpec] {
        allCommands.filter { MenuGroup.from(category: $0.category) == group }
    }

    private func commandCount(in group: MenuGroup) -> Int {
        commands(in: group).count
    }

    // MARK: - Actions

    private func runSelected() {
        if isSearching {
            let list = filtered
            guard list.indices.contains(selectionIndex) else { return }
            run(list[selectionIndex])
            return
        }
        if let group = selectedGroup {
            let list = commands(in: group)
            guard list.indices.contains(selectionIndex) else { return }
            run(list[selectionIndex])
            return
        }
        // Root browse: Enter on a group drills in instead of dismissing.
        let groups = MenuGroup.allCases
        guard groups.indices.contains(selectionIndex) else { return }
        withAnimation(.snappy) { selectedGroup = groups[selectionIndex] }
        selectionIndex = 0
    }

    private func run(_ command: EditorCommandSpec) {
        onSelect(command)
        dismiss()
    }
}

// MARK: - Menu grouping

/// Top-level groups the command palette uses for its browse mode.
/// Mirrors the iPad menu-bar headings so muscle memory transfers and
/// iPhone users can discover where features live by drilling through
/// the same hierarchy they'd see on iPad.
///
/// Single source of truth for the category → group mapping — the menu
/// bar itself is hand-built in `EditorCommands.swift`, but its
/// top-level structure tracks this enum.
enum MenuGroup: String, CaseIterable, Identifiable {
    case file     = "File"
    case edit     = "Edit"
    case view     = "View"
    case search   = "Search"
    case text     = "Text"
    case markdown = "Markdown"
    case app      = "App"

    var id: String { rawValue }

    /// SF Symbol shown on the root browse row. Picked to match the
    /// iPad menu-bar mental model where applicable.
    var icon: String {
        switch self {
        case .file:     return "doc"
        case .edit:     return "pencil"
        case .view:     return "eye"
        case .search:   return "magnifyingglass"
        case .text:     return "text.alignleft"
        case .markdown: return "number"
        case .app:      return "gearshape"
        }
    }

    /// Map a registry category to its menu-bar group. Exhaustive
    /// over `CommandCategory` — a new case in the enum becomes a
    /// compile error here until it's classified.
    static func from(category: CommandCategory) -> MenuGroup {
        switch category {
        case .app:                                          return .app
        case .file:                                         return .file
        case .edit, .selection:                             return .edit
        case .search, .navigate, .bookmark:                 return .search
        case .view, .format, .inspect, .encoding, .language,
             .lineEndings, .fold, .speech, .spelling:       return .view
        case .text, .convertCase, .insert, .snippets,
             .unicode, .tools:                              return .text
        case .markdown:                                     return .markdown
        }
    }
}
