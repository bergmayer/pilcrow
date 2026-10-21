import SwiftUI

struct ToolbarPreferencesTab: View {

    @Bindable private var prefs = AppPreferencesStore.shared
    @State private var config = ToolbarConfig.shared
    @State private var addingSlot: Bool = false
    @State private var editingIndex: Int?
    @State private var editingQuickIndex: Int?

    var body: some View {
        Form {
            if !DeviceIdiom.isPhone {
                Section {
                    Toggle("Show Toolbar", isOn: $prefs.showToolbar)
                }
            }

            Section {
                ForEach(Array(config.quickSlots.enumerated()), id: \.offset) { index, slot in
                    Button {
                        editingQuickIndex = index
                    } label: {
                        HStack(spacing: 12) {
                            toolbarSymbol(slot?.symbol ?? "plus.square.dashed", size: 20)
                                .frame(width: 36, height: 36)
                            Text("Button \(index + 1): \(slot.map { commandTitle(for: $0.commandId) } ?? "None")")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("quick-button-setting-\(index + 1)")
                }
                .onDelete { offsets in
                    for index in offsets { config.setQuickSlot(nil, at: index) }
                }
                Label(EditorChrome.commandPaletteTitle, systemImage: EditorChrome.commandPaletteSymbol)
                    .accessibilityLabel("Command Palette, always available")
                if DeviceIdiom.isPhone {
                    Label(EditorChrome.toolMenuTitle, systemImage: "ellipsis.rectangle")
                        .accessibilityLabel("Tool Menu, always available")
                }
                Button("Reset Quick Access Buttons to Undo and Redo") { config.resetQuickButtons() }
            } header: {
                Text("Quick Access")
            } footer: {
                Text(DeviceIdiom.isPhone
                     ? "Command Palette and Tool Menu are always available in Quick Access. Choose up to two other buttons; Undo and Redo are the defaults."
                     : "Command Palette is always available in Quick Access. Choose up to two other buttons; Undo and Redo are the defaults.")
            }

            Section(EditorChrome.toolItemsTitle) {
                ForEach(Array(config.slots.enumerated()), id: \.element.id) { index, slot in
                    Button {
                        editingIndex = index
                    } label: {
                        HStack(spacing: 12) {
                            toolbarSymbol(slot.symbol.isEmpty ? "questionmark.square.dashed" : slot.symbol, size: 20)
                                .frame(width: 36, height: 36)
                                .background(.quaternary, in: .rect(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commandTitle(for: slot.commandId))
                                    .foregroundStyle(.primary)
                                Text(slot.symbol.isEmpty ? "No symbol" : slot.symbol)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) { config.remove(at: index) }
                }
                .onMove { source, destination in
                    config.move(from: source, to: destination)
                }
            }

            Section {
                Button {
                    addingSlot = true
                } label: {
                    Label("Add Item…", systemImage: "plus.circle.fill")
                }
                Button(role: .destructive) {
                    config.resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .sheet(isPresented: $addingSlot) {
            ToolbarSlotAdder()
        }
        .sheet(item: Binding<EditingSlotID?>(
            get: { editingQuickIndex.map(EditingSlotID.init) },
            set: { editingQuickIndex = $0?.value }
        )) { wrapper in
            ToolbarSlotEditor(slotIndex: wrapper.value,
                initial: config.quickSlots[wrapper.value] ?? ToolbarSlot(commandId: "undo", symbol: "arrow.uturn.backward"),
                title: "Quick Access Button \(wrapper.value + 1)",
                onSave: { config.setQuickSlot($0, at: wrapper.value) })
        }
        .sheet(item: Binding<EditingSlotID?>(
            get: { editingIndex.map(EditingSlotID.init) },
            set: { editingIndex = $0?.value }
        )) { wrapper in
            ToolbarSlotEditor(slotIndex: wrapper.value, initial: config.slots[wrapper.value])
        }
    }

    private func commandTitle(for id: String) -> String {
        CommandRegistry.lookup(id: id)?.title ?? id
    }

    private struct EditingSlotID: Identifiable {
        let value: Int
        var id: Int { value }
    }
}

/// Fuzzy command picker + SF Symbol name. Save → ToolbarConfig.insert(_:).
private struct ToolbarSlotAdder: View {

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedCommandId: String = ""
    @State private var symbol: String = "circle"
    @State private var pickingSymbol: Bool = false

    private let allCommands: [EditorCommandSpec] = CommandRegistry.all()

    var body: some View {
        NavigationStack {
            Form {
                Section("Icon") {
                    iconPickerRow(symbol: $symbol, pickingSymbol: $pickingSymbol)
                }
                Section("Command") {
                    TextField("Search commands…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(filtered) { cmd in
                        Button {
                            selectedCommandId = cmd.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cmd.title).foregroundStyle(.primary)
                                    Text(cmd.category.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if cmd.id == selectedCommandId {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(DeviceIdiom.isPhone ? "Add Tool Menu Item" : "Add Toolbar Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        ToolbarConfig.shared.insert(ToolbarSlot(commandId: selectedCommandId, symbol: symbol))
                        dismiss()
                    }
                    .disabled(selectedCommandId.isEmpty || symbol.isEmpty)
                }
            }
        }
    }

    private var filtered: [EditorCommandSpec] {
        if query.isEmpty {
            return Array(allCommands.prefix(80))
        }
        return allCommands
            .compactMap { cmd -> (EditorCommandSpec, Int)? in
                guard let s = FuzzyMatcher.bestScore(query, against: cmd) else { return nil }
                return (cmd, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
