import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NapEngine.shared.start()
        PinnablePanel.install()
        Stats.shared.start()
        // pkill / logout / Ctrl-C: restore everything first, so frozen or throttled apps are never left behind.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NapEngine.shared.resumeAll(reason: "Nappy was told to quit")
                    Stats.shared.flush()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        NapEngine.shared.resumeAll()   // never leave apps frozen
        Stats.shared.flush()
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
            Image(systemName: settings.isOn && settings.napEnabled ? "moon.zzz.fill" : "moon.zzz")
        }
        .menuBarExtraStyle(.window)
    }
}
