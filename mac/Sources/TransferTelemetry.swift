import Foundation
import OSLog

enum TransferDiagnostics {
    private static let logger = Logger(subsystem: "dev.bridge.mac", category: "transfer")
    static func complete(size: Int64, binary: Bool, route: String, timings: TransferTimings?) {
        let value = "bytes=\(size) encoding=\(binary ? "binary-v1" : "json") route=\(route) \(timings?.summary ?? "Already received")"
        logger.info("\(value, privacy: .public)")
    }
}

struct TransferTimings {
    private(set) var started: Double?
    private var phase = ""
    private var entered = 0.0
    private(set) var seconds: [String: Double] = [:]
    private(set) var total: Double?
    mutating func transition(_ state: String, now: Double) {
        guard now.isFinite else { return }
        let next: String
        switch state {
        case "Preparing": next = "preparation"
        case "Waiting for phone", "Waiting for computer", "Accept to receive": next = "waiting"
        case "Sending", "Receiving": next = "transfer"
        case "Finishing", "Verifying": next = "finish"
        case "Complete": next = "complete"
        default: return
        }
        if next == "preparation" && phase != next { self = TransferTimings() }
        if started == nil && ["preparation", "transfer"].contains(next) { started = now; entered = now; phase = next; return }
        guard let started, total == nil, now >= entered, next != phase else { return }
        seconds[phase, default: 0] += now - entered; entered = now; phase = next
        if next == "complete" { total = now - started }
    }
    var summary: String? {
        guard let total else { return nil }
        return String(format: "Total %.1fs · preparation %.1fs · waiting %.1fs · transfer %.1fs · finish %.1fs",
                      total, seconds["preparation", default: 0], seconds["waiting", default: 0], seconds["transfer", default: 0], seconds["finish", default: 0])
    }
}

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
