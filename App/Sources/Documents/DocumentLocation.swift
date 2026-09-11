import Foundation
import FileProvider

/// Builds a human-readable breadcrumb for a file URL's enclosing
/// location (e.g. "Nextcloud › Documents › Notes", "iCloud Drive › 2026",
/// "On My iPad"). Used by the editor's window title-bar subtitle.
@MainActor
enum DocumentLocation {

    /// `NSFileProviderDomain.displayName` indexed by the domain's
    /// document-storage root path. Populated lazily by
    /// `loadDomainsIfNeeded()` and re-used on every `describe(...)`.
    /// The display name comes from the provider's bundle (the
    /// Nextcloud iOS app declares its own `displayName` — typically
    /// "Nextcloud") so we don't have to hard-code a lookup table for
    /// the names the user actually sees in the Files app.
    private static var providerCache: [(prefix: String, displayName: String)] = []
    private static var didStartLoadingDomains = false

    /// Kick the async `NSFileProviderManager.domains` lookup if it
    /// hasn't run yet. Safe to call from `describe(...)` on every
    /// render — the guard short-circuits after the first call.
    private static func loadDomainsIfNeeded() {
        guard !didStartLoadingDomains else { return }
        didStartLoadingDomains = true
        Task { @MainActor in
            await refreshProviderCache()
        }
    }

    /// Re-populate `providerCache` from the system. Called once at
    /// first `describe(...)`, and again on app foregrounding so newly
    /// installed File Provider apps (Nextcloud, OneDrive, etc.) get
    /// picked up without an app relaunch.
    static func refreshProviderCache() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            var fresh: [(prefix: String, displayName: String)] = []
            for domain in domains {
                guard let manager = NSFileProviderManager(for: domain) else { continue }
                let storage: URL
                do {
                    storage = try await manager.getUserVisibleURL(for: .rootContainer)
                } catch {
                    continue
                }
                // Trailing slash so `hasPrefix` doesn't match a sibling
                // directory whose name happens to share the storage
                // path's prefix.
                let prefix = storage.path.hasSuffix("/") ? storage.path : storage.path + "/"
                fresh.append((prefix: prefix, displayName: domain.displayName))
            }
            // Longest-prefix-first so a nested provider domain wins
            // over its parent's storage root.
            fresh.sort { $0.prefix.count > $1.prefix.count }
            providerCache = fresh
        } catch {
            // Best-effort — describe() falls back to the path-shape
            // heuristics if the cache is empty.
        }
    }

    /// Describe the *parent* directory of `url` as a human breadcrumb.
    /// Returns an empty string when the URL has no meaningful parent.
    static func describe(parentOf url: URL) -> String {
        loadDomainsIfNeeded()
        let parent = url.deletingLastPathComponent()

        // 0. File Provider lookup — preferred when the URL falls
        //    inside a known provider's user-visible root. The display
        //    name comes from the provider extension itself, so
        //    Nextcloud's Files-app entry "Nextcloud" wins over the
        //    folder-name heuristic that previously surfaced the
        //    account login (e.g. "admin").
        if let displayName = providerDisplayName(forPathIn: parent) {
            let remainder = remainingPath(of: parent, afterProviderPrefix: providerPrefix(for: parent))
            return joining([displayName] + remainder)
        }

        let components = parent.pathComponents

        // 1. iCloud Drive — files materialised under "Mobile Documents".
        if let i = components.firstIndex(of: "Mobile Documents"),
           i + 1 < components.count {
            let providerToken = components[i + 1]
            let rest = Array(components.dropFirst(i + 2))
            let providerName = iCloudFriendlyName(providerToken)
            return joining([providerName] + rest)
        }

        // 2. iPadOS CloudStorage path — used since iOS 18 for many
        //    third-party providers (Nextcloud, OneDrive, Google Drive).
        //    Path looks like:
        //      .../Library/CloudStorage/<ProviderName>-<account>/<sub-path>
        if let i = components.firstIndex(of: "CloudStorage"),
           i + 1 < components.count {
            let providerName = friendlyProviderName(components[i + 1])
            let rest = Array(components.dropFirst(i + 2))
            return joining([providerName] + rest)
        }

        // 3. Third-party File Provider — older Files-app integration.
        //    Path looks like:
        //      .../File Provider Storage/<provider-bundle-id>/<sub-path>
        if let i = components.firstIndex(of: "File Provider Storage"),
           i + 1 < components.count {
            let providerName = friendlyProviderName(components[i + 1])
            let rest = Array(components.dropFirst(i + 2))
            return joining([providerName] + rest)
        }

        // 4. App's own Documents directory — match the device's Files label.
        if let i = components.firstIndex(of: "Application"),
           let docsIdx = components.dropFirst(i).firstIndex(of: "Documents") {
            let rest = Array(components.dropFirst(docsIdx + 1))
            return joining([DeviceIdiom.isPhone ? "On My iPhone" : "On My iPad"] + rest)
        }

        // 5. Anything else — strip sandbox noise and join what's left.
        let cleaned = components.drop(while: { component in
            sandboxNoise.contains(component) || isLikelyUUID(component)
        })
        return cleaned.joined(separator: " › ")
    }

    private static func providerDisplayName(forPathIn url: URL) -> String? {
        let path = url.path
        for entry in providerCache where path == String(entry.prefix.dropLast())
                                     || path.hasPrefix(entry.prefix) {
            return entry.displayName
        }
        return nil
    }

    private static func providerPrefix(for url: URL) -> String {
        let path = url.path
        for entry in providerCache where path == String(entry.prefix.dropLast())
                                     || path.hasPrefix(entry.prefix) {
            return entry.prefix
        }
        return ""
    }

    private static func remainingPath(of url: URL, afterProviderPrefix prefix: String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let path = url.path
        guard path.count >= prefix.count - 1 else { return [] }
        let trimmed = String(path.dropFirst(min(prefix.count, path.count)))
        return trimmed.split(separator: "/").map(String.init)
    }

    // MARK: - Helpers

    private static func joining(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " › ")
    }

    private static let sandboxNoise: Set<String> = [
        "/", "private", "var", "mobile",
        "Containers", "Shared", "AppGroup",
        "Data", "Application", "Library"
    ]

    private static func isLikelyUUID(_ s: String) -> Bool {
        s.count == 36 && s.allSatisfy { ch in
            ch.isHexDigit || ch == "-"
        }
    }

    /// Translate a File-Provider folder name or bundle-id-ish token
    /// into the user-facing app name. Handles both styles:
    ///   * CloudStorage folder: `Nextcloud-admin@flame:8081` → `Nextcloud`
    ///   * Bundle-id token:     `com.nextcloud.files`       → `Nextcloud`
    /// Unknown tokens fall back to the head (before `-` or `.`),
    /// capitalised.
    private static func friendlyProviderName(_ token: String) -> String {
        // CloudStorage folders look like "<Provider>-<account>". The
        // account often contains the same provider name (`admin@flame…`)
        // so match the head, before the first `-`.
        let head = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? token
        let lower = head.lowercased()
        let table: [(needle: String, name: String)] = [
            ("nextcloud", "Nextcloud"),
            ("owncloud",  "ownCloud"),
            ("google", "Google Drive"),
            ("dropbox", "Dropbox"),
            ("onedrive", "OneDrive"),
            ("microsoft", "OneDrive"),
            ("box", "Box"),
            ("mega", "MEGA"),
            ("syncthing", "Syncthing"),
            ("synology", "Synology Drive"),
            ("resilio", "Resilio Sync"),
            ("pcloud", "pCloud"),
            ("yandex", "Yandex Disk"),
            ("seafile", "Seafile"),
            ("git", "Working Copy")
        ]
        for entry in table where lower.contains(entry.needle) {
            return entry.name
        }
        // Reverse-DNS bundle ids — return the last component capitalised.
        if head.contains(".") {
            let parts = head.split(separator: ".")
            if let last = parts.last { return String(last).capitalized }
        }
        return head
    }

    /// "com~apple~CloudDocs" → "iCloud Drive". Other iCloud containers
    /// keep their tilde-encoded form trimmed and capitalised.
    private static func iCloudFriendlyName(_ token: String) -> String {
        if token == "com~apple~CloudDocs" { return "iCloud Drive" }
        // Containers like "iCloud.com.bergmayer.myapp" — present the
        // last component.
        let parts = token.replacingOccurrences(of: "~", with: ".").split(separator: ".")
        if let last = parts.last { return String(last).capitalized }
        return token
    }
}
