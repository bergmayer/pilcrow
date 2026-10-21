import SwiftUI

enum EditorChrome {
    static let commandPaletteTitle = "Command Palette"
    static let commandPaletteSymbol = "terminal"
    static let toolMenuTitle = "Tool Menu"
    static var toolItemsTitle: String { DeviceIdiom.isPhone ? "Tool Menu Items" : "Toolbar Items" }
}

// MARK: - Slot model

/// `commandId` matches `CommandRegistry.all()`.
struct ToolbarSlot: Codable, Equatable, Identifiable {
    var commandId: String
    /// SF Symbol name OR `u:HEX` for a raw codepoint (`u:1F4BE` =
    /// the floppy disk). The unicode form lets us surface non-SF
    /// glyphs at the toolbar size in monochrome.
    var symbol: String
    var id: String { commandId + "|" + symbol }
}

/// SF Symbol via name, or a raw codepoint via the `u:HEX` prefix.
/// The unicode path appends U+FE0E (text-presentation VS15) so
/// emoji-form codepoints like 💾 render in monochrome to match the
/// SF Symbols around them.
@ViewBuilder
func toolbarSymbol(_ symbol: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
    if let scalar = unicodeScalar(forSymbolRef: symbol) {
        Text(String(scalar) + "\u{FE0E}")
            .font(.system(size: size * 1.1, weight: weight))
            .foregroundStyle(.primary)
    } else {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.hierarchical)
    }
}

private func unicodeScalar(forSymbolRef ref: String) -> Unicode.Scalar? {
    guard ref.hasPrefix("u:") else { return nil }
    let hex = String(ref.dropFirst(2))
    guard let value = UInt32(hex, radix: 16),
          let scalar = Unicode.Scalar(value) else { return nil }
    return scalar
}

// MARK: - Config / persistence

/// Shared by the toolbar, slot editor, and Settings UI.
@MainActor
@Observable
final class ToolbarConfig {

    static let shared = ToolbarConfig()

    /// Broken symbol names render as a placeholder glyph at runtime.
    static let defaults: [ToolbarSlot] = [
        .init(commandId: "find",      symbol: "magnifyingglass"),
        .init(commandId: "findRepl",  symbol: "arrow.triangle.2.circlepath"),
        .init(commandId: "gotoLine",  symbol: "arrow.down.to.line.compact"),
        .init(commandId: "comment",   symbol: "number"),
        .init(commandId: "indent",    symbol: "increase.indent"),
        .init(commandId: "outdent",   symbol: "decrease.indent"),
        .init(commandId: "sortLines", symbol: "arrow.up.arrow.down"),
        .init(commandId: "trim",      symbol: "scissors")
    ]

    static let quickDefaults: [ToolbarSlot?] = [
        ToolbarSlot(commandId: "undo", symbol: "arrow.uturn.backward"),
        ToolbarSlot(commandId: "redo", symbol: "arrow.uturn.forward")
    ]

    private(set) var slots: [ToolbarSlot]
    private(set) var quickSlots: [ToolbarSlot?]
    private let defaultsStore: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaultsStore = defaults
        let loaded = Self.load(from: defaults) ?? Self.defaults
        let savedQuick = defaults.data(forKey: AppPreferenceKey.quickAccessSlots)
            .flatMap { try? JSONDecoder().decode([ToolbarSlot?].self, from: $0) } ?? Self.quickDefaults
        self.quickSlots = (0..<2).map { index in
            guard savedQuick.indices.contains(index), let slot = savedQuick[index],
                  CommandRegistry.lookup(id: slot.commandId) != nil else { return nil }
            return slot
        }
        self.slots = loaded.filter { CommandRegistry.lookup(id: $0.commandId) != nil }
        // Retired commands (including the former drafts browser) must not
        // leave dead buttons in a previously customized toolbar.
        if slots != loaded { save() }
    }

    func setSlots(_ newSlots: [ToolbarSlot]) {
        slots = newSlots
        save()
    }

    func update(slotAt index: Int, commandId: String, symbol: String) {
        guard slots.indices.contains(index) else { return }
        slots[index] = ToolbarSlot(commandId: commandId, symbol: symbol)
        save()
    }

    func insert(_ slot: ToolbarSlot, at index: Int? = nil) {
        if let index, slots.indices.contains(index) {
            slots.insert(slot, at: index)
        } else {
            slots.append(slot)
        }
        save()
    }

    func remove(at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots.remove(at: index)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func resetToDefaults() {
        slots = Self.defaults
        save()
    }

    func setQuickSlot(_ slot: ToolbarSlot?, at index: Int) {
        guard quickSlots.indices.contains(index) else { return }
        quickSlots[index] = slot
        saveQuickSlots()
    }

    func resetQuickButtons() {
        quickSlots = Self.quickDefaults
        saveQuickSlots()
    }

    private func saveQuickSlots() {
        guard let data = try? JSONEncoder().encode(quickSlots) else { return }
        defaultsStore.set(data, forKey: AppPreferenceKey.quickAccessSlots)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        defaultsStore.set(data, forKey: AppPreferenceKey.toolbarSlots)
    }

    private static func load(from defaults: UserDefaults) -> [ToolbarSlot]? {
        guard let data = defaults.data(forKey: AppPreferenceKey.toolbarSlots),
              let decoded = try? JSONDecoder().decode([ToolbarSlot].self, from: data)
        else { return nil }
        return decoded
    }
}

/// The same two configurable buttons appear on iPhone and iPad.
struct QuickToolbarButtons: View {
    let onInteraction: () -> Void
    var touchTarget: CGFloat = 38
    @State private var config = ToolbarConfig.shared
    @State private var editing: QuickButtonEdit?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(config.quickSlots.enumerated()), id: \.offset) { index, slot in
                if let slot, let command = CommandRegistry.lookup(id: slot.commandId) {
                    Button {
                        onInteraction()
                        if command.isEnabled() { command.action() }
                    } label: {
                        toolbarSymbol(slot.symbol, size: 16)
                            .frame(width: touchTarget, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!command.isEnabled())
                    .accessibilityLabel(command.title)
                    .accessibilityIdentifier("quick-button-\(index + 1)")
                    .help(command.title)
                    .contextMenu {
                        Button("Customize Button \(index + 1)…") {
                            onInteraction()
                            editing = QuickButtonEdit(index: index, slot: slot)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { item in
            ToolbarSlotEditor(slotIndex: item.index, initial: item.slot,
                              title: "Quick Access Button \(item.index + 1)",
                              onSave: { config.setQuickSlot($0, at: item.index) })
        }
    }

    private struct QuickButtonEdit: Identifiable {
        let index: Int
        let slot: ToolbarSlot
        var id: Int { index }
    }
}
