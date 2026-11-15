import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NapEngine.shared.start()
        PinnablePanel.install()
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
            let active = settings.isOn && settings.napEnabled
            #if PUBLIC
            Image(systemName: active ? "moon.zzz.fill" : "moon.zzz")
            #else
            // The Dev build has its own icon so it can be told apart from the Public build in the menu bar.
            Image(systemName: active ? "moon.stars.fill" : "moon.stars")
            #endif
        }
        .menuBarExtraStyle(.window)
    }
}
