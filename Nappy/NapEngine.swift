import AppKit
import IOKit.pwr_mgt
import Darwin
import Observation

struct NappedApp: Identifiable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let pids: [pid_t]   // the app plus its helper/child processes
    let since: Date
    var id: pid_t { pid }
}

/// Puts idle background apps into macOS's native background policy (`PRIO_DARWIN_BG`) — the same
/// throttling App Nap applies: lowest CPU priority, throttled disk/network I/O, coalesced timers.
/// Apps keep running (notifications, sync, audio keep working), they are just made cheap.
/// The App Nap decision itself can't be forced on another process with public API, so this is the closest native mechanism.
@Observable
final class NapEngine {
    static let shared = NapEngine()

    private(set) var napped: [NappedApp] = []
    private(set) var statusText = "Ready"

    @ObservationIgnored private var backgroundSince: [pid_t: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let settings = Settings.shared
    @ObservationIgnored private let selfPID = ProcessInfo.processInfo.processIdentifier
    @ObservationIgnored private let pidKey = "nappy.nappedPIDs"
    @ObservationIgnored private var started = false
    @ObservationIgnored private var skipReason: [pid_t: String] = [:]
    @ObservationIgnored private let log = ActivityLog.shared

    private static let protectedIDs: Set<String> = [
        "com.apple.finder", "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.universalcontrol",
    ]

    func start() {
        guard !started else { return }
        started = true
        var uptime = timespec(); clock_gettime(CLOCK_MONOTONIC_RAW, &uptime)
        log.add("app started \(uptime.tv_sec) s after boot")
        recoverStoppedProcesses()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.appActivated(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.appTerminated(app) }
        }

        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: Main loop

    func tick() {
        guard settings.isOn, settings.napEnabled else {
            resumeAll(reason: settings.isOn ? "nap turned off" : "Nappy turned off"); backgroundSince.removeAll()
            statusText = settings.isOn ? "Nap is off" : "Paused"
            return
        }
        let now = Date()
        let workspace = NSWorkspace.shared
        let frontPID = workspace.frontmostApplication?.processIdentifier
        let visible = settings.onlyWithoutWindows ? pidsWithVisibleWindows() : []
        let awake = settings.respectPowerAssertions ? pidsHoldingAssertions() : []
        let delay = TimeInterval(settings.delaySeconds)
        var alive = Set<pid_t>()

        for app in workspace.runningApplications {
            let pid = app.processIdentifier
            alive.insert(pid)
            guard isNappable(app) else { continue }

            if pid == frontPID || settings.isIgnored(app.bundleIdentifier) {
                backgroundSince[pid] = nil
                if isNapped(pid) { resume(pid: pid, reason: pid == frontPID ? "now frontmost" : "added to ignored") }
                continue
            }

            if isNapped(pid) { continue }

            let since = backgroundSince[pid] ?? now
            backgroundSince[pid] = since
            guard now.timeIntervalSince(since) >= delay else { continue }
            if visible.contains(pid) || awake.contains(pid) {
                let reason = visible.contains(pid) ? "has a visible window" : "keeping Mac awake (power assertion)"
                if skipReason[pid] != reason {
                    skipReason[pid] = reason
                    log.add("skip  \(app.localizedName ?? "App") (pid \(pid)) — \(reason)")
                }
                continue
            }
            suspend(app, idle: now.timeIntervalSince(since))
        }

        backgroundSince = backgroundSince.filter { alive.contains($0.key) }
        skipReason = skipReason.filter { alive.contains($0.key) }
        napped.removeAll { !alive.contains($0.pid) }
        persistPIDs()
        statusText = napped.isEmpty ? "Watching" : "\(napped.count) napping"
    }

    // MARK: Suspend / resume

    func isNapped(_ pid: pid_t) -> Bool { napped.contains { $0.pid == pid } }

    private func isNappable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular
            && !app.isTerminated
            && app.isFinishedLaunching
            && app.processIdentifier != selfPID
            && !(app.bundleIdentifier.map(Self.protectedIDs.contains) ?? false)
    }

    private func suspend(_ app: NSRunningApplication, idle: TimeInterval) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "App"
        let group = [pid] + descendants(of: pid)
        guard setBackground(group, true) else {
            log.add("error \(name) (pid \(pid)) — setpriority failed")
            return
        }
        skipReason[pid] = nil
        log.add("nap   \(name) (pid \(pid), +\(group.count - 1) helpers) after \(Int(idle)) s in background")
        napped.append(NappedApp(pid: pid, bundleID: app.bundleIdentifier,
                                name: app.localizedName ?? "App", icon: app.icon, pids: group, since: Date()))
        persistPIDs()
    }

    func resume(pid: pid_t, reason: String = "restored manually") {
        if let entry = napped.first(where: { $0.pid == pid }) {
            setBackground(entry.pids + descendants(of: pid), false)
            log.add("wake  \(entry.name) (pid \(pid)) — \(reason), napped \(Int(Date().timeIntervalSince(entry.since))) s")
        }
        napped.removeAll { $0.pid == pid }
        backgroundSince[pid] = nil
        persistPIDs()
    }

    func resumeAll(reason: String = "restore all") {
        for app in napped {
            setBackground(app.pids + descendants(of: app.pid), false)
            log.add("wake  \(app.name) (pid \(app.pid)) — \(reason)")
        }
        if !napped.isEmpty { napped.removeAll() }
        persistPIDs()
    }

    private func appActivated(_ app: NSRunningApplication) {
        backgroundSince[app.processIdentifier] = nil
        if isNapped(app.processIdentifier) { resume(pid: app.processIdentifier, reason: "switched to app") }
    }

    private func appTerminated(_ app: NSRunningApplication) {
        if let e = napped.first(where: { $0.pid == app.processIdentifier }) { log.add("quit  \(e.name) (pid \(e.pid)) while napping") }
        napped.removeAll { $0.pid == app.processIdentifier }
        backgroundSince[app.processIdentifier] = nil
        persistPIDs()
    }

    @discardableResult
    private func setBackground(_ pids: [pid_t], _ on: Bool) -> Bool {
        var ok = false
        for pid in pids where pid > 1 {
            // PRIO_DARWIN_PROCESS = 4, PRIO_DARWIN_BG = 0x1000
            if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0 { ok = true }
        }
        return ok
    }

    /// Helper processes of an app: its child processes (Chrome/VS Code helpers) plus processes macOS
    /// attributes to it as the "responsible" process (XPC services such as Safari's WebKit networking/GPU
    /// processes, which are launched by launchd and so are not children).
    private func descendants(of pid: pid_t) -> [pid_t] {
        var result = Set<pid_t>()
        var queue = [pid]
        while let p = queue.popLast() {
            var buf = [pid_t](repeating: 0, count: 256)
            let bytes = proc_listchildpids(p, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            for kid in buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where kid > 0 && result.insert(kid).inserted {
                queue.append(kid)
            }
        }
        if let responsible = Self.responsibleFn {
            let count = Int(proc_listallpids(nil, 0))
            if count > 0 {
                var all = [pid_t](repeating: 0, count: count + 64)
                let n = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size)))
                for other in all.prefix(max(n, 0)) where other > 1 && other != pid && responsible(other) == pid {
                    result.insert(other)
                }
            }
        }
        result.remove(pid)
        return Array(result)
    }

    /// `responsibility_get_pid_responsible_for_pid` — the call Activity Monitor uses to group helpers under their app.
    private static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    // MARK: Crash safety — never leave apps throttled if Nappy dies

    private func persistPIDs() {
        UserDefaults.standard.set(napped.flatMap(\.pids).map { Int($0) }, forKey: pidKey)
    }

    private func recoverStoppedProcesses() {
        let old = UserDefaults.standard.array(forKey: pidKey) as? [Int] ?? []
        if !old.isEmpty { log.add("recover \(old.count) process(es) left from a previous run") }
        setBackground(old.map { pid_t($0) }, false)
        for pid in old { kill(pid_t(pid), SIGCONT) }   // also wakes anything frozen by an older Nappy build
        UserDefaults.standard.removeObject(forKey: pidKey)
    }

    // MARK: Heuristics

    /// PIDs owning at least one normal, visible window on the current Space.
    private func pidsWithVisibleWindows() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result = Set<pid_t>()
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
            result.insert(pid)
        }
        return result
    }

    /// PIDs that asked macOS to stay awake (playing audio/video, downloads, calls, builds…).
    private func pidsHoldingAssertions() -> Set<pid_t> {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess, let cf = ref?.takeRetainedValue() else { return [] }
        let blocking: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
                                     "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        var result = Set<pid_t>()
        for (k, v) in cf as NSDictionary {
            guard let pid = (k as? NSNumber)?.int32Value, let list = v as? [[String: Any]] else { continue }
            if list.contains(where: { blocking.contains($0["AssertType"] as? String ?? "") }) { result.insert(pid) }
        }
        return result
    }
}
