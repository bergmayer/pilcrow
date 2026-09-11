import Foundation
import SwiftUI

/// One file in `Documents/Templates/`. Tapping the row in the
/// launcher seeds a brand-new Untitled tab with the file's bytes —
/// the template file itself is never opened, so editing the new
/// buffer never bleeds back into the template.
struct TemplateRecord: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let displayName: String
    /// SF Symbol picked from the file extension so the launcher row
    /// looks distinct (`doc.text.fill` for .txt, `text.book.closed`
    /// for .md, `tablecells` for .csv, …). Falls back to a generic
    /// document for unknown types.
    let symbol: String
}

/// First-run seeding + live enumeration of the device-local
/// `Documents/Templates/` folder. The folder is available through
/// Files because file sharing is enabled; it requires no cloud capability.
@MainActor
final class TemplatesStore {

    static let shared = TemplatesStore()

    /// Default seeds get (re-)installed here so an app update can ship
    /// new defaults, but a user-added template is never auto-deleted.
    var directory: URL {
        Self.localDocumentsURL.appendingPathComponent("Templates", isDirectory: true)
    }

    private init() {}

    private static let localDocumentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    /// Idempotent: creates the folder, writes any seed file that
    /// isn't already there. Lets the user delete a seed they don't
    /// want without it reappearing — only missing files are written.
    func seedIfNeeded() {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for seed in Self.defaultSeeds {
            let url = dir.appendingPathComponent(seed.filename)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? seed.body.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    func loadAll() -> [TemplateRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let records = urls.map { url in
            TemplateRecord(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                symbol: Self.symbol(for: url.pathExtension.lowercased())
            )
        }
        return records.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Returns the template's bytes as a String, or nil if the file
    /// vanished between enumeration and tap.
    func loadContent(_ template: TemplateRecord) -> String? {
        guard let data = try? Data(contentsOf: template.url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func symbol(for ext: String) -> String {
        switch ext {
        case "md", "markdown":     return "text.book.closed.fill"
        case "csv", "tsv":         return "tablecells.fill"
        case "json", "yaml", "yml": return "curlybraces"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "cpp", "h":
                                    return "chevron.left.forwardslash.chevron.right"
        case "html", "xml":        return "chevron.left.slash.chevron.right"
        case "txt", "":            return "doc.text.fill"
        default:                   return "doc.fill"
        }
    }

    private struct Seed {
        let filename: String
        let body: String
    }

    private static let defaultSeeds: [Seed] = [
        Seed(filename: "Blank.txt", body: ""),
        Seed(filename: "Notes.md", body: """
        # Notes

        -

        """),
        Seed(filename: "Data.csv", body: """
        column1,column2,column3
        ,,
        """)
    ]
}

/// Applies a template's bytes to an untitled editor buffer without ever
/// opening or modifying the template file itself.
@MainActor
enum TemplateWorkflow {
    static func apply(_ template: TemplateRecord, to tab: TabModel) {
        guard let body = TemplatesStore.shared.loadContent(template) else {
            AppStateBus.shared.presentation.openErrorMessage =
                "Couldn't read the template \(template.url.lastPathComponent). Choose another template or check the file in Files."
            return
        }
        tab.startDocument(with: body)
        tab.state.languageIdentifier = LanguageRegistry.identifier(for: template.url)
    }
}

/// Picker for the explicit New from Template command. The window's start
/// screen also offers templates directly.
struct TemplatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [TemplateRecord] = []

    let onPick: (TemplateRecord) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No Templates",
                        systemImage: "doc.badge.plus",
                        description: Text(
                            "Add files to Documents/Templates in Files, then reopen this picker."
                        )
                    )
                } else {
                    List(templates) { template in
                        Button {
                            onPick(template)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: template.symbol)
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.displayName)
                                        .foregroundStyle(.primary)
                                    Text(template.url.lastPathComponent)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("New from Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                TemplatesStore.shared.seedIfNeeded()
                templates = TemplatesStore.shared.loadAll()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
