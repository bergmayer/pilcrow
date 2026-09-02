import Foundation
import UIKit

enum AppIconChoice: String, CaseIterable, Identifiable {
    case forest
    case burgundy
    case indigo
    case ochre

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forest: "Forest"
        case .burgundy: "Burgundy"
        case .indigo: "Indigo"
        case .ochre: "Ochre"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .forest: nil
        case .burgundy: "AppIconBurgundy"
        case .indigo: "AppIconIndigo"
        case .ochre: "AppIconOchre"
        }
    }

    @MainActor
    static var current: AppIconChoice {
        switch UIApplication.shared.alternateIconName {
        case "AppIconBurgundy": .burgundy
        case "AppIconIndigo": .indigo
        case "AppIconOchre": .ochre
        default: .forest
        }
    }
}

/// Upper byte-size for syntax highlighting, fold discovery, and
/// the markdown inline decorator. Files over the limit open in
/// plain-text mode. Sentinels: `-1` = unlimited, `0` = never.
enum SyntaxLimit: Int, CaseIterable, Identifiable {
    case never  = 0
    case up1MB  = 1_048_576
    case up5MB  = 5_242_880
    case up20MB = 20_971_520
    case always = -1

    var id: Int { rawValue }
    var rawByteValue: Int { rawValue }

    var label: String {
        switch self {
        case .never:  "Never (always plain text)"
        case .up1MB:  "Up to 1 MB"
        case .up5MB:  "Up to 5 MB"
        case .up20MB: "Up to 20 MB"
        case .always: "Always (may lag on huge files)"
        }
    }

    func allows(byteCount: Int) -> Bool {
        switch self {
        case .never:  return false
        case .always: return true
        case .up1MB, .up5MB, .up20MB:
            return byteCount <= rawByteValue
        }
    }

    /// Unknown stored values (forward-compat) fall back to `.up5MB`.
    /// Reads the store, not UserDefaults — the store is the declared
    /// single source of truth and already validated the sentinels.
    @MainActor
    static func current() -> SyntaxLimit {
        SyntaxLimit(rawValue: AppPreferencesStore.shared.syntaxLimitBytes) ?? .up5MB
    }
}
