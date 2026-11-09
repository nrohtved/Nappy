import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NapEngine.shared.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        NapEngine.shared.resumeAll()   // never leave apps frozen
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
