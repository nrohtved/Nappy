import SwiftUI
import AppKit

/// What sits behind the pinned window's content: the system's own Liquid Glass (regular style, no changes to its
/// values), like the menu in the menu bar. The Dev build has two flags on top of that: `blurPanel` swaps in a blurred
/// background and `tintPanel` adds a see-through colour.
struct PanelBackground: View {
    #if !PUBLIC
    private var flags = FeatureFlags.shared
    #endif

    var body: some View {
        ZStack {
            #if PUBLIC
            GlassBackground()
            #else
            if flags.isOn(.blurPanel) { BlurBackground() } else { GlassBackground() }
            if flags.isOn(.tintPanel) {
                Color(nsColor: .windowBackgroundColor).opacity(flags.tintOpacity)
            }
            #endif
        }
        .ignoresSafeArea()
    }
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = 20          // close to the window's own corners
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

#if !PUBLIC
private struct BlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#endif
