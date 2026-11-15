#if !PUBLIC
import Foundation
import IOKit
import Observation

/// One reading of the battery's own power counters (AppleSmartBattery in the IO registry).
struct BatteryReading {
    var accumulatedLoad: UInt64?   // sum of the whole-Mac power draw in mW, added to once per second
    var loadCount: UInt64?         // how many one-second readings are in that sum
    var watts: Double?             // power draw right now
    var percent: Int?
    var pluggedIn = false
    var fullWh: Double?            // energy of a full charge
}

enum BatteryReader {
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        let batteryData = props["BatteryData"] as? [String: Any] ?? [:]
        func number(_ d: [String: Any], _ key: String) -> NSNumber? { d[key] as? NSNumber }

        var r = BatteryReading()
        r.accumulatedLoad = number(telemetry, "AccumulatedSystemLoad")?.uint64Value
        r.loadCount = number(telemetry, "SystemLoadAccumulatorCount")?.uint64Value
        let volts = number(props, "Voltage")?.doubleValue ?? 0          // mV
        if let load = number(telemetry, "SystemLoad")?.doubleValue, load > 0 {
            r.watts = load / 1000
        } else if let raw = number(props, "Amperage")?.uint64Value {
            let amps = Int64(bitPattern: raw)                           // negative while discharging
            if amps < 0 { r.watts = Double(-amps) * volts / 1e6 }
        }
        r.percent = number(props, "CurrentCapacity")?.intValue
        r.pluggedIn = (props["ExternalConnected"] as? Bool) ?? false
        if let mAh = (number(batteryData, "FullChargeCapacity") ?? number(batteryData, "AppleRawMaxCapacity"))?.doubleValue, volts > 0 {
            r.fullWh = mAh * volts / 1e6
        }
        return r
    }
}

struct PowerBucket: Codable {
    var seconds = 0.0
    var joules = 0.0
    var watts: Double { seconds > 0 ? joules / seconds : 0 }
}

/// Whole-Mac power draw with Nappy Off versus On, from the battery's own counters. The counters refresh about once
/// a minute and hold the average over that minute, so each refresh is credited to the mode that was active for the
/// whole minute; a minute that spans a switch is dropped. Powers the `batteryStats` flag.
@Observable
final class BatteryStats {
    static let shared = BatteryStats()

    private(set) var off = PowerBucket()
    private(set) var on = PowerBucket()
    private(set) var now: BatteryReading?
    private(set) var available = true

    static let minSeconds = 600.0

    @ObservationIgnored private var seen: (acc: UInt64, cnt: UInt64)?
    @ObservationIgnored private var valid = false
    @ObservationIgnored private var lastMode: Bool?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let key = "nappy.battery.v1"
    @ObservationIgnored private let flags = FeatureFlags.shared
    @ObservationIgnored private let settings = Settings.shared

    private struct Stored: Codable { var off: PowerBucket, on: PowerBucket }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            off = s.off; on = s.on
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

    var hasBaseline: Bool { off.seconds >= Self.minSeconds && on.seconds >= Self.minSeconds }

    /// Share of power saved: 1 − (On ÷ Off).
    var saved: Double? { hasBaseline && off.watts > 0 ? 1 - on.watts / off.watts : nil }

    /// Hours a full charge lasts at that draw.
    func hours(_ bucket: PowerBucket) -> Double? {
        guard let wh = now?.fullWh, bucket.watts > 0 else { return nil }
        return wh / bucket.watts
    }

    func reset() {
        off = PowerBucket(); on = PowerBucket()
        seen = nil; valid = false; lastMode = nil
        save()
    }

    private func sample() {
        guard flags.isOn(.batteryStats) else { seen = nil; valid = false; lastMode = nil; return }
        guard let reading = BatteryReader.read(), reading.accumulatedLoad != nil, reading.loadCount != nil else {
            available = false; return
        }
        available = true
        now = reading
        let mode = settings.napEnabled
        if lastMode != mode { lastMode = mode; valid = false }
        guard let acc = reading.accumulatedLoad, let cnt = reading.loadCount else { return }
        if let s = seen, cnt != s.cnt {
            if valid, cnt > s.cnt, acc >= s.acc, cnt - s.cnt <= 180 {
                let seconds = Double(cnt - s.cnt), joules = Double(acc - s.acc) / 1000   // mW × s → J
                if mode { on.seconds += seconds; on.joules += joules } else { off.seconds += seconds; off.joules += joules }
                save()
            }
            valid = cnt > s.cnt   // the first refresh after a switch only marks where the clean minutes start
        }
        seen = (acc, cnt)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Stored(off: off, on: on)) { UserDefaults.standard.set(d, forKey: key) }
    }
}
#endif
