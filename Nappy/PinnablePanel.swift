// PinnablePanel: a MenuBarExtra(.window) panel that can be "pinned" into a floating window that stays open.
// Drop this file into any macOS 14+ SwiftUI app that uses MenuBarExtra with .menuBarExtraStyle(.window).
//
// Use:
//   1. In App.init() (or when the model is created):   PinnablePanel.install()
//   2. Put a pin button in the panel content:           Button { PinnablePanel.show { MyPanelContent(pinned: true) } } label: { Image(systemName: "pin") }
//   3. (optional) PinnablePanel.onClose = { /* e.g. model.panelVisible = false */ }
//
// How it works
//   - show(): builds an NSPanel (floating, no fade animation, joins all Spaces) around the same SwiftUI content, puts it exactly
//     where the menu panel was (same top-left), then hides the menu panel (alpha 0, no mouse, orderOut).
//   - install(): MenuBarExtra gives no click access to its status item, so a click on the icon cannot be caught directly. Instead
//     it watches the SwiftUI panel window (didBecomeKey/didExpose/didUpdate). While the pinned window is open, whenever that panel
//     appears it is hidden again and the pinned window takes the focus first (closing the key window first makes the focus
//     flash to the app behind). The check repeats at 0.05/0.2/0.5 s because SwiftUI can show the panel again after it was closed.
//   - Closing the pinned window gives the menu panel back (alpha 1, mouse on).
// Notes
//   - The menu panel is found by its class name containing "MenuBarExtra" (private class: re-check after major macOS updates).
//   - Only activate when the app is not already active: activating an active app makes the system pass the front place around.

import SwiftUI
import AppKit
import Darwin

@MainActor
enum PinnablePanel {
    static var onClose: (() -> Void)?

    private static var panel: NSPanel?
    private static var closeObserver: NSObjectProtocol?
    private static var installed = false

    static var isShown: Bool { panel?.isVisible == true }

    private static func isMenuPanel(_ w: NSWindow) -> Bool {
        String(describing: type(of: w)).contains("MenuBarExtra")
    }

    private static func hide(_ w: NSWindow) {
        w.animationBehavior = .none
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.orderOut(nil)
    }

    private static func allowMenuPanel() {
        for w in NSApp.windows where isMenuPanel(w) { w.alphaValue = 1; w.ignoresMouseEvents = false }
    }

    static func bringToFront(focus: Bool = false) {
        guard let panel, panel.isVisible else { return }
        panel.orderFrontRegardless()
        if focus {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        }
    }

    // The window sizes itself to its content (preferredContentSize). A window keeps its BOTTOM edge when its height
    // changes, which makes the header jump as the cards open and close, so the top edge is remembered and put
    // back right after every resize. Only the position changes here, never the size, so layout is not disturbed.
    private static var topEdge: CGFloat?
    private static var correcting = false
    private static var observers: [NSObjectProtocol] = []

    private static func keepTop(of panel: NSPanel) {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard !correcting, panel.isVisible else { return }
                    if note.name == NSWindow.didMoveNotification {
                        topEdge = panel.frame.maxY                      // you dragged the window: that is the new top
                    } else if let top = topEdge, abs(panel.frame.maxY - top) > 0.5 {
                        correcting = true
                        var frame = panel.frame
                        frame.origin.y = top - frame.height
                        panel.setFrame(frame, display: false)
                        correcting = false
                    }
                }
            })
        }
    }

    static func close() {
        panel?.close()
    }

    /// After the pinned window is closed its SwiftUI content would stay in memory for good (about 20 MB), so the
    /// window is thrown away and a new one is built the next time the menu is pinned.
    private static func release() {
        guard let p = panel, !p.isVisible else { return }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let c = closeObserver { NotificationCenter.default.removeObserver(c); closeObserver = nil }
        p.contentViewController = nil
        panel = nil
        topEdge = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { malloc_zone_pressure_relief(nil, 0) }
    }

    /// Opens the pinned window with `content`, in the place of the menu panel.
    static func show<Content: View>(title: String = "", @ViewBuilder content: () -> Content) {
        if panel == nil {
            let controller = NSHostingController(rootView: content())
            controller.sizingOptions = [.preferredContentSize]
            let p = NSPanel(contentViewController: controller)
            p.title = title
            // The glass background needs a transparent window whose content reaches under the title bar.
            p.styleMask = [.titled, .closable, .utilityWindow, .fullSizeContentView]
            p.titlebarAppearsTransparent = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.animationBehavior = .none
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
                Task { @MainActor in allowMenuPanel(); onClose?(); release() }
            }
            panel = p
            keepTop(of: p)
        }
        let menu = NSApp.windows.first { $0.isVisible && isMenuPanel($0) }
        if let panel, !panel.isVisible {
            panel.layoutIfNeeded()
            if let frame = menu?.frame {
                let titleBar = panel.frame.height - panel.contentLayoutRect.height
                panel.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY + titleBar))
            } else {
                panel.center()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        topEdge = panel?.frame.maxY
        if let menu { hide(menu) }
    }

    /// Call once at launch: keeps the menu panel from opening on top of the pinned window.
    static func install() {
        guard !installed else { return }
        installed = true
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let w = note.object as? NSWindow, isShown, isMenuPanel(w), w.isVisible || w.alphaValue > 0 else { return }
                MainActor.assumeIsolated {
                    let wasOpen = w.isVisible
                    if wasOpen { bringToFront(focus: true) }   // the pinned window first, then the panel goes
                    hide(w)
                    if wasOpen {
                        for delay in [0.05, 0.2, 0.5] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                MainActor.assumeIsolated { if isShown, w.isVisible { hide(w) } }
                            }
                        }
                    }
                }
            }
        }
    }
}
