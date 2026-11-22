import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NapEngine.shared.start()
        PinnablePanel.install()
        PinnablePanel.onAllSpaces = { !FeatureFlags.shared.isOn(.panelOneDesktop) }
        MenuPanelGate.shared.start()
        #if !PUBLIC
        // Self-test for the pinned window: `open -n "Nappy Dev.app" --args --pin-test` pins the menu and opens and
        // closes the cards by itself for half a minute, so a crash or a jumping header can be checked without clicking.
        if CommandLine.arguments.contains("--pin-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                PinnablePanel.show(title: "Nappy") { MenuView(pinned: true, selfTest: true) }
            }
        }
        #endif
        #if !PUBLIC
        Stats.shared.start()
        BatteryStats.shared.start()
        #endif
        // pkill / logout / Ctrl-C: restore everything first, so frozen or throttled apps are never left behind.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NapEngine.shared.resumeAll(reason: "Nappy was told to quit")
                    #if !PUBLIC
                    Stats.shared.flush()
                    #endif
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        NapEngine.shared.resumeAll()   // never leave apps frozen
        #if !PUBLIC
        Stats.shared.flush()
        #endif
    }
}

@main
struct NappyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var settings = Settings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            Image(nsImage: MenuBarIcon.image(active: settings.napEnabled))
        }
        .menuBarExtraStyle(.window)
    }
}
