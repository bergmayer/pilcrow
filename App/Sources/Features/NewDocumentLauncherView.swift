import SwiftUI
import UIKit

/// Start screen for a new or emptied window. Each creation choice fills
/// the current tab; recovery can also restore an entire closed window.
struct NewDocumentLauncherView: View {

    let session: EditorSession

    let onPickBlank: () -> Void
    let onPickTemplate: (TemplateRecord) -> Void
    let onPickOpenFile: () -> Void
    /// Seeds a fresh editor tab with the system pasteboard contents.
    /// Disabled when the pasteboard has no string payload.
    let onPickClipboard: (String) -> Void
    /// `true` when this launcher is the only tab in the window —
    /// drives the header copy ("New Window" vs "New Tab"). The
    /// distinction is purely cosmetic: the surface and the picks
    /// behave identically either way.
    let isWindowScopeLauncher: Bool
    /// Closes this launcher surface without picking anything. The
    /// scene routes it to the same close path as ⌘W. Only offered
    /// when other tabs remain to return to.
    let onCancel: () -> Void
    /// `false` when this launcher is filling the window's empty
    /// state (no real tabs left) — there's nothing meaningful to
    /// cancel back to, so the Cancel chip is hidden.
    let showsCancel: Bool

    /// Refreshed on each appear — the user may have deleted a draft
    /// in another window or saved one out of the recovery pool.
    @State private var templates: [TemplateRecord] = []
    @State private var drafts: [DraftRecord] = []
    @Bindable private var closedWindows = ClosedWindowsStore.shared
    @State private var showingRecovery = false
    /// Snapshot of `UIPasteboard.general.hasStrings` at refresh time
    /// so the "From Clipboard" row can disable itself when there's
    /// nothing to paste.
    @State private var hasClipboardText: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Outer wash sets the chrome backdrop; the actual launcher
        // floats as a centered card with its own padding so the
        // surface feels contained within the tab rather than
        // taking over the whole pane.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                documentActions
                recoverySection
                templatesSection
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            hasClipboardText = UIPasteboard.general.hasStrings
        }
        .onChange(of: closedWindows.records.map(\.id)) { _, _ in
            refreshRecovery()
        }
        .sheet(isPresented: $showingRecovery, onDismiss: refreshRecovery) {
            DraftsRecoverySheet(owner: session)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isWindowScopeLauncher ? "New Window" : "New Tab")
                    .font(.title2.weight(.semibold))
                Text("Start writing, use the clipboard, or open a file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if showsCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Recoverable work

    private var recoveryCatalog: RecoverableWorkCatalog {
        RecoverableWorkCatalog(
            drafts: drafts,
            closedWindows: closedWindows.records,
            excludedDraftFilenames: openDraftFilenames
        )
    }

    private var openDraftFilenames: Set<String> {
        Set(AppStateBus.shared.scenes.allOpenSessions.flatMap { session in
            session.tabs.flatMap(\.document.liveRecoveryFilenames)
        })
    }

    @ViewBuilder
    private var recoverySection: some View {
        if !recoveryCatalog.isEmpty {
            Button { showingRecovery = true } label: {
                actionRow(
                    symbol: "clock.arrow.circlepath",
                    title: "Recover Unsaved Changes…",
                    detail: "Some previous work could not be reopened automatically.",
                    enabled: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func refresh() {
        templates = TemplatesStore.shared.loadAll()
        hasClipboardText = UIPasteboard.general.hasStrings
        refreshRecovery()
    }

    private func refreshRecovery() {
        let loaded = DraftsStore.shared.loadAll()
        let catalog = RecoverableWorkCatalog(
            drafts: loaded,
            closedWindows: closedWindows.records,
            excludedDraftFilenames: openDraftFilenames
        )
        closedWindows.pruneInvalidRecords(catalog.invalidWindowIDs)
        drafts = loaded
    }

    // MARK: Templates

    @ViewBuilder
    private var templatesSection: some View {
        sectionHeader("Templates", systemImage: "doc.badge.plus")
        if templates.isEmpty {
            emptyCard(
                "No templates yet",
                detail: "Drop files into the Documents/Templates folder via Files.app to add your own."
            )
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                spacing: 8
            ) {
                ForEach(templates) { template in
                    Button {
                        onPickTemplate(template)
                    } label: {
                        templateCard(template)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func templateCard(_ template: TemplateRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: template.symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(template.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(template.url.lastPathComponent)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
    }

    // MARK: Create or open a document

    @ViewBuilder
    private var documentActions: some View {
        VStack(spacing: 0) {
            Button(action: onPickBlank) {
                actionRow(
                    symbol: "doc.badge.plus",
                    title: "Blank Document",
                    detail: "Start writing in a new text document.",
                    enabled: true
                )
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 54)
            openFileRow
            Divider().padding(.leading, 54)
            clipboardRow
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var openFileRow: some View {
        Button(action: onPickOpenFile) {
            actionRow(
                symbol: "folder",
                title: "Open File…",
                detail: "Browse the Files app for an existing document.",
                enabled: true
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var clipboardRow: some View {
        Button {
            // Read live at tap time — `hasClipboardText` only gates
            // the row's enabled state; the actual bytes may differ
            // if another app copied something between refresh and
            // the user's tap.
            guard let text = UIPasteboard.general.string,
                  !text.isEmpty else { return }
            onPickClipboard(text)
        } label: {
            actionRow(
                symbol: "doc.on.clipboard",
                title: "From Clipboard",
                detail: hasClipboardText
                    ? "Start a tab seeded with the current clipboard text."
                    : "Copy text in any app, then come back here.",
                enabled: hasClipboardText
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasClipboardText)
    }

    @ViewBuilder
    private func actionRow(symbol: String, title: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: Shared chrome

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    @ViewBuilder
    private func emptyCard(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
