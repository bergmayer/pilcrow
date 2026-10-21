import SwiftUI

/// Shared by `ToolbarSlotEditor` and `ToolbarSlotAdder`.
@ViewBuilder
@MainActor
func iconPickerRow(symbol: Binding<String>, pickingSymbol: Binding<Bool>) -> some View {
    HStack(spacing: 16) {
        toolbarSymbol(symbol.wrappedValue.isEmpty ? "questionmark.square.dashed" : symbol.wrappedValue, size: 32)
            .frame(width: 60, height: 60)
            .background(.quaternary, in: .rect(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 4) {
            Button {
                pickingSymbol.wrappedValue = true
            } label: {
                Label("Choose Symbol…", systemImage: "square.grid.2x2")
            }
            Text(symbol.wrappedValue.isEmpty ? "No symbol" : symbol.wrappedValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        Spacer()
    }
    .padding(.vertical, 4)
    .sheet(isPresented: pickingSymbol) {
        ToolbarSymbolPicker(selected: symbol)
    }
}

// MARK: - Slot editor (long-press target; also reused by Settings)

struct ToolbarSlotEditor: View {

    @Environment(\.dismiss) private var dismiss
    let slotIndex: Int
    let title: String?
    let onSave: ((ToolbarSlot) -> Void)?
    @State private var query: String = ""
    @State private var selectedCommandId: String
    @State private var symbol: String
    @State private var pickingSymbol: Bool = false

    private let allCommands: [EditorCommandSpec] = CommandRegistry.all()

    init(slotIndex: Int, initial: ToolbarSlot, title: String? = nil,
         onSave: ((ToolbarSlot) -> Void)? = nil) {
        self.slotIndex = slotIndex
        self.title = title
        self.onSave = onSave
        _selectedCommandId = State(initialValue: initial.commandId)
        _symbol = State(initialValue: initial.symbol)
    }

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
            .navigationTitle(title ?? "\(DeviceIdiom.isPhone ? "Tool Menu" : "Toolbar") Item \(slotIndex + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let onSave {
                            onSave(ToolbarSlot(commandId: selectedCommandId, symbol: symbol))
                        } else {
                            ToolbarConfig.shared.update(slotAt: slotIndex, commandId: selectedCommandId, symbol: symbol)
                        }
                        dismiss()
                    }
                    .disabled(selectedCommandId.isEmpty || symbol.isEmpty)
                }
            }
        }
    }

    private var filtered: [EditorCommandSpec] {
        if query.isEmpty {
            let head = allCommands.filter { $0.id == selectedCommandId }
            let rest = allCommands.filter { $0.id != selectedCommandId }
            return Array((head + rest).prefix(80))
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
