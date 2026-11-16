import SwiftUI
import AppKit
import Darwin

/// Keeps memory low while the menu is closed. The menu bar panel's SwiftUI views stay alive after it closes
/// (about 30 MB), so the content is only built while the panel is on screen and dropped when it is hidden.
/// While it is closed the panel holds an empty box of the last height, so it opens at the right size.
@MainActor @Observable
final class MenuPanelGate {
    static let shared = MenuPanelGate()

    private(set) var isOpen = false
    var lastHeight: CGFloat = 330

    @ObservationIgnored private var started = false

    private func isMenuPanel(_ w: NSWindow) -> Bool {
        String(describing: type(of: w)).contains("MenuBarExtra")
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.isMenuPanel(w) else { return }
                self.isOpen = true
            }
        }
        // The panel can lose focus while still showing (the Add App popover takes it), so look again a moment later.
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.isMenuPanel(w) else { return }
                self.closeIfHidden(w, after: 0.4)
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.isMenuPanel(w) else { return }
                self.closeIfHidden(w, after: 0.4)
            }
        }
    }

    private func closeIfHidden(_ w: NSWindow, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, !w.isVisible, !w.isKeyWindow else { return }
                self.isOpen = false
                // Give the freed memory back to the system once SwiftUI has let go of the views.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
        }
    }
}
