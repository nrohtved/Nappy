import Foundation
import AppKit
import Observation

struct IgnoredApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// User preferences, persisted to UserDefaults as one JSON blob.
@Observable
final class Settings {
    static let shared = Settings()

    // The switch on the Nap card: napping on or off.
    var napEnabled = true { didSet { save() } }
    /// Seconds an app must stay in the background before it is napped (minimum 5).
    var delaySeconds = 60 { didSet { save() } }
    var ignored: [IgnoredApp] = [] { didSet { save() } }

    // Safety options
    var onlyWithoutWindows = true { didSet { save() } }
    var respectPowerAssertions = true { didSet { save() } }

    @ObservationIgnored private var loading = true
    @ObservationIgnored private let key = "nappy.settings.v1"

    private struct Stored: Codable {
        var napEnabled: Bool, delaySeconds: Int, ignored: [IgnoredApp]
        var onlyWithoutWindows: Bool, respectPowerAssertions: Bool
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            napEnabled = s.napEnabled; delaySeconds = max(5, s.delaySeconds)
            ignored = s.ignored
            onlyWithoutWindows = s.onlyWithoutWindows
            respectPowerAssertions = s.respectPowerAssertions
        } else {
            ignored = Self.defaultIgnored()
        }
        loading = false
        save()
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(napEnabled: napEnabled, delaySeconds: delaySeconds, ignored: ignored,
                       onlyWithoutWindows: onlyWithoutWindows,
                       respectPowerAssertions: respectPowerAssertions)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Freezing a terminal, IDE or chat client you are working in would be nasty — seed them as ignored.
    private static func defaultIgnored() -> [IgnoredApp] {
        let ids = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
                   "com.anthropic.claudefordesktop", "com.microsoft.VSCode"]
        return ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return IgnoredApp(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }

    func isIgnored(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignored.contains { $0.bundleID == bundleID }
    }

    func ignore(bundleID: String, name: String) {
        guard !isIgnored(bundleID) else { return }
        ignored.append(IgnoredApp(bundleID: bundleID, name: name))
        ignored.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

}
