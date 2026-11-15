import AppKit
import IOKit.pwr_mgt
import Darwin
import Observation

struct NappedApp: Identifiable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    var pids: [pid_t]   // the app plus its helper/child processes
    let since: Date
    var electron = false
    var hardFreeze = false           // `forceNap`: the whole app is paused, not just its helpers
    var freezeNote = ""              // why a locked app is not paused yet: "window showing", "keeping Mac awake"
    var frozen: Set<pid_t> = []      // renderer/GPU helpers under `freezeHelpers`
    var isStopped = false
    var nextThaw = Date.distantFuture
    var thawUntil = Date.distantFuture
    var preBG: Set<pid_t> = []   // helpers already background before the nap (macOS did that): left untouched both ways
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
    @ObservationIgnored private let flags = FeatureFlags.shared
    #if !PUBLIC
    @ObservationIgnored private var lastWake: [pid_t: Date] = [:]
    #endif
    @ObservationIgnored private var lastAudit = Date.distantPast
    #if !PUBLIC
    private static let cooldown: TimeInterval = 180
    #endif
    private static let freezeFor: TimeInterval = 55
    private static let thawFor: TimeInterval = 5
    @ObservationIgnored private var lastFreezeRefresh = Date.distantPast
    private(set) var freezeCount = 0
    /// Apps locked to nap (`forceNap` flag): bundle id → name. Kept across launches.
    private(set) var forced: [String: String] = (UserDefaults.standard.dictionary(forKey: "nappy.forcedNap.v1") as? [String: String]) ?? [:]
    // Reading properties of a fresh NSRunningApplication costs a LaunchServices round trip each, so the list of
    // regular apps is kept and only rebuilt when an app launches or quits (and once a minute as a safety net).
    @ObservationIgnored private var regularApps: [NSRunningApplication] = []
    @ObservationIgnored private var appListDirty = true
    @ObservationIgnored private var lastAppSync = Date.distantPast

    private static let protectedIDs: Set<String> = [
        "com.apple.finder", "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.universalcontrol",
    ]

    /// Running apps with a Dock icon and a menu bar, without re-reading every process each time.
    func runningRegularApps(_ now: Date = Date()) -> [NSRunningApplication] {
        if appListDirty || now.timeIntervalSince(lastAppSync) > 60 {
            regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            appListDirty = false; lastAppSync = now
        }
        return regularApps
    }

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
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.appListDirty = true }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.appTerminated(app) }
        }

        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: Main loop

    func tick() {
        guard settings.napEnabled else {
            resumeAll(reason: "nap turned off"); backgroundSince.removeAll()
            statusText = "Napping is off"
            return
        }
        let now = Date()
        let workspace = NSWorkspace.shared
        let frontPID = workspace.frontmostApplication?.processIdentifier
        // The window list and power-assertion list are only read when an app is actually about to nap, once per tick.
        var visibleCache: Set<pid_t>?, awakeCache: Set<pid_t>?
        func visible() -> Set<pid_t> {
            if let v = visibleCache { return v }
            let v = settings.onlyWithoutWindows ? pidsWithVisibleWindows() : []
            visibleCache = v; return v
        }
        func awake() -> Set<pid_t> {
            if let a = awakeCache { return a }
            let a = settings.respectPowerAssertions ? pidsHoldingAssertions() : []
            awakeCache = a; return a
        }
        let delay = TimeInterval(settings.delaySeconds)
        var alive = Set<pid_t>()

        for app in runningRegularApps(now) {
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
            let waited = now.timeIntervalSince(since)
            guard waited >= delay else { continue }
            #if !PUBLIC
            if flags.isOn(.napCooldown), let woke = lastWake[pid], now.timeIntervalSince(woke) < 600, waited < Self.cooldown {
                if skipReason[pid] != "cooldown" {
                    skipReason[pid] = "cooldown"
                    log.add("skip  \(app.localizedName ?? "App") (pid \(pid)) — cooldown after recent wake")
                    Stats.shared.recordAudit { $0.cooldownHolds += 1 }
                }
                continue
            }
            #endif
            if visible().contains(pid) || awake().contains(pid) {
                let reason = visible().contains(pid) ? "has a visible window" : "keeping Mac awake (power assertion)"
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
        #if !PUBLIC
        lastWake = lastWake.filter { alive.contains($0.key) }
        #endif
        auditNapped(now)
        maintainFrozen(now)
        persistPIDs()
        statusText = napped.isEmpty ? "Watching your apps" : "\(napped.count) app\(napped.count == 1 ? "" : "s") napping"
    }

    // MARK: Suspend / resume

    func isForced(bundleID: String?) -> Bool {
        guard flags.isOn(.forceNap), let bundleID else { return false }
        return forced[bundleID] != nil
    }

    func setForced(bundleID: String, name: String, on: Bool) {
        if on { forced[bundleID] = name } else { forced[bundleID] = nil }
        UserDefaults.standard.set(forced, forKey: "nappy.forcedNap.v1")
        log.add("force \(name): \(on ? "locked, will be paused completely while it naps" : "released")")
        // Apply it to the app if it is napping right now.
        for i in napped.indices where napped[i].bundleID == bundleID {
            if on {
                napped[i].hardFreeze = true
                lastFreezeRefresh = .distantPast        // paused on the next tick, after the window and awake checks
            } else {
                for p in napped[i].frozen { kill(p, SIGCONT) }
                napped[i].frozen = []; napped[i].isStopped = false; napped[i].hardFreeze = false
            }
        }
    }

    func isNapped(_ pid: pid_t) -> Bool { napped.contains { $0.pid == pid } }

    func isNappable(_ app: NSRunningApplication) -> Bool {
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
        // Helpers macOS already runs in the background (hidden tabs, idle XPC services) are not touched at all, so
        // there is nothing of ours to undo on them. The app itself is always throttled and always restored.
        let preBG: Set<pid_t> = flags.isOn(.groupAudit) ? Set(group.filter { $0 != pid && isBackground($0) }) : []
        guard setBackground(group.filter { !preBG.contains($0) }, true) else {
            log.add("error \(name) (pid \(pid)) — setpriority failed")
            return
        }
        skipReason[pid] = nil
        log.add("nap   \(name) (pid \(pid), +\(group.count - 1) helpers) after \(Int(idle)) s in background")
        napped.append(NappedApp(pid: pid, bundleID: app.bundleIdentifier,
                                name: app.localizedName ?? "App", icon: app.icon, pids: group, since: Date(), preBG: preBG))
        if !preBG.isEmpty {
            log.add("audit \(name): \(preBG.count) of \(group.count) processes were already background — not touched, not restored")
            #if !PUBLIC
            Stats.shared.recordAudit { $0.leftAlone += preBG.count }
            #endif
        }
        #if !PUBLIC
        Stats.shared.recordNap()
        #endif
        if flags.isOn(.freezeHelpers), isElectron(app), let i = napped.indices.last {
            napped[i].electron = true
            lastFreezeRefresh = .distantPast   // freeze on the next tick, after the visible-window and assertion checks
        }
        if isForced(bundleID: app.bundleIdentifier), let i = napped.indices.last {
            napped[i].hardFreeze = true
            lastFreezeRefresh = .distantPast
        }
        persistPIDs()
    }

    func resume(pid: pid_t, reason: String = "restored manually") {
        if let entry = napped.first(where: { $0.pid == pid }) {
            restore(entry)
            #if !PUBLIC
            lastWake[pid] = Date()
            #endif
            log.add("wake  \(entry.name) (pid \(pid)) — \(reason), napped \(Int(Date().timeIntervalSince(entry.since))) s")
            #if !PUBLIC
            Stats.shared.recordWake(app: entry.name, reason: reason, napped: Date().timeIntervalSince(entry.since))
            #endif
        }
        napped.removeAll { $0.pid == pid }
        backgroundSince[pid] = nil
        persistPIDs()
    }

    func resumeAll(reason: String = "restore all") {
        for app in napped {
            restore(app)
            log.add("wake  \(app.name) (pid \(app.pid)) — \(reason)")
            #if !PUBLIC
            Stats.shared.recordWake(app: app.name, reason: reason, napped: Date().timeIntervalSince(app.since))
            #endif
        }
        if !napped.isEmpty { napped.removeAll() }
        persistPIDs()
    }

    /// Puts every process of an app (including ones that joined later) back to normal, and with the audit flag checks it worked.
    private func restore(_ entry: NappedApp) {
        for pid in entry.frozen { kill(pid, SIGCONT) }
        let all = Set(entry.pids + descendants(of: entry.pid))
        let targets = Array(all.subtracting(entry.preBG))
        setBackground(targets, false)
        guard flags.isOn(.groupAudit) else { return }
        var stuck = targets.filter { isAlive($0) && isBackground($0) }
        if !stuck.isEmpty { setBackground(stuck, false); stuck = stuck.filter { isAlive($0) && isBackground($0) } }
        if !stuck.isEmpty {
            log.add("audit \(entry.name): \(stuck.count) of \(targets.count) processes still throttled after restore (pids \(stuck.prefix(5).map(String.init).joined(separator: ", ")))")
            #if !PUBLIC
            Stats.shared.recordAudit { $0.restoreStuck += stuck.count }
            #endif
        }
    }

    /// Every 30 s: helpers that appeared after the nap get throttled, and throttles that were undone are re-applied.
    private func auditNapped(_ now: Date) {
        guard flags.isOn(.groupAudit), !napped.isEmpty, now.timeIntervalSince(lastAudit) >= 30 else { return }
        lastAudit = now
        let owner = ProcessTable.members(of: napped.map(\.pid))
        #if !PUBLIC
        let batch = flags.isOn(.batchSave)
        var total = AuditCounts()
        #endif
        for i in napped.indices {
            let app = napped[i]
            let current = Set(owner.filter { $0.value == app.pid }.keys)
            let known = Set(app.pids)
            let joined = current.subtracting(known).filter { $0 > 1 && isAlive($0) }
            let drifted = known.filter { $0 > 1 && isAlive($0) && !app.preBG.contains($0) && !isBackground($0) }
            if !joined.isEmpty { setBackground(Array(joined), true) }
            if !drifted.isEmpty { setBackground(Array(drifted), true) }
            napped[i].pids = Array(known.union(joined)).filter(isAlive)
            #if !PUBLIC
            let checked = known.count
            if batch { total.checks += checked; total.joined += joined.count; total.drifted += drifted.count }
            else { Stats.shared.recordAudit { $0.checks += checked; $0.joined += joined.count; $0.drifted += drifted.count } }
            #endif
            if !joined.isEmpty || !drifted.isEmpty {
                log.add("audit \(app.name): +\(joined.count) helpers joined late, \(drifted.count) throttles re-applied")
            }
        }
        #if !PUBLIC
        if batch { Stats.shared.recordAudit { $0.checks += total.checks; $0.joined += total.joined; $0.drifted += total.drifted } }
        #endif
    }

    /// getpriority() doesn't follow the background flag reliably; the task's scheduling priority does (4 = background, 31–46 = normal).
    // MARK: Freeze Electron helpers

    private func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    /// Chromium helper kind from the process arguments: only renderers and the GPU process are ever frozen —
    /// never the main process, the network service or audio, so connections and sound keep working.
    private static var freezableCache: [pid_t: Bool] = [:]

    private static func isFreezable(_ pid: pid_t) -> Bool {
        if let known = freezableCache[pid] { return known }   // a process's arguments never change: read them once
        let result = readFreezable(pid)
        freezableCache[pid] = result
        return result
    }

    private static func readFreezable(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return false }
        let text = String(decoding: buf.prefix(size), as: UTF8.self)
        return text.contains("--type=renderer") || text.contains("--type=gpu-process")
    }

    /// Every tick: run the 55 s stopped / 5 s running cycle. Every 15 s: freeze helpers that joined late, and
    /// release everything if the app got a visible window or started keeping the Mac awake.
    private func maintainFrozen(_ now: Date) {
        // Two modes share this code: Electron helpers (`freezeHelpers`: renderer/GPU only, 55 s stopped / 5 s running)
        // and locked apps (`forceNap`: the whole app stays stopped, so it cannot wake itself).
        func helpersMode(_ a: NappedApp) -> Bool { a.electron && flags.isOn(.freezeHelpers) }
        func hardMode(_ a: NappedApp) -> Bool { a.hardFreeze && flags.isOn(.forceNap) }
        guard napped.contains(where: { helpersMode($0) || hardMode($0) }) else { return }
        let refresh = now.timeIntervalSince(lastFreezeRefresh) >= 15
        var visible = Set<pid_t>(), awake = Set<pid_t>(), owner: [pid_t: pid_t] = [:]
        if refresh {
            lastFreezeRefresh = now
            visible = pidsWithUncoveredWindows()    // a window hidden behind other windows does not count
            awake = pidsHoldingAssertions()
            owner = ProcessTable.members(of: napped.filter { helpersMode($0) || hardMode($0) }.map(\.pid))
            let live = Set(owner.keys)
            Self.freezableCache = Self.freezableCache.filter { live.contains($0.key) }   // forget processes that are gone
        }
        for i in napped.indices where helpersMode(napped[i]) || hardMode(napped[i]) {
            let hard = hardMode(napped[i])
            if refresh {
                let group = Set(napped[i].pids).union(owner.filter { $0.value == napped[i].pid }.keys)
                let blocked = visible.contains(napped[i].pid) || !group.isDisjoint(with: awake)
                napped[i].freezeNote = !blocked ? "" : (visible.contains(napped[i].pid) ? "window showing" : "keeping Mac awake")
                if blocked {
                    if !napped[i].frozen.isEmpty {
                        for p in napped[i].frozen { kill(p, SIGCONT) }
                        log.add("freeze \(napped[i].name): released \(napped[i].frozen.count) processes (window visible or keeping Mac awake)")
                        napped[i].frozen = []; napped[i].isStopped = false
                    }
                } else {
                    let fresh = group.filter {
                        $0 > 1 && $0 != selfPID && !napped[i].frozen.contains($0)
                            && (hard || ($0 != napped[i].pid && Self.isFreezable($0)))
                    }
                    if !fresh.isEmpty {
                        let stopNow = napped[i].frozen.isEmpty || napped[i].isStopped
                        for p in fresh {
                            if stopNow { kill(p, SIGSTOP) }
                            napped[i].frozen.insert(p)
                        }
                        if napped[i].frozen.count == fresh.count {
                            napped[i].isStopped = stopNow
                            napped[i].nextThaw = now.addingTimeInterval(Self.freezeFor)
                            freezeCount += 1
                            log.add(hard ? "freeze \(napped[i].name): paused the whole app (\(fresh.count) processes), only Nappy can wake it"
                                         : "freeze \(napped[i].name): stopped \(fresh.count) renderer/GPU helpers")
                        }
                        napped[i].pids = Array(Set(napped[i].pids).union(fresh))
                    }
                }
            }
            guard !napped[i].frozen.isEmpty else { continue }
            napped[i].frozen = napped[i].frozen.filter(isAlive)
            if hard { continue }                       // a locked app is never let out for a moment
            if napped[i].isStopped, now >= napped[i].nextThaw {
                for p in napped[i].frozen { kill(p, SIGCONT) }
                napped[i].isStopped = false; napped[i].thawUntil = now.addingTimeInterval(Self.thawFor)
            } else if !napped[i].isStopped, now >= napped[i].thawUntil {
                for p in napped[i].frozen { kill(p, SIGSTOP) }
                napped[i].isStopped = true; napped[i].nextThaw = now.addingTimeInterval(Self.freezeFor)
            }
        }
    }

    /// Lets every frozen helper run again (flag turned off).
    func thawAll() {
        for i in napped.indices where !napped[i].frozen.isEmpty {
            for p in napped[i].frozen { kill(p, SIGCONT) }
            napped[i].frozen = []; napped[i].isStopped = false
        }
    }

    private func isBackground(_ pid: pid_t) -> Bool {
        var ti = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        return n > 0 && ti.pti_priority <= 4
    }
    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private func appActivated(_ app: NSRunningApplication) {
        backgroundSince[app.processIdentifier] = nil
        if isNapped(app.processIdentifier) { resume(pid: app.processIdentifier, reason: "switched to app") }
    }

    private func appTerminated(_ app: NSRunningApplication) {
        appListDirty = true
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
        for (other, r) in ProcessTable.responsibleMap() where other != pid && r == pid { result.insert(other) }
        result.remove(pid)
        return Array(result)
    }

    /// `responsibility_get_pid_responsible_for_pid` — the call Activity Monitor uses to group helpers under their app.
    static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
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

    /// PIDs with a window that can really be seen: at least a few percent of it is not covered by windows in front of it.
    /// (`pidsWithVisibleWindows` also counts windows hidden behind others, which is too strict for pausing an app.)
    private func pidsWithUncoveredWindows() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result = Set<pid_t>()
        var inFront: [CGRect] = []                       // the list is ordered front to back
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width >= 60, rect.height >= 60 else { continue }
            var uncovered = 0
            for ix in 0..<7 {
                for iy in 0..<5 {
                    let p = CGPoint(x: rect.minX + rect.width * (CGFloat(ix) + 0.5) / 7, y: rect.minY + rect.height * (CGFloat(iy) + 0.5) / 5)
                    if !inFront.contains(where: { $0.contains(p) }) { uncovered += 1 }
                }
            }
            if uncovered >= 3 { result.insert(pid) }
            inFront.append(rect)
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
