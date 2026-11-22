#if !PUBLIC
import SwiftUI

/// What a flag shows under its switch once it is on.
struct FlagDetail: View {
    let flag: Flag
    private var stats = Stats.shared

    init(flag: Flag) { self.flag = flag }

    var body: some View {
        switch flag {
        case .pinPanel, .batchSave, .pictureInPicture, .blurPanel, .coffeeCard, .fullScreenGuard, .spareOtherApps, .panelOneDesktop: EmptyView()
        case .tintPanel: tintOptions
        case .wakeOnHover: hoverStats
        case .powerStats: power
        case .wakeStats: wake
        case .napCooldown: cooldown
        case .freezeHelpers: freeze
        case .batteryStats: battery
        case .forceNap: lockedApps
        case .groupAudit: auditView
        }
    }

    // MARK: Power

    private var power: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps in the background, with Nappy off vs on").font(.caption2).foregroundStyle(.secondary)
            header
            line("Processor use", off: "\(fmt(stats.off.cpuPercent))%", on: "\(fmt(stats.on.cpuPercent))%")
            line("Processor work", off: "\(fmt(stats.off.gigacyclesPerSec)) G/s", on: "\(fmt(stats.on.gigacyclesPerSec)) G/s")
            Divider()
            if stats.hasBaseline, let cpu = stats.saved(\.cpuPercent) {
                HStack {
                    Text("Saved").font(.callout.weight(.semibold))
                    Spacer()
                    Text(pct(cpu) + " less processor use").font(.callout.weight(.semibold)).foregroundStyle(cpu > 0 ? .green : .orange)
                    if let cyc = stats.saved(\.gigacyclesPerSec) { Text("· " + pct(cyc) + " less work").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text(missing).font(.caption).foregroundStyle(.secondary)
            }
            topApps
            footer
        }
        .padding(.leading, 4)
    }

    /// Who uses the CPU: the biggest apps, Off vs On, so a total that barely moves can be explained.
    @ViewBuilder private var topApps: some View {
        let rows = topRows
        if !rows.isEmpty {
            Divider()
            Text("Busiest apps").font(.caption2).foregroundStyle(.secondary)
            ForEach(rows, id: \.key) { row in
                let name = row.key, app = row.value
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 9)).foregroundStyle(.indigo)
                        .opacity(NapEngine.shared.napped.contains { $0.name == name } ? 1 : 0)
                    Text(name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(app.off.seconds > 0 ? "\(fmt(app.off.cpuPercent))%" : "–").frame(width: 56, alignment: .trailing)
                    Text(app.on.seconds > 0 ? "\(fmt(app.on.cpuPercent))%" : "–").frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private var topRows: [(key: String, value: AppStat)] {
        func total(_ a: AppStat) -> Double { a.off.cpuSeconds + a.on.cpuSeconds }
        let sorted = stats.apps.sorted { (x: (key: String, value: AppStat), y: (key: String, value: AppStat)) -> Bool in
            total(x.value) > total(y.value)
        }
        return Array(sorted.prefix(6))
    }

    private var missing: String {
        let need = { (b: StatBucket) in max(0, Stats.minSeconds - b.seconds) }
        let parts = [(need(stats.off), "Off"), (need(stats.on), "On")].filter { $0.0 > 0 }
            .map { "\(Int($0.0.rounded(.up))) more seconds with Nappy \($0.1.lowercased())" }
        return "Still measuring: needs " + parts.joined(separator: " and ") + ". Turn Nappy off for a few minutes to get something to compare with."
    }

    // MARK: Wake

    private var wake: some View {
        let e = stats.events
        return VStack(alignment: .leading, spacing: 6) {
            statLine("Times napped", "\(e.naps)")
            statLine("Times woken up", "\(e.wakes)")
            Text("\(e.wakesByActivation) you switched to the app · \(e.wakesManual) you pressed wake up · \(e.wakesOther) other reasons")
                .font(.caption2).foregroundStyle(.secondary)
            if e.wakes > 0 { statLine("Average nap", duration(e.napSeconds / Double(e.wakes))) }
            let top = e.wakesByApp.sorted { $0.value > $1.value }.prefix(3)
            if !top.isEmpty {
                Text("Woken up most: " + top.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            line("Processor wake-ups per second", off: fmt(stats.off.wakeupsPerSec, 0), on: fmt(stats.on.wakeupsPerSec, 0), showHeader: true)
            if stats.hasBaseline {
                HStack {
                    Text("Wake-ups prevented").font(.callout.weight(.semibold))
                    Spacer()
                    Text("≈ " + compact(stats.wakeupsLimited)).font(.callout.weight(.semibold)).foregroundStyle(.green)
                }
            } else {
                Text(missing).font(.caption).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(.leading, 4)
    }

    // MARK: Battery

    private var battery: some View {
        let b = BatteryStats.shared
        return VStack(alignment: .leading, spacing: 6) {
            if !b.available {
                Text("This Mac doesn't report battery power, so it can't be measured.").font(.caption).foregroundStyle(.secondary)
            } else {
                if let now = b.now {
                    statLine("Right now", "\(now.watts.map { String(format: "%.1f W", $0) } ?? "–") · \(now.percent.map { "\($0)%" } ?? "–") · \(now.pluggedIn ? "plugged in" : "on battery")")
                }
                headerView(b.off.seconds, b.on.seconds)
                line("Whole Mac power", off: b.off.seconds > 0 ? watts(b.off.watts) : "–", on: b.on.seconds > 0 ? watts(b.on.watts) : "–")
                line("Battery life (full charge)", off: b.hours(b.off).map(hours) ?? "–", on: b.hours(b.on).map(hours) ?? "–")
                Divider()
                if let saved = b.saved {
                    HStack {
                        Text("Saved").font(.callout.weight(.semibold))
                        Spacer()
                        Text(pct(saved) + " less power").font(.callout.weight(.semibold)).foregroundStyle(saved > 0 ? .green : .orange)
                        if let a = b.hours(b.off), let c = b.hours(b.on) {
                            Text("· \(c >= a ? "+" : "−")\(Int(abs(c - a) * 60)) min").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    let need = { (p: PowerBucket) in max(0, BatteryStats.minSeconds - p.seconds) }
                    let parts = [(need(b.off), "Off"), (need(b.on), "On")].filter { $0.0 > 0 }
                        .map { "\(Int(($0.0 / 60).rounded(.up))) more min with Nappy \($0.1.lowercased())" }
                    Text("Still measuring: needs " + parts.joined(separator: " and ") + ". The battery updates about once a minute.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("This is the power of the whole Mac. Screen brightness and what you are doing change it too, so compare over a long time.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Reset") { b.reset() }.controlSize(.mini) }
            }
        }
        .padding(.leading, 4)
    }

    private func watts(_ w: Double) -> String { String(format: "%.2f W", w) }
    private func hours(_ h: Double) -> String { String(format: "%.1f h", h) }

    // MARK: Wake on hover

    private var hoverStats: some View {
        VStack(alignment: .leading, spacing: 6) {
            statLine("Woken by the pointer", "\(NapEngine.shared.hoverWakes)")
            Text("Applies to apps locked with the lock button that are paused: the pointer over one of their windows or over the Dock wakes them, and so does a window of theirs becoming visible, or Activity Monitor coming to the front.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    // MARK: Pinned window background

    private var tintOptions: some View {
        @Bindable var flags = FeatureFlags.shared
        return HStack(spacing: 8) {
            Text("See-through").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $flags.tintOpacity, in: 0...1).controlSize(.small)
            Text("Solid").font(.caption2).foregroundStyle(.secondary)
            Text("\(Int((flags.tintOpacity * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().frame(width: 34, alignment: .trailing)
        }
        .padding(.leading, 4)
    }

    // MARK: Locked apps

    private var lockedApps: some View {
        let engine = NapEngine.shared
        let locked = engine.forced.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        let paused = engine.napped.filter { $0.hardFreeze && !$0.frozen.isEmpty }
        return VStack(alignment: .leading, spacing: 6) {
            statLine("Locked apps", "\(locked.count)")
            statLine("Paused completely now", "\(paused.count)")
            ForEach(locked, id: \.key) { id, name in
                HStack {
                    Text(name).font(.caption)
                    Spacer()
                    Text(lockStatus(id, paused: paused)).font(.caption2).foregroundStyle(.secondary)
                    Button("Release") { engine.setForced(bundleID: id, name: name, on: false) }.controlSize(.mini)
                }
            }
            Text("Use the lock button next to an app in Napping Now. A locked app that is napping with no window showing, and nothing keeping the Mac awake, is stopped completely, so it can't wake itself (no timers, no background work, no notifications). It wakes the moment you switch to it or press wake up, and everything is let go if Nappy quits.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    /// Why a locked app is, or is not, paused right now.
    private func lockStatus(_ id: String, paused: [NappedApp]) -> String {
        guard let entry = NapEngine.shared.napped.first(where: { $0.bundleID == id }) else { return "not napping" }
        if !entry.frozen.isEmpty { return "paused" }
        return entry.freezeNote.isEmpty ? "starting" : "waiting: \(entry.freezeNote)"
    }

    // MARK: Freeze

    private var freeze: some View {
        let apps = NapEngine.shared.napped.filter { !$0.frozen.isEmpty }
        let total = apps.reduce(0) { $0 + $1.frozen.count }
        return VStack(alignment: .leading, spacing: 6) {
            statLine("Parts paused now", "\(total) in \(apps.count) app\(apps.count == 1 ? "" : "s")")
            statLine("Times paused since opening", "\(NapEngine.shared.freezeCount)")
            ForEach(apps) { app in
                HStack {
                    Text(app.name).font(.caption)
                    Spacer()
                    Text("\(app.frozen.count) \(app.isStopped ? "paused" : "running for 5 s")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text("Only Electron apps with no window showing and nothing keeping the Mac awake. To see the effect, look at \"Busiest apps\" under \"Savings report\".")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    // MARK: Cooldown / audit

    private var cooldown: some View {
        VStack(alignment: .leading, spacing: 6) {
            statLine("Naps delayed", "\(stats.audit.cooldownHolds)")
            Text("An app you just woke up waits 3 min in the background before it can nap again.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Reset") { stats.reset() }.controlSize(.mini) }
        }
        .padding(.leading, 4)
    }

    private var auditView: some View {
        let a = stats.audit
        return VStack(alignment: .leading, spacing: 6) {
            statLine("Helpers checked", "\(a.checks)")
            statLine("Started late (now napping)", "\(a.joined)")
            statLine("Slowdown lost (applied again)", "\(a.drifted)")
            statLine("Already slowed by macOS (left alone)", "\(a.leftAlone)")
            statLine("Still slowed after waking", "\(a.restoreStuck)")
            HStack { Spacer(); Button("Reset") { stats.reset() }.controlSize(.mini) }
        }
        .padding(.leading, 4)
    }

    // MARK: Pieces

    private var header: some View { headerView(stats.off.seconds, stats.on.seconds) }

    private func headerView(_ offSeconds: Double, _ onSeconds: Double) -> some View {
        HStack {
            Spacer()
            Text("Off · \(duration(offSeconds))").frame(width: 92, alignment: .trailing)
            Text("On · \(duration(onSeconds))").frame(width: 92, alignment: .trailing)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func line(_ title: String, off: String, on: String, showHeader: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showHeader { header }
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(off).frame(width: 92, alignment: .trailing)
                Text(on).frame(width: 92, alignment: .trailing)
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }

    private func statLine(_ title: String, _ value: String) -> some View {
        HStack { Text(title).font(.caption); Spacer(); Text(value).font(.system(size: 11, design: .monospaced)) }
    }

    private var footer: some View {
        HStack {
            Text(stats.liveNote).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Reset") { stats.reset() }.controlSize(.mini)
        }
    }

    private func fmt(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    private func compact(_ v: Double) -> String {
        v >= 1e6 ? String(format: "%.1fM", v / 1e6) : v >= 1e3 ? String(format: "%.1fk", v / 1e3) : String(format: "%.0f", v)
    }
    private func duration(_ s: Double) -> String {
        s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : String(format: "%.1f h", s / 3600)
    }
}
#endif
