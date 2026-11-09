import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct MenuView: View {
    @Bindable private var settings = Settings.shared
    private var engine = NapEngine.shared

    @State private var napExpanded = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showInfo = false
    @State private var logExpanded = false
    private var log = ActivityLog.shared

    var body: some View {
        VStack(spacing: 10) {
            header
            napCard
            optionsCard
            footer
        }
        .padding()
        .frame(width: 350)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Nappy").font(.headline)
                Text(engine.statusText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.isOn.toggle() } label: {
                HStack(spacing: 8) {
                    Circle().fill(settings.isOn ? .green : .gray).frame(width: 7, height: 7)
                    Text(settings.isOn ? "On" : "Off").font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .glassEffect(.regular.tint(settings.isOn ? .green.opacity(0.35) : nil).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Nap card

    private var napCard: some View {
        Card(title: "Nap Idle Apps", subtitle: "After \(durationLabel(settings.delaySeconds)) in background",
             symbol: "moon.zzz", isOn: $settings.napEnabled, expanded: $napExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                row("Nap After") {
                    Picker("", selection: $settings.delaySeconds) {
                        ForEach([5, 10, 30, 60, 120, 300, 600, 900, 1800, 3600], id: \.self) { Text(durationLabel($0)).tag($0) }
                    }.labelsHidden().fixedSize()
                }

                Divider()
                sectionTitle("Napping Now")
                if engine.napped.isEmpty {
                    Text("No apps napping").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(engine.napped) { app in
                        HStack(spacing: 10) {
                            appIcon(app.icon)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Button("Restore") { engine.resume(pid: app.pid) }.controlSize(.mini)
                            Button("Ignore") {
                                if let id = app.bundleID { settings.ignore(bundleID: id, name: app.name) }
                                engine.resume(pid: app.pid)
                            }.controlSize(.small)
                        }
                    }
                }

                Divider()
                HStack {
                    sectionTitle("Ignored Apps")
                    Spacer()
                    addAppMenu
                }
                if settings.ignored.isEmpty {
                    Text("Every background app can nap").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(settings.ignored) { app in
                    HStack(spacing: 10) {
                        appIcon(icon(forBundleID: app.bundleID))
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Button { settings.ignored.removeAll { $0.id == app.id } } label: {
                            Image(systemName: "minus.circle.fill").font(.body).foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var addAppMenu: some View {
        Menu {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && !settings.isIgnored($0.bundleIdentifier) && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            ForEach(running, id: \.processIdentifier) { app in
                Button {
                    settings.ignore(bundleID: app.bundleIdentifier!, name: app.localizedName ?? "App")
                    if app.bundleIdentifier != nil { engine.resume(pid: app.processIdentifier) }
                } label: {
                    if let icon = app.icon { Image(nsImage: icon.resized(16)) }
                    Text(app.localizedName ?? "App")
                }
            }
            Divider()
            Button("Choose from Applications…") { chooseApp() }
        } label: {
            Label("Add App…", systemImage: "plus")
        }
        .menuStyle(.button).fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                Settings.shared.ignore(bundleID: id, name: name)
            }
        }
    }

    // MARK: Options

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            Toggle(isOn: $settings.onlyWithoutWindows) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only Nap Apps Without Windows")
                    Text("Skips apps that still have a visible window, e.g. side by side.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.respectPowerAssertions) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip Apps Keeping Mac Awake")
                    Text("Music, calls, downloads and other work in progress keep running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            activityLog
        }
        .toggleStyle(.switch).controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Activity log

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { logExpanded.toggle() } } label: {
                HStack {
                    Text("Activity log").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(log.lines.count)").font(.callout).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(logExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if logExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading).id(i)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .frame(height: 150)
                    .onChange(of: log.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                    .onAppear { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
                }
                HStack {
                    Button("Copy") { log.copy() }
                    Button("Show file") { log.showFile() }
                    Spacer()
                    Button("Clear") { log.clear() }
                }
                .controlSize(.small)
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch at login failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button { showInfo.toggle() } label: {
                Image(systemName: "info").font(.callout).frame(width: 44, height: 24)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo) {
                Text("Apps that stay in the background are put into macOS's native background mode: lowest CPU priority and throttled disk and network, like App Nap. They keep running and are restored instantly when you switch back. Apps that are playing audio, in a call or downloading are skipped. If Nappy quits, everything is restored.")
                    .font(.callout).padding().frame(width: 280)
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.callout).frame(width: 44, height: 24)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Helpers

    private func row<V: View>(_ title: String, @ViewBuilder _ control: () -> V) -> some View {
        HStack { Text(title); Spacer(); control() }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.subheadline.weight(.medium))
    }

    private func appIcon(_ image: NSImage?) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Image(systemName: "app.dashed").resizable() }
        }
        .frame(width: 20, height: 20)
    }

    private func icon(forBundleID id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        if seconds == 3600 { return "1 hour" }
        return "\(seconds / 60) min"
    }

}

// MARK: - Card

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 0 : -90)).frame(width: 14)
                }.buttonStyle(.plain)
                Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if expanded {
                Divider().padding(.vertical, 8)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private extension NSImage {
    func resized(_ side: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        img.unlockFocus()
        return img
    }
}
