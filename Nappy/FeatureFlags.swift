#if !PUBLIC
import Foundation
import Observation

/// Experimental features that can be switched on and off from the Experimental features page, to test them one at a time.
/// The cases are listed in the order they were created (oldest first), which is the order the page shows them in;
/// a new flag goes at the end.
enum Flag: String, CaseIterable, Identifiable {
    case pinPanel
    case powerStats
    case wakeStats
    case napCooldown
    case groupAudit
    case batchSave
    case freezeHelpers
    case batteryStats
    case forceNap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinPanel: "Pin the menu"
        case .powerStats: "Savings report"
        case .wakeStats: "Nap and wake counter"
        case .napCooldown: "Wait before napping again"
        case .groupAudit: "Double-check helpers"
        case .batchSave: "Save less often"
        case .freezeHelpers: "Pause Electron app helpers"
        case .batteryStats: "Battery report"
        case .forceNap: "Lock apps to nap"
        }
    }

    var detail: String {
        switch self {
        case .pinPanel: "Adds a pin button. Pinning turns the menu into a window that stays open."
        case .powerStats: "Compares how hard your background apps work with Nappy off and on, and shows how much is saved."
        case .wakeStats: "Counts how often apps nap and wake up, and how many wake-ups Nappy prevented."
        case .napCooldown: "After you switch back to an app, waits 3 min before napping it again, so it doesn't nap and wake over and over."
        case .forceNap: "Adds a lock button to apps in Napping Now. A locked app is paused completely while it naps with no window showing, so it cannot wake itself. Only Nappy wakes it: when you switch to it, or press wake up."
        case .batteryStats: "Compares how much power the whole Mac uses with Nappy off and on, and shows the % saved and the extra battery time."
        case .freezeHelpers: "For apps built with Electron (Figma, Notion…): while napping with no window showing, pauses the parts that draw the screen for 55 s, then lets them run for 5 s, and repeats."
        case .batchSave: "Saves the statistics once a minute instead of after every change, which uses less power."
        case .groupAudit: "Every 30 s, checks that the helper processes of each napped app are napping too, and that they go back to normal when you return."
        }
    }
}

@Observable
final class FeatureFlags {
    static let shared = FeatureFlags()

    private(set) var enabled: Set<String>
    @ObservationIgnored private let key = "nappy.flags.v1"

    private init() {
        enabled = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    var onCount: Int { Flag.allCases.filter { isOn($0) }.count }

    func isOn(_ flag: Flag) -> Bool { enabled.contains(flag.rawValue) }

    func set(_ flag: Flag, _ on: Bool) {
        if on { enabled.insert(flag.rawValue) } else { enabled.remove(flag.rawValue) }
        UserDefaults.standard.set(Array(enabled), forKey: key)
        ActivityLog.shared.add("flag \(flag.rawValue) \(on ? "on" : "off")")
        if flag == .pinPanel, !on { PinnablePanel.close() }
        if flag == .batchSave, !on { Stats.shared.flush() }
        if flag == .freezeHelpers || flag == .forceNap, !on { NapEngine.shared.thawAll() }
    }

    func binding(_ flag: Flag) -> Binding<Bool> {
        Binding(get: { self.isOn(flag) }, set: { self.set(flag, $0) })
    }
}

import SwiftUI
#else
import Foundation

/// The public build has no experiments menu: the experiments that were switched on are simply always on,
/// and the ones that were off were cut.
enum Flag: String {
    case pinPanel, groupAudit, freezeHelpers, forceNap
}

final class FeatureFlags {
    static let shared = FeatureFlags()
    private init() {}
    func isOn(_ flag: Flag) -> Bool { true }
}
#endif
