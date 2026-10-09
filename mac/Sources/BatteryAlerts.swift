import Foundation

struct BatteryAlertDecision {
    let notify: Bool
    let latched: Bool
    static func evaluate(level: Int, charging: Bool, enabled: Bool, threshold: Int, latched: Bool) -> Self {
        guard (0...100).contains(level) else { return Self(notify: false, latched: latched) }
        if level > threshold + 5 { return Self(notify: false, latched: false) }
        guard enabled, !charging, level <= threshold, !latched else { return Self(notify: false, latched: latched) }
        return Self(notify: true, latched: true)
    }
}
