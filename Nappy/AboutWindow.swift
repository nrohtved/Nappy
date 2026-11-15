import SwiftUI
import AppKit

/// The separate "About Nappy" window: which app this is and which version.
@MainActor
enum AboutWindow {
    /// Where "Buy me a coffee" goes. Replace with your own page.
    static let coffeeURL = URL(string: "https://buymeacoffee.com/nrohtved")!

    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let controller = NSHostingController(rootView: AboutView())
            let w = NSWindow(contentViewController: controller)
            w.title = "About Nappy"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = .floating          // stays visible above the pinned menu window
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return Stage.isPublic ? "Version \(short) (\(build))" : "Version \(short) (\(build)) · \(Stage.name) build"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Nappy").font(.title.bold())
            Text(version).font(.callout).foregroundStyle(.secondary)
            Text("Nappy puts the apps you aren't using to sleep, so your Mac works less and uses less power. They keep running quietly and wake up the moment you switch back to them.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280)
            Button {
                NSWorkspace.shared.open(AboutWindow.coffeeURL)
            } label: {
                Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 360)
    }
}
