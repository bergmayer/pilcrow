import SwiftUI

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

    private(set) var slots: [ToolbarSlot]

    private init() {
        let loaded = Self.load() ?? Self.defaults
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

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.toolbarSlots)
    }

    private static func load() -> [ToolbarSlot]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.toolbarSlots),
              let decoded = try? JSONDecoder().decode([ToolbarSlot].self, from: data)
        else { return nil }
        return decoded
    }
}
