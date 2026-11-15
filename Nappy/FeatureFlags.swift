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
    case pictureInPicture
    case blurPanel
    case tintPanel
    case wakeOnHover
    case coffeeCard

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
        case .pictureInPicture: "Protect Picture in Picture"
        case .blurPanel: "Blurred pinned window"
        case .tintPanel: "See-through pinned window"
        case .wakeOnHover: "Wake paused apps on hover"
        case .coffeeCard: "Coffee card"
        }
    }

    var detail: String {
        switch self {
        case .pinPanel: "Adds a pin button. Pinning turns the menu into a window that stays open."
        case .powerStats: "Compares how hard your background apps work with Nappy off and on, and shows how much is saved."
        case .wakeStats: "Counts how often apps nap and wake up, and how many wake-ups Nappy prevented."
        case .napCooldown: "After you switch back to an app, waits 3 min before napping it again, so it doesn't nap and wake over and over."
        case .coffeeCard: "Shows an orange Buy me a coffee card at the bottom of the menu. Press it to open the page; close it with the x. It comes back by itself 3 days after you close it, and the coffee button in the bottom bar only shows while the card is closed (it shakes too)."
        case .wakeOnHover: "A paused locked app is woken at once when the pointer is over one of its windows, when the pointer is over the Dock (to open or restore a window from it), when one of its windows becomes visible, or while Activity Monitor is in front (so Quit works). It is paused again 1.5 s after the pointer leaves the window or the Dock. Needs Lock apps to nap."
        case .blurPanel: "The pinned window uses a blurred background (the kind sidebars and popovers use) instead of its standard glass."
        case .tintPanel: "Adds a see-through colour over the pinned window background. Use the slider to set how solid it is."
        case .pictureInPicture: "While a Picture in Picture window is open, the apps you were using in the last 2 minutes are not napped (and are woken if they were), until it closes. Their icons show under Don't Nap Busy Apps. Needs Don't Nap Busy Apps to be on."
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

    /// When the coffee card was closed with its x; nil while it is showing. It comes back by itself after 3 days.
    var coffeeDismissedAt: Date? = (UserDefaults.standard.object(forKey: "nappy.coffeeDismissedAt") as? Date)
        ?? (UserDefaults.standard.bool(forKey: "nappy.coffeeDismissed") ? Date() : nil) {      // older builds stored a plain yes/no
        didSet { UserDefaults.standard.set(coffeeDismissedAt, forKey: "nappy.coffeeDismissedAt") }
    }
    var coffeeDismissed: Bool { coffeeDismissedAt != nil }
    static let coffeeReturnsAfter: TimeInterval = 3 * 24 * 60 * 60

    func dismissCoffee() { coffeeDismissedAt = Date() }

    /// Called now and then: a card that was closed more than 3 days ago is shown again.
    func showCoffeeAgainIfDue() {
        if let closed = coffeeDismissedAt, Date().timeIntervalSince(closed) >= Self.coffeeReturnsAfter { coffeeDismissedAt = nil }
    }

    /// How solid the `tintPanel` background is (0 = fully see-through, 1 = solid).
    var tintOpacity: Double = (UserDefaults.standard.object(forKey: "nappy.tintOpacity") as? Double) ?? 0.5 {
        didSet { UserDefaults.standard.set(tintOpacity, forKey: "nappy.tintOpacity") }
    }

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
        if flag == .coffeeCard, on { coffeeDismissedAt = nil }
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
    case pinPanel, groupAudit, freezeHelpers, forceNap, wakeOnHover
}

final class FeatureFlags {
    static let shared = FeatureFlags()
    private init() {}
    func isOn(_ flag: Flag) -> Bool { true }
}
#endif
