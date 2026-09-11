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
    let request: UtilityWindowRequest?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        FileBrowserRepresentable(
            dismiss: { dismissWindow() }
        )
            .ignoresSafeArea()
            .onAppear {
                // Same dismiss-on-restore guard the palette uses so
                // iPadOS doesn't relaunch the app into the file
                // browser after the user quit while it was open.
                if request?.launchID != SessionsStore.shared.currentLaunchID {
                    openWindow(id: SceneID.editor.rawValue, value: EditorRoute.newDocument())
                    dismissWindow()
                }
            }
    }
}

/// Sheet variant of the file browser, presented on the active
/// editor scene when the user's `DocumentDestination` is `.tab`.
/// Same browser UI; the dismiss action comes from the sheet's own
/// environment instead of `dismissWindow`.
struct FileBrowserSheetView: View {
    let owner: EditorSession?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FileBrowserRepresentable(dismiss: { dismiss() }, onPick: { [weak owner] url in
            guard let owner, AppStateBus.shared.scenes.allOpenSessions.contains(where: { $0 === owner }) else { return }
            CommandActions.routeOpenURL(url, in: owner, destination: .tab)
            dismiss()
        })
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

            FileBrowserRepresentable(
                dismiss: { /* no-op: the tab outlives the pick */ },
                onPick: onPick
            )
            .ignoresSafeArea(edges: .bottom)
        }
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
            CommandActions.routeOpenURL(url, destination: .window)
        }
    }
}
