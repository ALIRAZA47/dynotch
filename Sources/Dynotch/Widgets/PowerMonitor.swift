import IOKit.ps
import SwiftUI

/// The Mac's own battery. Announces plugging in and running low in the closed notch.
@MainActor
final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()

    @Published private(set) var hasBattery = false
    @Published private(set) var level = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    /// Minutes until full while charging, until empty otherwise. nil while macOS is still estimating.
    @Published private(set) var minutesRemaining: Int?

    private var source: CFRunLoopSource?
    private var warnedLevels: Set<Int> = []

    private init() {}

    func start() {
        refresh(announce: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh(announce: true) }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
    }

    var symbol: String {
        if isCharging || isPluggedIn { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var tint: Color {
        if isCharging || isPluggedIn { return .green }
        return level <= 10 ? .red : level <= 20 ? .orange : .white
    }

    var statusDescription: String {
        var parts = ["\(level)%"]
        if isCharging {
            parts.append("charging")
            if let minutesRemaining { parts.append("full in \(Self.hoursAndMinutes(minutesRemaining))") }
        } else if isPluggedIn {
            parts.append("plugged in")
        } else if let minutesRemaining {
            parts.append("\(Self.hoursAndMinutes(minutesRemaining)) left")
        }
        return parts.joined(separator: ", ")
    }

    private func refresh(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let wasPluggedIn = isPluggedIn
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            hasBattery = true
            level = Int((Double(current) / Double(maximum) * 100).rounded())
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = description[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
            minutesRemaining = minutes > 0 ? minutes : nil
        }
        guard hasBattery, announce else { return }

        if isPluggedIn, !wasPluggedIn, AppSettings.shared.liveCharging {
            LiveActivityCenter.shared.post(LiveNotice(key: "power", symbol: "bolt.fill", tint: .green, text: "\(level)%"), for: 3)
        }
        if isPluggedIn {
            warnedLevels.removeAll()
        } else if AppSettings.shared.lowBatteryAlerts {
            for threshold in [20, 10] where level <= threshold && warnedLevels.insert(threshold).inserted {
                LiveActivityCenter.shared.post(LiveNotice(key: "power", symbol: "battery.25percent", tint: threshold == 10 ? .red : .orange,
                                                          text: "\(level)%", detail: "Low battery. Plug in soon."), for: 5)
                break
            }
        }
    }

    private static func hoursAndMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
