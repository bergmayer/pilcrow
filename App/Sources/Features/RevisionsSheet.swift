import SwiftUI

/// Browser for a document's revision history. Lists every snapshot
/// the `RevisionStore` has captured for the current file (most recent
/// first), lets the user preview any entry, and reverts the buffer
/// back to that snapshot.
///
/// Revert just loads the snapshot text into the live buffer and
/// marks it dirty — the next auto-save (or ⌘S) commits the reverted
/// state to disk. That keeps the revert one-undo away from being
/// taken back if the user changes their mind.
struct RevisionsSheet: View {

    @Environment(\.dismiss) private var dismiss
    let document: PlainTextDocument

    @State private var entries: [RevisionStore.Entry] = []
    @State private var selection: RevisionStore.Entry.ID?
    @State private var previewText: String?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Revisions Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Start typing — the editor snapshots your work as you go. Saving the file to disk adds an \"Original\" anchor you can revert all the way back to.")
                    )
                } else {
                    splitBody
                }
            }
            .navigationTitle("Revisions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Revert to Original") {
                        revertToOriginal()
                    }
                    .disabled(originalEntry == nil)
                }
            }
            .onAppear(perform: reload)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var splitBody: some View {
        List(selection: $selection) {
            ForEach(entriesDisplayOrder) { entry in
                row(for: entry)
                    .tag(entry.id)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if let selected = selectedEntry {
                detailFooter(for: selected)
            }
        }
        .onChange(of: selection) { _, _ in loadPreview() }
    }

    @ViewBuilder
    private func row(for entry: RevisionStore.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(for: entry.kind))
                .foregroundStyle(tint(for: entry.kind))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label(for: entry.kind))
                        .font(.callout)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(Self.timestampFormatter.string(from: entry.timestamp))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !entry.preview.isEmpty {
                    Text(entry.preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Text(Self.byteFormatter.string(fromByteCount: Int64(entry.byteSize)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func detailFooter(for entry: RevisionStore.Entry) -> some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text(label(for: entry.kind))
                    .font(.headline)
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert to This Revision") {
                    revert(to: entry)
                }
                .buttonStyle(.borderedProminent)
            }
            ScrollView {
                Text(previewText ?? "Loading…")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
            .background(.quaternary, in: .rect(cornerRadius: 6))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(.bar)
    }

    // MARK: - Data

    private var entriesDisplayOrder: [RevisionStore.Entry] {
        entries.sorted { $0.timestamp > $1.timestamp }
    }

    private var selectedEntry: RevisionStore.Entry? {
        entries.first { $0.id == selection }
    }

    private var originalEntry: RevisionStore.Entry? {
        entries.first { $0.kind == .original }
    }

    private func reload() {
        let key = document.revisionKey
        Task {
            entries = await RevisionStore.shared.entries(forKey: key)
            if selection == nil {
                selection = entriesDisplayOrder.first?.id
            }
            loadPreview()
        }
    }

    private func loadPreview() {
        guard let entry = selectedEntry else {
            previewText = nil
            return
        }
        let key = document.revisionKey
        previewText = nil
        Task {
            let text = await RevisionStore.shared.loadText(of: entry, forKey: key) ?? ""
            guard selection == entry.id else { return }
            previewText = text
        }
    }

    // MARK: - Actions

    private func revert(to entry: RevisionStore.Entry) {
        let key = document.revisionKey
        Task {
            guard let text = await RevisionStore.shared.loadText(of: entry, forKey: key) else {
                return
            }
            document.text = text
            document.isDirty = true
            document.bufferRevision &+= 1
            // `currentEditor` can point at a different window than the one
            // that presented this sheet — push into the owning editor.
            if let editor = owningEditorState {
                editor.text = text
                editor.setText?(text)
            }
            document.autoSave()
            dismiss()
        }
    }

    /// The editor state for the tab that owns `document`, found via
    /// the bus's open-session registry.
    private var owningEditorState: EditorState? {
        for session in AppStateBus.shared.scenes.allOpenSessions {
            if let tab = session.tabs.first(where: { $0.document === document }) {
                return tab.state
            }
        }
        return nil
    }

    private func revertToOriginal() {
        guard let entry = originalEntry else { return }
        revert(to: entry)
    }

    // MARK: - Format helpers

    private func icon(for kind: RevisionStore.Kind) -> String {
        switch kind {
        case .original: "flag.fill"
        case .auto:     "bolt.fill"
        case .manual:   "pencil.circle.fill"
        }
    }

    private func tint(for kind: RevisionStore.Kind) -> Color {
        switch kind {
        case .original: .orange
        case .auto:     .secondary
        case .manual:   .blue
        }
    }

    private func label(for kind: RevisionStore.Kind) -> String {
        switch kind {
        case .original: "Original"
        case .auto:     "Auto-save"
        case .manual:   "Manual save"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB]
        f.countStyle = .file
        return f
    }()
}
