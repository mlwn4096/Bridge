import Foundation

struct TransferRateEstimator {
    let total: Int64
    private(set) var bytes: Int64 = 0
    private(set) var rate: Double = 0
    private var lastTime: Double
    init(total: Int64, started: Double) { self.total = total; lastTime = started }
    mutating func record(_ received: Int64, now: Double) -> Bool {
        guard total >= 0, received >= bytes, received <= total, now.isFinite, now > lastTime else { return false }
        let sample = Double(received - bytes) / (now - lastTime)
        rate = rate == 0 ? sample : 0.25 * sample + 0.75 * rate
        bytes = received; lastTime = now
        return true
    }
}
enum TransferTelemetry {
    static func remaining(size: Int64, progress: Double, speed: Double) -> String? {
        guard size > 0, progress.isFinite, (0..<1).contains(progress), speed.isFinite, speed > 0 else { return nil }
        let seconds = ceil(Double(size) * (1 - progress) / speed)
        guard seconds.isFinite, seconds <= 604800 else { return nil }
        let value = max(1, Int(seconds))
        if value < 60 { return "~\(value)s left" }
        if value < 3600 { return "~\((value + 59) / 60) min left" }
        return "~\((value + 3599) / 3600) hr left"
    }
}
