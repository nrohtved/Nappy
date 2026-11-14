import Foundation
import Observation

/// Experimental features that can be switched on and off from the "Feature flags" row, to test them one at a time.
enum Flag: String, CaseIterable, Identifiable {
    case pinPanel
    case powerStats
    case wakeStats
    case napCooldown
    case groupAudit
    case batchSave
    case freezeHelpers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinPanel: "Pin panel"
        case .powerStats: "Power stats"
        case .wakeStats: "Wake stats"
        case .napCooldown: "Nap cooldown"
        case .groupAudit: "Group audit"
        case .batchSave: "Batched saving"
        case .freezeHelpers: "Freeze Electron helpers"
        }
    }

    var detail: String {
        switch self {
        case .pinPanel: "Adds a pin button that turns the menu into a floating window that stays open."
        case .powerStats: "Measures what background apps use with Nappy Off, then On, and shows the % saved."
        case .wakeStats: "Counts naps and wakes, and the CPU wakeups the nap held back."
        case .napCooldown: "After an app is woken, wait 3 min in the background before napping it again, to stop nap/wake churn."
        case .freezeHelpers: "Electron apps (Figma, Notion…): while napped with no window, stop their renderer and GPU helpers for 55 s, run them 5 s, repeat."
        case .batchSave: "Writes stats to disk once a minute, and the audit records its counts once per pass, instead of on every change."
        case .groupAudit: "Re-checks each napped app's helpers every 30 s, throttles ones that appear later, and verifies the restore."
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
        if flag == .freezeHelpers, !on { NapEngine.shared.thawAll() }
    }

    func binding(_ flag: Flag) -> Binding<Bool> {
        Binding(get: { self.isOn(flag) }, set: { self.set(flag, $0) })
    }
}

import SwiftUI
