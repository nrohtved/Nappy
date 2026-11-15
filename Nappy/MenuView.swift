import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct MenuView: View {
    /// True when shown inside the floating pinned window instead of the menu bar panel.
    var pinned = false
    #if !PUBLIC
    var selfTest = false
    @State private var headerPositions: [String] = []     // self-test: where the header was inside the window
    #endif
    private var flags = FeatureFlags.shared
    #if !PUBLIC
    private enum Page { case main, flags }
    @State private var page = Page.main
    @State private var flagsHeight: CGFloat = 0
    #endif
    @Bindable private var settings = Settings.shared
    private var engine = NapEngine.shared

    @State private var napExpanded = true
    @State private var optionsExpanded = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showAddApp = false
    @State private var contentHeight: CGFloat = 520      // pinned window: the height of the content
    #if !PUBLIC
    @State private var logExpanded = false
    private var log = ActivityLog.shared
    #endif

    var body: some View {
        if pinned {
            // The pinned window is an AppKit window whose height does not move in step with SwiftUI's animation,
            // and plain content slides around inside it (the header jumped). So the content is laid over a flexible
            // clear box that takes whatever height the window has, pinned to its top edge; the box's ideal height is
            // the content's height, which is what sizes the window.
            Color.clear
                .frame(minWidth: 350, maxWidth: 350, minHeight: 0, idealHeight: contentHeight, maxHeight: .infinity)
                .background { PanelBackground() }       // the system's glass (the Dev flags can change it)
                .overlay(alignment: .top) {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            header          // always at the top, outside the page animation
                #if !PUBLIC
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { y in
                    if selfTest {
                        let w = NSApp.windows.first { $0.isFloatingPanel && $0.title == "Nappy" }
                        headerPositions.append("y=\(Int(y.rounded())) windowHeight=\(Int(w?.frame.height ?? 0)) windowTop=\(Int(w?.frame.maxY ?? 0))")
                    }
                }
                #endif
            #if PUBLIC
            mainPage
            #else
            // The two pages slide past each other: forward pushes the main page out to the left,
            // back brings it in from the left again.
            ZStack(alignment: .top) {
                if page == .flags {
                    flagsPage
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    mainPage
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            // The clip sits well outside the cards so their glass edge and shadow (which reaches further
            // below than above) are not cut off; the negative padding gives the layout its size back.
            .padding(Self.clipRoom)
            .clipped()
            .padding(EdgeInsets(top: -Self.clipRoom.top, leading: -Self.clipRoom.leading,
                                bottom: -Self.clipRoom.bottom, trailing: -Self.clipRoom.trailing))
            .animation(.snappy(duration: 0.3), value: page)
            #endif
            footer
        }
        .padding()
        .frame(width: 350)
        #if !PUBLIC
        .task { await runSelfTest() }
        #endif
    }

    #if !PUBLIC
    /// Opens and closes the cards and flips between the two pages every 0.35 s (only with `--pin-test`).
    private func runSelfTest() async {
        guard selfTest else { return }
        try? await Task.sleep(for: .seconds(1.5))
        for i in 0..<70 {
            withAnimation(.snappy) {
                switch i % 3 {
                case 0: napExpanded.toggle()
                case 1: let binding = optionsExpandedBinding; binding.wrappedValue.toggle()
                default: page = (page == .main) ? .flags : .main
                }
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        let w = NSApp.windows.first { $0.isFloatingPanel && $0.title == "Nappy" }
        let summary = "final: content=\(Int(contentHeight)) window=\(Int(w?.frame.height ?? 0)) layoutRect=\(Int(w?.contentLayoutRect.height ?? 0)) opaque=\(w?.isOpaque ?? true) fullSize=\(w?.styleMask.contains(.fullSizeContentView) ?? false)"
        try? (headerPositions + [summary]).joined(separator: "\n").write(toFile: "/tmp/nappy-pin-test.txt", atomically: true, encoding: .utf8)
    }
    #endif

    private var mainPage: some View {
        VStack(spacing: 10) {
            napCard
            optionsCard
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // The app icon itself (it has a margin around the tile, so the frame is a little larger than the tile).
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .padding(.leading, -4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Nappy").font(.headline)
                    #if !PUBLIC
                    Text("DEV").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange, in: .capsule)
                    #endif
                }
                Text(engine.statusText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            // Shows the state only; the switch on the Nap card turns napping on and off.
            let active = settings.napEnabled
            HStack(spacing: 8) {
                Circle().fill(active ? .green : .gray).frame(width: 7, height: 7)
                Text(active ? "On" : "Off").font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .glassEffect(.regular.tint(active ? .green.opacity(0.35) : nil), in: .capsule)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Nap card

    private var napCard: some View {
        Card(title: "Nap Unused Apps", subtitle: "After \(durationLabel(settings.delaySeconds)) of not using them",
             symbol: "moon.zzz", isOn: $settings.napEnabled, expanded: $napExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                row("Start Napping After", font: .subheadline) {
                    Picker("", selection: $settings.delaySeconds) {
                        ForEach([5, 10, 30, 60, 120, 300, 600, 900, 1800, 3600], id: \.self) { Text(durationLabel($0)).tag($0) }
                    }.labelsHidden().fixedSize().font(.subheadline)
                }

                Divider()
                sectionTitle("Napping Now")
                if engine.napped.isEmpty {
                    Text("No apps are napping right now").font(.caption).foregroundStyle(.secondary)
                } else {
                    limited(count: engine.napped.count) {
                        // The app that started napping most recently comes first, so a new one is easy to spot.
                        ForEach(engine.napped.sorted { $0.since > $1.since }) { app in
                            HStack(spacing: 6) {
                                appIcon(app.icon)
                                HStack(spacing: 4) {
                                    Text(app.name).font(.subheadline).lineLimit(1)
                                    // How long it has been napping, right after the name; refreshes while the menu is open.
                                    TimelineView(.periodic(from: .now, by: 5)) { context in
                                        Text(napDuration(context.date.timeIntervalSince(app.since)))
                                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                            .fixedSize()
                                    }
                                }
                                Spacer(minLength: 4)
                                Button { engine.resume(pid: app.pid) } label: {
                                    rowGlyph("arrow.uturn.left.circle.fill")
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Wake this app up")
                                if flags.isOn(.forceNap), let id = app.bundleID {
                                    let locked = engine.isForced(bundleID: id)
                                    Button { engine.setForced(bundleID: id, name: app.name, on: !locked) } label: {
                                        rowGlyph(locked ? "lock.fill" : "lock.open")
                                    }
                                    .buttonStyle(.plain).foregroundStyle(locked ? Color.accentColor : .secondary)
                                    .help(locked ? "Locked: paused completely while it naps, only Nappy can wake it" : "Lock: pause this app completely while it naps, so it cannot wake itself")
                                }
                                Button {
                                    if let id = app.bundleID { settings.ignore(bundleID: id, name: app.name) }
                                    engine.resume(pid: app.pid)
                                } label: {
                                    rowGlyph("minus.circle.fill")
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Never nap this app")
                            }
                            .frame(height: Self.rowHeight)
                        }
                    }
                }

                Divider()
                HStack {
                    sectionTitle("Never Nap These Apps")
                    Spacer()
                    addAppMenu
                }
                if settings.ignored.isEmpty {
                    Text("Any unused app can nap").font(.caption).foregroundStyle(.secondary)
                }
                limited(count: settings.ignored.count) {
                    ForEach(settings.ignored) { app in
                        HStack(spacing: 6) {
                            appIcon(icon(forBundleID: app.bundleID))
                            Text(app.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            Button { settings.ignored.removeAll { $0.id == app.id } } label: {
                                rowGlyph("minus.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Allow this app to nap again")
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
            }
        }
    }

    /// "Add App…" opens a small list with each open app's icon. (A SwiftUI Menu on macOS does not show app icons,
    /// so this is a popover with ordinary rows.)
    private var addAppMenu: some View {
        Button { showAddApp.toggle() } label: {
            Label("Add App…", systemImage: "plus").font(.subheadline)
        }
        .popover(isPresented: $showAddApp, arrowEdge: .bottom) { addAppList }
    }

    private var addAppList: some View {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && !settings.isIgnored($0.bundleIdentifier) && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if running.isEmpty {
                        Text("No other apps are open").font(.subheadline).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(running, id: \.processIdentifier) { app in
                        PickerRow {
                            settings.ignore(bundleID: app.bundleIdentifier!, name: app.localizedName ?? "App")
                            engine.resume(pid: app.processIdentifier)
                            showAddApp = false
                        } content: {
                            appIcon(app.icon)
                            Text(app.localizedName ?? "App").font(.subheadline).lineLimit(1)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)
            Divider()
            PickerRow {
                showAddApp = false
                chooseApp()
            } content: {
                Image(systemName: "folder").frame(width: Self.glyphSize, height: Self.glyphSize)
                Text("Choose Another App…").font(.subheadline)
            }
            .padding(6)
        }
        .frame(width: 240)
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

    /// The apps Nappy sees working right now (the ones "Don't Nap Busy Apps" protects), as icons only;
    /// pointing at an icon shows the app's name.
    private var busyAppIcons: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            let apps = engine.busyApps()
            if !apps.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.glyphSize), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(apps, id: \.processIdentifier) { app in
                        appIcon(app.icon).help(app.localizedName ?? "App")
                    }
                }
            }
        }
    }

    /// Opening Options closes the Nap card and closing Options opens it again. Closing the Nap card by hand
    /// leaves Options as it is.
    private var optionsExpandedBinding: Binding<Bool> {
        Binding(get: { optionsExpanded }, set: { open in
            optionsExpanded = open
            napExpanded = !open
        })
    }

    private var optionsCard: some View {
        Card(title: "Options", subtitle: "Login and what is never napped", symbol: "slider.horizontal.3",
             isOn: nil, expanded: optionsExpandedBinding) {
            VStack(alignment: .leading, spacing: 10) {
                OptionRow(title: "Open Nappy at Login") {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                }
                OptionRow(title: "Don't Nap Apps You Can See",
                          description: "Apps with a window showing on screen, for example side by side, are left alone.") {
                    Toggle("", isOn: $settings.onlyWithoutWindows)
                }
                OptionRow(title: "Don't Nap Busy Apps",
                          description: "Apps playing sound, in a call or downloading keep running normally.") {
                    Toggle("", isOn: $settings.respectPowerAssertions)
                }
                if settings.respectPowerAssertions { busyAppIcons }

                #if !PUBLIC
                Divider()
                Button { page = .flags } label: {
                    HStack {
                        Text("Experimental features").font(.subheadline)
                        Spacer()
                        Text("\(flags.onCount) on").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
                activityLog
                #endif
            }
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    #if !PUBLIC
    // MARK: Experimental features page

    private var flagsPage: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { page = .main } label: {
                    Image(systemName: "chevron.left").font(.callout.weight(.semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Back")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Experimental features").font(.headline)
                    Text("\(flags.onCount) on").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Flag.allCases) { flag in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(flag.title).font(.callout)
                                        Text(flag.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: .capsule)
                                            .textSelection(.enabled)
                                    }
                                    Text(flag.detail).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Toggle("", isOn: flags.binding(flag))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            if flags.isOn(flag) { FlagDetail(flag: flag) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { flagsHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(flagsHeight, 1), maxFlagsHeight))
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    /// The list scrolls once it is taller than the screen allows.
    private var maxFlagsHeight: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 220)
    }

    // MARK: Activity log

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { logExpanded.toggle() } } label: {
                HStack {
                    Text("Activity log").font(.subheadline)
                    Spacer()
                    Text("\(log.lines.count)").font(.caption).foregroundStyle(.secondary)
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
                    Button("Show in Finder") { log.showFile() }
                    Spacer()
                    Button("Clear") { log.clear() }
                }
                .controlSize(.small)
            }
        }
    }
    #endif

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch at login failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Footer

    /// Icons only, no background: pin (when enabled), About, Buy me a coffee, and quit on the right.
    private var footer: some View {
        HStack(spacing: 16) {
            if flags.isOn(.pinPanel) {
                footerButton(pinned ? "pin.slash" : "pin", help: pinned ? "Unpin this window" : "Keep this menu open") {
                    if pinned { PinnablePanel.close() } else { PinnablePanel.show(title: "Nappy") { MenuView(pinned: true) } }
                }
            }
            footerButton("info.circle", help: "About Nappy") { AboutWindow.show() }
            footerButton("cup.and.saucer.fill", help: "Buy me a coffee") { NSWorkspace.shared.open(AboutWindow.coffeeURL) }
            Spacer()
            footerButton("power", help: "Quit Nappy") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 6)
    }

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Helpers

    #if !PUBLIC
    private static let clipRoom = EdgeInsets(top: 24, leading: 24, bottom: 48, trailing: 24)
    #endif
    private static let rowHeight: CGFloat = 20
    private static let rowSpacing: CGFloat = 1
    private static let glyphSize: CGFloat = 18      // app icons and row buttons are all this size
    private static let visibleRows = 5

    /// Shows up to five rows; a longer list scrolls inside a box five rows tall.
    @ViewBuilder
    private func limited<Rows: View>(count: Int, @ViewBuilder _ rows: () -> Rows) -> some View {
        if count > Self.visibleRows {
            let height = CGFloat(Self.visibleRows) * Self.rowHeight + CGFloat(Self.visibleRows - 1) * Self.rowSpacing
            ScrollView {
                VStack(alignment: .leading, spacing: Self.rowSpacing) { rows() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
        } else {
            VStack(alignment: .leading, spacing: Self.rowSpacing) { rows() }
        }
    }

    private func napDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)min" }
        return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60)
    }

    private func row<V: View>(_ title: String, font: Font = .body, @ViewBuilder _ control: () -> V) -> some View {
        HStack { Text(title).font(font); Spacer(); control() }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.subheadline.weight(.medium))
    }

    private func appIcon(_ image: NSImage?) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Image(systemName: "app.dashed").resizable() }
        }
        .frame(width: Self.glyphSize, height: Self.glyphSize)
    }

    /// A button icon in a Napping Now or Never Nap These Apps row: same symbol size everywhere.
    private func rowGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.body).frame(width: Self.glyphSize, height: Self.glyphSize)
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
    let isOn: Binding<Bool>?          // nil: no switch on the card
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // The whole title area opens and closes the card; only the switch on the right is separate.
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 0 : -90)).frame(width: 14)
                        Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.subheadline.weight(.semibold))
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let isOn { Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch) }
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

/// One line in Options: small title, an optional description at most 70% as wide as the row, and the switch at the far right.
private struct OptionRow<Control: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var control: Control
    @State private var width: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fixedSize(horizontal: true, vertical: false)   // never cut the title short
                if let description {
                    Text(description)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: width > 0 ? width * 0.7 : nil, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

/// A row in a small picker popover: whole row clickable, lightly highlighted under the pointer.
private struct PickerRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
