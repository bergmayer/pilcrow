import SwiftUI
import UIKit

@main
struct PilcrowApp: App {

    /// Bridges UIKit's quick-action callbacks (Info.plist
    /// `UIApplicationShortcutItems`) into `AppStateBus.pendingShortcut`
    /// so the SwiftUI scene system can react.
    @UIApplicationDelegateAdaptor(AppDelegateBridge.self) private var appDelegate

    init() {
        AppPreferenceDefaults.register()
        TemplatesStore.shared.seedIfNeeded()
        Task { @MainActor in
            await DraftsStore.shared.migrateLegacyRecovery()
        }
    }

    var body: some Scene {
        WindowGroup(
            "Editor",
            id: SceneID.editor.rawValue,
            for: EditorRoute.self
        ) { route in
            EditorScene(route: route)
                .background(WindowOpenerInstaller())
        }
        .commands {
            EditorCommands()
        }

        // Settings as a separate scene. On iPadOS this opens as a
        // separate window when invoked via `@Environment(\.openWindow)`.
        WindowGroup("Settings", id: SceneID.preferences.rawValue) {
            PreferencesView()
        }
        .defaultSize(width: 560, height: 460)
        .commandsRemoved()

        // Multi-File Search lives in its own scene so it stays on
        // screen while the user opens result files in editor tabs/
        // windows. Same `requestOpenWindow` / dismiss-on-restore dance
        // as the palette to keep iPadOS from restoring it as the
        // launch surface.
        WindowGroup("Multi-File Search", id: SceneID.multiFileSearch.rawValue) {
            MultiFileSearchSheet()
        }
        .defaultSize(width: 560, height: 640)
        .commandsRemoved()

        // File Browser as its own scene — the "iPad way" of opening
        // documents. UIDocumentBrowserViewController hosted in a
        // real window (not a modal sheet). The window stays open so
        // the user can pick file after file; each pick spawns a
        // new editor window via `CommandActions.routeOpenURL`.
        WindowGroup("File Browser", id: SceneID.fileBrowser.rawValue) {
            FileBrowserScene()
        }
        .defaultSize(width: 720, height: 600)
        .commandsRemoved()

        // Markdown Preview scene. Reads the focused editor's text
        // and renders it through `marked.js` in a WKWebView. The user
        // can then Share / Print → Save as PDF from the toolbar.
        WindowGroup("Markdown Preview", id: SceneID.markdownPreview.rawValue) {
            MarkdownPreviewScene()
        }
        .defaultSize(width: 720, height: 880)
        .commandsRemoved()
    }
}

/// Installed once at the editor `WindowGroup` so non-View callers
/// can spawn named scenes. SwiftUI's `openWindow` action only
/// lives inside a View body; storing it as a process-lifetime
/// closure on `SceneRouter` is the cleanest bridge.
private struct WindowOpenerInstaller: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard AppStateBus.shared.scenes.openWindow == nil else { return }
                AppStateBus.shared.scenes.openWindow = { id in
                    // New same-size windows stack exactly over an
                    // existing window at the default spot — visually
                    // confusing, but not fixable from the app: iPadOS
                    // has no window-frame API (systemFrame is
                    // Catalyst-only, SwiftUI WindowPlacement is
                    // iOS-unavailable), and routing through a UIKit
                    // activation request with
                    // UIWindowSceneProminentPlacement was tested and
                    // placed the window identically. Placement is the
                    // system's call.
                    openWindow(id: id.rawValue)
                }
                AppStateBus.shared.scenes.openEditorWindow = { route in
                    openWindow(id: SceneID.editor.rawValue, value: route)
                }
            }
    }
}

@MainActor
final class AppDelegateBridge: NSObject, UIApplicationDelegate {

    /// Captured when the process starts. The `≤ 5 s` window scopes
    /// the cold-launch filter so user-initiated window opens later
    /// in the session aren't second-guessed.
    private let processStart = Date()

    /// Flips true as soon as the first scene config is approved.
    /// Without this, a fresh install (no records, no matches) had
    /// every session destroyed and iPadOS kept spawning replacements
    /// — an instant infinite create/destroy loop on launch. The
    /// first scene per cold launch always passes; subsequent
    /// cold-launch sessions go through the record-match filter.
    private var hasAllowedAnyScene = false

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            apply(item)
        }
        // Cold-launch filter: iPadOS auto-restores every
        // `UISceneSession` in its pool, including ones the user
        // swiped away. We only keep the ones we have a backing
        // SessionRecord for — those are the involuntary-kill
        // survivors (memory pressure, reboot). User-swiped sessions
        // are gone from our store via `didDiscardSceneSessions`,
        // so they fail the check and get destroyed. After the cold-
        // launch window everything is user-initiated (⌘N, +, etc.)
        // and passes through. The "allow first scene" gate breaks
        // the otherwise infinite destroy/respawn loop on fresh
        // installs where no records exist yet.
        let isColdLaunchWindow = Date().timeIntervalSince(processStart) < 5.0
        if isColdLaunchWindow, hasAllowedAnyScene {
            let persistentId = connectingSceneSession.persistentIdentifier
            // `hasRecord(forPersistentIdentifier:)` is true only when
            // we explicitly saved a record for this session — i.e.,
            // it had content the user wants restored. An empty
            // window or a swiped-away window has no record.
            if !SessionsStore.shared.hasRecord(forPersistentIdentifier: persistentId) {
                application.requestSceneSessionDestruction(
                    connectingSceneSession,
                    options: nil,
                    errorHandler: nil
                )
            }
        }
        hasAllowedAnyScene = true
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    /// Called after iPadOS permanently discards sessions. There is no
    /// cancellable "should close" hook, so preserve any dirty window as a
    /// local Recoverable Work record before removing it from auto-restoration.
    /// If the process was not running at close time, UIKit delivers this on
    /// the next launch and the same recovery path still applies.
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        let backgroundTask = application.beginBackgroundTask(
            withName: "Archive discarded editor windows"
        )
        Task { @MainActor in
            defer {
                if backgroundTask != .invalid {
                    application.endBackgroundTask(backgroundTask)
                }
            }
            for session in sceneSessions {
                let persistentID = session.persistentIdentifier
                if let record = await recoveryRecord(forPersistentIdentifier: persistentID) {
                    _ = ClosedWindowsStore.shared.archive(record)
                    AppStateBus.shared.scenes.focusSurvivingSession(
                        excludingSceneUUID: record.sceneUUID
                    )
                }
                SessionsStore.shared.removeRecord(forPersistentIdentifier: persistentID)
                DraftsStore.shared.enforceCapNow()
            }
        }
    }

    /// When another window keeps the process alive, UIKit may deliver the
    /// discard callback while the closing EditorSession is still registered.
    /// Capture its exact live text synchronously. If teardown has already
    /// deregistered it, EditorScene.onDisappear has persisted the same
    /// information and the stored record is the fallback.
    private func recoveryRecord(
        forPersistentIdentifier persistentID: String
    ) async -> SessionRecord? {
        if let live = AppStateBus.shared.scenes.allOpenSessions.first(where: {
            SessionsStore.shared.persistentIdentifier(
                forSceneUUID: $0.sceneUUID
            ) == persistentID
        }) {
            do {
                try await DraftsStore.shared.withCapEnforcementSuspended {
                    for tab in live.tabs where tab.document.isDirty {
                        if let liveText = tab.state.textView?.text {
                            tab.document.text = liveText
                        }
                        try await tab.document.commitRecoverySnapshot()
                    }
                }
            } catch {
                AppStateBus.shared.presentation.openErrorMessage =
                    "Couldn't finish preserving a closed window: \(error.localizedDescription)"
                return SessionsStore.shared.record(
                    forPersistentIdentifier: persistentID
                )
            }
            var record = SessionRecord(scene: live.sceneUUID, session: live)
            record.persistentIdentifier = persistentID
            return record
        }
        return SessionsStore.shared.record(
            forPersistentIdentifier: persistentID
        )
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        apply(shortcutItem)
        completionHandler(true)
    }

    private func apply(_ item: UIApplicationShortcutItem) {
        guard let action = HomeShortcut(rawValue: item.type) else { return }
        AppStateBus.shared.scenes.pendingShortcut = action
    }
}
