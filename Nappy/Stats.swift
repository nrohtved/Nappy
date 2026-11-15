#if !PUBLIC
import AppKit
import Darwin
import Observation

/// One side of the A/B comparison: everything the background apps used while Nappy was in one mode.
struct StatBucket: Codable {
    var seconds = 0.0
    var cpuSeconds = 0.0      // CPU time used by background apps
    var cycles = 0.0          // CPU cycles used by background apps
    var wakeups = 0.0         // CPU interrupt wakeups caused by background apps

    var cpuPercent: Double { seconds > 0 ? cpuSeconds / seconds * 100 : 0 }        // % of one core
    var gigacyclesPerSec: Double { seconds > 0 ? cycles / seconds / 1e9 : 0 }
    var wakeupsPerSec: Double { seconds > 0 ? wakeups / seconds : 0 }
}

/// Per-app breakdown of the same comparison.
struct AppStat: Codable {
    var off = StatBucket()
    var on = StatBucket()
}

/// What the group audit and the cooldown did.
struct AuditCounts: Codable {
    var checks = 0            // helper processes checked
    var joined = 0            // helpers that appeared after the nap and were throttled late
    var drifted = 0           // helpers whose throttle had been undone and was re-applied
    var leftAlone = 0         // helpers that were already background before the nap, so not restored to normal
    var restoreStuck = 0      // helpers still throttled after a restore
    var cooldownHolds = 0     // naps held back by the cooldown
}

/// Counts of what Nappy itself did.
struct NapEvents: Codable {
    var naps = 0
    var wakes = 0
    var wakesByActivation = 0     // you switched to the app
    var wakesManual = 0           // Restore button / added to Ignored
    var wakesOther = 0            // Nappy or nap turned off, quit, …
    var napSeconds = 0.0
    var wakesByApp: [String: Int] = [:]
}

/// Samples what background apps consume while Nappy is Off versus On, and counts naps and wakes.
/// Powers the `powerStats` and `wakeStats` flags. Numbers are CPU time, cycles and interrupt wakeups
/// (what drives power use), not watts: macOS gives no per-process energy figure without root.
@Observable
final class Stats {
    static let shared = Stats()

    private(set) var off = StatBucket()
    private(set) var on = StatBucket()
    private(set) var events = NapEvents()
    private(set) var apps: [String: AppStat] = [:]
    private(set) var audit = AuditCounts()
    private(set) var liveNote = ""

    private struct Counters { var cpu: Double, cycles: Double, wakeups: Double }

    @ObservationIgnored private var previous: [pid_t: Counters] = [:]
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastMode: Bool?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let key = "nappy.stats.v1"
    @ObservationIgnored private let flags = FeatureFlags.shared
    @ObservationIgnored private let settings = Settings.shared
    @ObservationIgnored private static var timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    private struct Stored: Codable { var off: StatBucket, on: StatBucket, events: NapEvents, apps: [String: AppStat]?, audit: AuditCounts? }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            off = s.off; on = s.on; events = s.events; apps = s.apps ?? [:]; audit = s.audit ?? AuditCounts()
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Derived

    static let minSeconds = 120.0
    var hasBaseline: Bool { off.seconds >= Self.minSeconds && on.seconds >= Self.minSeconds }

    /// Share of background CPU saved: 1 − (On ÷ Off). Negative means Nappy On used more.
    func saved(_ value: (StatBucket) -> Double) -> Double? {
        guard hasBaseline, value(off) > 0 else { return nil }
        return 1 - value(on) / value(off)
    }

    /// Wakeups avoided while On, estimated from the Off rate.
    var wakeupsLimited: Double {
        guard hasBaseline else { return 0 }
        return max(0, off.wakeupsPerSec - on.wakeupsPerSec) * on.seconds
    }

    func reset() {
        off = StatBucket(); on = StatBucket(); events = NapEvents(); apps = [:]; audit = AuditCounts()
        previous = [:]; lastSample = nil; lastMode = nil
        BatteryStats.shared.reset()
        save()
    }

    // MARK: Events (called by NapEngine)

    func recordAudit(_ change: (inout AuditCounts) -> Void) { change(&audit); save() }

    func recordNap() {
        guard flags.isOn(.wakeStats) else { return }
        events.naps += 1; save()
    }

    func recordWake(app: String, reason: String, napped: TimeInterval) {
        guard flags.isOn(.wakeStats) else { return }
        events.wakes += 1
        events.napSeconds += napped
        events.wakesByApp[app, default: 0] += 1
        switch reason {
        case "switched to app", "now frontmost": events.wakesByActivation += 1
        case "restored manually", "added to ignored": events.wakesManual += 1
        default: events.wakesOther += 1
        }
        save()
    }

    // MARK: Sampling

    private func sample() {
        flushIfDue(Date())
        guard flags.isOn(.powerStats) || flags.isOn(.wakeStats) else {
            previous = [:]; lastSample = nil; lastMode = nil; liveNote = ""
            return
        }
        let now = Date()
        let mode = settings.napEnabled
        let engine = NapEngine.shared
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let rootApps = engine.runningRegularApps().filter {
            engine.isNappable($0) && $0.processIdentifier != front && !settings.isIgnored($0.bundleIdentifier)
        }
        let roots = rootApps.map(\.processIdentifier)
        let owner = ProcessTable.members(of: roots)
        let members = Set(owner.keys)
        var perApp: [pid_t: Counters] = [:]

        var current: [pid_t: Counters] = [:]
        var dCPU = 0.0, dCycles = 0.0, dWake = 0.0
        for pid in members {
            guard let c = Self.read(pid) else { continue }
            current[pid] = c
            if let p = previous[pid] {
                let d = Counters(cpu: max(0, c.cpu - p.cpu), cycles: max(0, c.cycles - p.cycles), wakeups: max(0, c.wakeups - p.wakeups))
                dCPU += d.cpu; dCycles += d.cycles; dWake += d.wakeups
                if let root = owner[pid] {
                    var a = perApp[root] ?? Counters(cpu: 0, cycles: 0, wakeups: 0)
                    a.cpu += d.cpu; a.cycles += d.cycles; a.wakeups += d.wakeups
                    perApp[root] = a
                }
            }
        }
        let dt = lastSample.map { now.timeIntervalSince($0) } ?? 0
        let usable = lastSample != nil && lastMode == mode && dt > 0 && dt < 40
        previous = current; lastSample = now; lastMode = mode
        guard usable else { return }

        func add(_ b: inout StatBucket) {
            b.seconds += dt; b.cpuSeconds += dCPU; b.cycles += dCycles; b.wakeups += dWake
        }
        if mode { add(&on) } else { add(&off) }
        for app in rootApps {
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            let d = perApp[app.processIdentifier] ?? Counters(cpu: 0, cycles: 0, wakeups: 0)
            var stat = apps[name] ?? AppStat()
            if mode { stat.on.seconds += dt; stat.on.cpuSeconds += d.cpu; stat.on.cycles += d.cycles; stat.on.wakeups += d.wakeups }
            else { stat.off.seconds += dt; stat.off.cpuSeconds += d.cpu; stat.off.cycles += d.cycles; stat.off.wakeups += d.wakeups }
            apps[name] = stat
        }
        liveNote = "\(members.count) processes in \(roots.count) apps in the background"
        save()
    }

    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastWrite = Date.distantPast

    /// With the `batchSave` flag the write is postponed and done at most once a minute (see `flushIfDue`).
    private func save() {
        if flags.isOn(.batchSave) { dirty = true; return }
        write()
    }

    /// Writes any postponed changes now (flag turned off, app quitting).
    func flush() { if dirty { write() } }

    private func flushIfDue(_ now: Date) {
        if dirty, now.timeIntervalSince(lastWrite) >= 60 { write() }
    }

    private func write() {
        dirty = false
        lastWrite = Date()
        let s = Stored(off: off, on: on, events: events, apps: apps, audit: audit)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }

    private static func read(_ pid: pid_t) -> Counters? {
        var ru = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard r == 0 else { return nil }
        let toSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        return Counters(cpu: Double(ru.ri_user_time + ru.ri_system_time) * toSeconds,
                        cycles: Double(ru.ri_cycles), wakeups: Double(ru.ri_interrupt_wkups))
    }
}
#endif
