import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Standalone file-browser scene, hosted in its own `WindowGroup` so
/// File → Open feels like the iPad "Files" app — a real window with
/// a full document browser, not a modal sheet on top of an editor.
///
/// On pick, the URL is routed through `AppStateBus.routeOpenURL` so
/// the file opens in a fresh editor window (the multi-window default
/// the user wants). The browser window stays open so the user can
/// keep picking files without having to reopen it each time.
struct FileBrowserScene: View {

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        FileBrowserWithRecovery(
            dismiss: { dismissWindow(id: SceneID.fileBrowser.rawValue) }
        )
            .ignoresSafeArea()
            .onAppear {
                // Same dismiss-on-restore guard the palette uses so
                // iPadOS doesn't relaunch the app into the file
                // browser after the user quit while it was open.
                if !AppStateBus.shared.scenes.consumeOpen(.fileBrowser) {
                    AppStateBus.shared.scenes.openWindow?(.editor)
                    dismissWindow(id: SceneID.fileBrowser.rawValue)
                }
            }
    }
}

/// Sheet variant of the file browser, presented on the active
/// editor scene when the user's `DocumentDestination` is `.tab`.
/// Same browser UI; the dismiss action comes from the sheet's own
/// environment instead of `dismissWindow`.
struct FileBrowserSheetView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FileBrowserWithRecovery(dismiss: { dismiss() })
            .ignoresSafeArea()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }
}

/// In-tab browser content — the tab itself hosts the document
/// browser. On pick, `onPick` flips the tab back to `.editor` and
/// loads the URL. `onCancel` lets the user back out to a blank editor
/// without picking anything: a thin header bar above the browser
/// hosts the "Back" button so the user always has a way out of the
/// without closing the tab entirely.
struct FileBrowserTabContent: View {

    let onPick: (URL) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("Open File")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Symmetry placeholder so the title stays centered —
                // same footprint as the Back button on the leading edge.
                Color.clear
                    .frame(width: 64, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            FileBrowserWithRecovery(
                dismiss: { /* no-op: the tab outlives the pick */ },
                onPick: onPick
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Adds app-owned recovery access immediately above the system document
/// browser's Recents/Browse surface. `UIDocumentBrowserViewController`
/// doesn't expose an API for inserting custom rows into its Recents list,
/// so this persistent bar is the nearest native-safe placement.
private struct FileBrowserWithRecovery: View {

    let dismiss: () -> Void
    var onPick: ((URL) -> Void)?

    @State private var drafts: [DraftRecord] = []
    @State private var showingRecovery = false
    @Bindable private var closedWindows = ClosedWindowsStore.shared

    private var catalog: RecoverableWorkCatalog {
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

    private var recoveryCount: Int {
        catalog.windows.count + catalog.drafts.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                showingRecovery = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .font(.title3)
                        .foregroundStyle(recoveryCount == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recoverable Work")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(recoveryDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if recoveryCount > 0 {
                        Text("Review")
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Divider()

            FileBrowserRepresentable(dismiss: dismiss, onPick: onPick)
        }
        .background(.bar)
        .onAppear(perform: refreshRecovery)
        .onChange(of: closedWindows.records.map(\.id)) { _, _ in
            refreshRecovery()
        }
        .sheet(isPresented: $showingRecovery, onDismiss: refreshRecovery) {
            DraftsRecoverySheet()
        }
    }

    private var recoveryDetail: String {
        switch recoveryCount {
        case 0: return "Nothing to recover"
        case 1: return "1 item available"
        default: return "\(recoveryCount) items available"
        }
    }

    private func refreshRecovery() {
        let loaded = DraftsStore.shared.loadAll()
        let normalized = RecoverableWorkCatalog(
            drafts: loaded,
            closedWindows: closedWindows.records,
            excludedDraftFilenames: openDraftFilenames
        )
        closedWindows.pruneInvalidRecords(normalized.invalidWindowIDs)
        drafts = loaded
    }
}

struct FileBrowserRepresentable: UIViewControllerRepresentable {

    /// Closure that closes this window. Called after a successful pick
    /// so the user doesn't end up with one stranded file-browser
    /// window per Open — each pick should replace this window with the
    /// new editor scene, not stack on top of it.
    let dismiss: () -> Void

    /// Optional override for what happens on pick. When non-nil, this
    /// fires instead of the default "route via AppStateBus" path —
    /// used by the in-tab browser variant so picks transform the
    /// hosting tab in place rather than spawning a new scene.
    var onPick: ((URL) -> Void)?

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(
            forOpening: PlainTextDocument.supportedReadTypes
        )
        // We have a dedicated File → New menu item; the browser is
        // strictly for opening existing files.
        browser.allowsDocumentCreation = false
        browser.allowsPickingMultipleItems = false
        browser.shouldShowFileExtensions = true
        browser.delegate = context.coordinator
        return browser
    }

    func updateUIViewController(_ vc: UIDocumentBrowserViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        let dismissCallback = dismiss
        let pickCallback = onPick
        return Coordinator(
            dismiss: { @MainActor in dismissCallback() },
            onPick: pickCallback.map { fn in { @MainActor url in fn(url) } }
        )
    }

    /// Delegate is nonisolated to satisfy the protocol requirement
    /// (UIDocumentBrowserViewControllerDelegate methods are not
    /// declared `@MainActor`). Each callback hops to the main actor
    /// before touching `AppStateBus`.
    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {

        /// Captured at init time. Dismisses the host file-browser
        /// window once a pick has been routed — keeps the user from
        /// accumulating stranded picker windows.
        private let dismiss: @MainActor () -> Void
        /// Optional per-pick override. When non-nil, fires instead of
        /// `Self.route(url)`; the in-tab browser uses this to
        /// transform its hosting tab in place.
        private let onPick: (@MainActor (URL) -> Void)?

        init(
            dismiss: @escaping @MainActor () -> Void,
            onPick: (@MainActor (URL) -> Void)?
        ) {
            self.dismiss = dismiss
            self.onPick = onPick
        }

        nonisolated func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didPickDocumentsAt documentURLs: [URL]
        ) {
            documentURLs.first.map(handlePick)
        }

        nonisolated func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didImportDocumentAt sourceURL: URL,
            toDestinationURL destinationURL: URL
        ) {
            handlePick(destinationURL)
        }

        /// Common path for pick + import. Default behaviour: route the
        /// URL through `AppStateBus` (which spawns a new scene or
        /// adds a tab per the destination override) and dismiss the
        /// picker window. With a custom `onPick`, the override fires
        /// instead — used by the in-tab browser to transform its
        /// hosting tab in place rather than spawning anything.
        nonisolated private func handlePick(_ url: URL) {
            let dismiss = self.dismiss
            let custom = self.onPick
            Task { @MainActor in
                if let custom {
                    custom(url)
                } else {
                    Self.route(url)
                    dismiss()
                }
            }
        }

        nonisolated func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            failedToImportDocumentAt documentURL: URL,
            error: (any Error)?
        ) {
            let message = error?.localizedDescription
                ?? "Couldn't open \(documentURL.lastPathComponent)."
            Task { @MainActor in
                AppStateBus.shared.presentation.openErrorMessage = message
            }
        }

        @MainActor
        private static func route(_ url: URL) {
            CommandActions.routeOpenURL(url)
        }
    }
}
