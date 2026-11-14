import SwiftUI

/// What a flag shows under its switch once it is on.
struct FlagDetail: View {
    let flag: Flag
    private var stats = Stats.shared

    init(flag: Flag) { self.flag = flag }

    var body: some View {
        switch flag {
        case .pinPanel, .batchSave: EmptyView()
        case .powerStats: power
        case .wakeStats: wake
        case .napCooldown: cooldown
        case .freezeHelpers: freeze
        case .groupAudit: auditView
        }
    }

    // MARK: Power

    private var power: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Background apps only, Nappy Off vs On").font(.caption2).foregroundStyle(.secondary)
            header
            line("CPU", off: "\(fmt(stats.off.cpuPercent))%", on: "\(fmt(stats.on.cpuPercent))%")
            line("Cycles", off: "\(fmt(stats.off.gigacyclesPerSec)) G/s", on: "\(fmt(stats.on.gigacyclesPerSec)) G/s")
            Divider()
            if stats.hasBaseline, let cpu = stats.saved(\.cpuPercent) {
                HStack {
                    Text("Saved").font(.callout.weight(.semibold))
                    Spacer()
                    Text(pct(cpu) + " CPU").font(.callout.weight(.semibold)).foregroundStyle(cpu > 0 ? .green : .orange)
                    if let cyc = stats.saved(\.gigacyclesPerSec) { Text("· " + pct(cyc) + " cycles").font(.caption).foregroundStyle(.secondary) }
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
            Text("Top apps by CPU").font(.caption2).foregroundStyle(.secondary)
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
            .map { "\(Int($0.0.rounded(.up))) s more with Nappy \($0.1)" }
        return "Collecting — " + parts.joined(separator: " and ") + ". Switch Nappy Off for a couple of minutes to get a baseline."
    }

    // MARK: Wake

    private var wake: some View {
        let e = stats.events
        return VStack(alignment: .leading, spacing: 6) {
            statLine("Naps started", "\(e.naps)")
            statLine("Wakes by Nappy", "\(e.wakes)")
            Text("\(e.wakesByActivation) switched to app · \(e.wakesManual) manual · \(e.wakesOther) other")
                .font(.caption2).foregroundStyle(.secondary)
            if e.wakes > 0 { statLine("Avg nap length", duration(e.napSeconds / Double(e.wakes))) }
            let top = e.wakesByApp.sorted { $0.value > $1.value }.prefix(3)
            if !top.isEmpty {
                Text("Most woken: " + top.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            line("CPU wakeups/s", off: fmt(stats.off.wakeupsPerSec, 0), on: fmt(stats.on.wakeupsPerSec, 0), showHeader: true)
            if stats.hasBaseline {
                HStack {
                    Text("Wakeups limited").font(.callout.weight(.semibold))
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

    // MARK: Freeze

    private var freeze: some View {
        let apps = NapEngine.shared.napped.filter { !$0.frozen.isEmpty }
        let total = apps.reduce(0) { $0 + $1.frozen.count }
        return VStack(alignment: .leading, spacing: 6) {
            statLine("Helpers frozen now", "\(total) in \(apps.count) app\(apps.count == 1 ? "" : "s")")
            statLine("Freezes since launch", "\(NapEngine.shared.freezeCount)")
            ForEach(apps) { app in
                HStack {
                    Text(app.name).font(.caption)
                    Spacer()
                    Text("\(app.frozen.count) \(app.isStopped ? "stopped" : "running 5 s")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text("Only Electron apps with no visible window and nothing keeping the Mac awake. Compare CPU in Top apps under Power stats.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    // MARK: Cooldown / audit

    private var cooldown: some View {
        VStack(alignment: .leading, spacing: 6) {
            statLine("Naps held back", "\(stats.audit.cooldownHolds)")
            Text("Apps woken in the last 10 min must stay in the background for 3 min before they nap again.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Reset") { stats.reset() }.controlSize(.mini) }
        }
        .padding(.leading, 4)
    }

    private var auditView: some View {
        let a = stats.audit
        return VStack(alignment: .leading, spacing: 6) {
            statLine("Helpers checked", "\(a.checks)")
            statLine("Joined late (throttled)", "\(a.joined)")
            statLine("Throttle undone (re-applied)", "\(a.drifted)")
            statLine("Already background (left alone)", "\(a.leftAlone)")
            statLine("Still throttled after restore", "\(a.restoreStuck)")
            HStack { Spacer(); Button("Reset") { stats.reset() }.controlSize(.mini) }
        }
        .padding(.leading, 4)
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Spacer()
            Text("Off · \(duration(stats.off.seconds))").frame(width: 92, alignment: .trailing)
            Text("On · \(duration(stats.on.seconds))").frame(width: 92, alignment: .trailing)
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
