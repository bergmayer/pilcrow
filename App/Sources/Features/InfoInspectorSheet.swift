import SwiftUI
import FileEncoding
import LineEnding

/// File / Outline / Count inspector. Hosted as a SwiftUI side
/// `.inspector` from `EditorView` (toggled by the ⓘ button in the
/// bottom-right status bar) — *not* a sheet, despite the historic
/// type name. The editor remains editable while this panel is open.
struct InfoInspectorSheet: View {

    let document: PlainTextDocument
    @Bindable var state: EditorState
    let onJump: (Int) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case file = "File"
        case outline = "Outline"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .file:    "doc.text"
            case .outline: "list.bullet.indent"
            }
        }
    }

    @State private var fileAttributes: FileAttributes?
    @State private var metadataError: String?

    private struct MetadataRequest: Equatable {
        let url: URL?
        let modified: Date?
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $state.inspectorTab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            switch state.inspectorTab {
            case .file:    fileSection
            case .outline: outlineSection
            }
        }
        .task(id: MetadataRequest(url: document.fileURL, modified: document.sourceMtimeAtLoad)) {
            fileAttributes = nil
            metadataError = nil
            guard let url = document.fileURL else { return }
            do {
                let attributes = try await CoordinatedFileAccess.perform(at: url) { try FileAttributes(url: $0) }
                try Task.checkCancellation()
                fileAttributes = attributes
            } catch is CancellationError { }
            catch { metadataError = error.localizedDescription }
        }
    }

    // MARK: File

    @ViewBuilder
    private var fileSection: some View {
        let attrs = fileAttributes
        Form {
            Section("File") {
                if let metadataError {
                    Text("File information is unavailable: " + metadataError)
                        .font(.callout).foregroundStyle(.secondary)
                }
                row("Created",  value: attrs?.creationDateFormatted ?? "—")
                row("Modified", value: attrs?.modificationDateFormatted ?? "—")
                row("Size",     value: attrs?.sizeFormatted ?? sizeFromBuffer)
                row("Permissions", value: attrs?.permissionsFormatted ?? "—")
                row("Owner",    value: attrs?.owner ?? "—")
                row("Full Path", value: document.fileURL?.path ?? "Unsaved", monospaced: true, multiline: true)
            }
            if let statistics = state.writingStatistics {
                Section("Writing Statistics") {
                    row("Words", value: statistics.words.formatted())
                    row("Characters", value: statistics.characters.formatted())
                    row("Selected Words", value: statistics.selectedWords.formatted())
                    row("Selected Characters", value: statistics.selectedCharacters.formatted())
                    row("Buffer Bytes", value: statistics.bufferBytes.map { $0.formatted() } ?? "Not encodable")
                }
            }
            Section("Text Settings") {
                row("Encoding",     value: document.fileEncoding.localizedName)
                row("Line Endings", value: "\(document.lineEnding.label) (\(document.lineEnding.description))")
                row("Language",     value: LanguageRegistry.displayName(for: state.languageIdentifier))
            }
            Section("Window Appearance") {
                // Local overrides — each picker wins over the
                // matching Settings ▸ Appearance / Font preference
                // for THIS tab only. "Inherit Global" on any row
                // clears that row's override so future Settings
                // changes for it propagate again. Per-tab — a fresh
                // open of the same file in a new tab does NOT
                // inherit these choices.
                Picker("Theme", selection: windowThemeBinding) {
                    Text("Inherit Global").tag(WindowThemeChoice.inherit)
                    Divider()
                    ForEach(AppThemeName.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(WindowThemeChoice.override(theme))
                    }
                }
                Picker("Font", selection: windowFontBinding) {
                    Text("Inherit Global").tag(WindowFontChoice.inherit)
                    Divider()
                    ForEach(EditorFont.allCases, id: \.self) { face in
                        Text(face.rawValue).tag(WindowFontChoice.override(face))
                    }
                }
                HStack {
                    Text("Font Size")
                    Spacer()
                    if state.fontSizeOverride != nil {
                        Button("Inherit Global") {
                            state.fontSizeOverride = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                    Stepper(value: windowFontSizeBinding, in: 9...96, step: 1) {
                        Text("\(Int(state.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 50, alignment: .trailing)
                    }
                    .labelsHidden()
                }
                if state.themeOverride != nil || state.fontOverride != nil || state.fontSizeOverride != nil {
                    Text("This window is using one or more custom appearance settings. Settings ▸ Appearance changes won't apply here until you switch the matching row back to Inherit Global.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `.inherit` clears the per-window override and `state.font` falls
    /// back through to the global pref automatically; `.override(face)`
    /// promotes the override and `state.font` resolves to it.
    private var windowFontBinding: Binding<WindowFontChoice> {
        Binding(
            get: {
                if let override = state.fontOverride { return .override(override) }
                return .inherit
            },
            set: { choice in
                switch choice {
                case .inherit:           state.fontOverride = nil
                case .override(let f):   state.fontOverride = f
                }
            }
        )
    }

    /// Every stepper change writes the override (so user intent isn't
    /// inherited back from global on the next Settings change). The
    /// "Inherit Global" button next to it explicitly clears the override.
    private var windowFontSizeBinding: Binding<Double> {
        Binding(
            get: { state.fontSize },
            set: { state.fontSizeOverride = $0 }
        )
    }

    private enum WindowFontChoice: Hashable {
        case inherit
        case override(EditorFont)
    }

    /// `.inherit` clears the per-window override and `state.themeName`
    /// falls back through to the global pref automatically.
    private var windowThemeBinding: Binding<WindowThemeChoice> {
        Binding(
            get: {
                if let override = state.themeOverride { return .override(override) }
                return .inherit
            },
            set: { choice in
                switch choice {
                case .inherit:             state.themeOverride = nil
                case .override(let theme): state.themeOverride = theme
                }
            }
        )
    }

    /// Picker selection model — either "use whatever global says" or
    /// a specific named override. Hashable for SwiftUI tagging.
    private enum WindowThemeChoice: Hashable {
        case inherit
        case override(AppThemeName)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, monospaced: Bool = false, multiline: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .lineLimit(multiline ? nil : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var sizeFromBuffer: String {
        let bytes = document.originalData?.count ?? document.text.utf8.count
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Outline

    @ViewBuilder
    private var outlineSection: some View {
        let entries = OutlineDiscovery.entries(in: document.text as NSString, language: state.languageIdentifier)
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No outline",
                    systemImage: "list.bullet.indent",
                    description: Text(state.languageIdentifier == .markdown
                                      ? "Add `# Heading` lines to build an outline."
                                      : "No symbols found at this document's language.")
                )
            } else {
                List(entries) { entry in
                    Button {
                        onJump(entry.row + 1)
                    } label: {
                        HStack(spacing: 8) {
                            // Indent by level. Level 1 sits at the left edge;
                            // level N is offset by (N-1) × 14 pt so nested
                            // sections visually nest like in Finder.
                            Spacer().frame(width: CGFloat(entry.level - 1) * 14)
                            Image(systemName: "number")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                            Text(entry.title.isEmpty ? "(empty)" : entry.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(entry.row + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

}

// MARK: - File metadata helper

private struct FileAttributes: Sendable {
    let creationDateFormatted: String
    let modificationDateFormatted: String
    let sizeFormatted: String
    let permissionsFormatted: String
    let owner: String

    init(url: URL) throws {
        let raw = try FileManager.default.attributesOfItem(atPath: url.path)
        let dateStyle = Date.FormatStyle(date: .long, time: .shortened)
        self.creationDateFormatted = (raw[.creationDate] as? Date)?.formatted(dateStyle) ?? "—"
        self.modificationDateFormatted = (raw[.modificationDate] as? Date)?.formatted(dateStyle) ?? "—"
        if let size = raw[.size] as? Int {
            self.sizeFormatted = "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size.formatted(.number)) bytes)"
        } else {
            self.sizeFormatted = "—"
        }
        if let perms = raw[.posixPermissions] as? NSNumber {
            let octal = String(perms.intValue, radix: 8)
            self.permissionsFormatted = "\(octal) (\(symbolicPermissions(perms.intValue)))"
        } else {
            self.permissionsFormatted = "—"
        }
        self.owner = raw[.ownerAccountName] as? String ?? "—"
    }
}

/// Convert a POSIX mode integer to the `rwxrwxrwx` style used by `ls`.
private func symbolicPermissions(_ mode: Int) -> String {
    var s = ""
    for shift in [6, 3, 0] {
        let bits = (mode >> shift) & 0b111
        s += (bits & 0b100 != 0) ? "r" : "-"
        s += (bits & 0b010 != 0) ? "w" : "-"
        s += (bits & 0b001 != 0) ? "x" : "-"
    }
    return s
}
