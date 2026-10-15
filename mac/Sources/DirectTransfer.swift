import Foundation
import Darwin

struct DirectConfiguration: Equatable {
    let sessionID: String
    let ssid: String
    let password: String
    init?(_ payload: [String: Any]) {
        guard let id = payload["sessionID"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id.lowercased(),
              let ssid = payload["ssid"] as? String, ssid.hasPrefix("Bridge-"), ssid.utf8.count == 15,
              ssid.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }),
              let password = payload["password"] as? String, password.utf8.count == 24,
              password.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        sessionID = id; self.ssid = ssid; self.password = password
    }
    func beacon(port: UInt16) -> Data {
        // Neither the password nor pairing credentials ever enter UDP discovery.
        try! JSONSerialization.data(withJSONObject: ["type": "bridgeDirectV1", "sessionID": sessionID, "port": Int(port)])
    }
}

/// Scoped to an explicit direct-mode session. Broadcasts are untrusted route hints.
final class DirectBeacon {
    private var timer: Timer?
    private var descriptor: Int32 = -1
    func start(configuration: DirectConfiguration, port: UInt16) throws {
        stop()
        descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)); stop(); throw error
        }
        let payload = configuration.beacon(port: port)
        broadcast(payload)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.broadcast(payload) }
    }
    private func broadcast(_ payload: Data) {
        guard descriptor >= 0 else { return }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"),
                  item.pointee.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = item.pointee.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(38474).bigEndian; destination.sin_addr.s_addr = ip | ~netmask
            withUnsafePointer(to: &destination) { target in
                target.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                    payload.withUnsafeBytes { bytes in _ = sendto(descriptor, bytes.baseAddress, bytes.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { stop() }
}

let speedProbeBytes: Int64 = 32 * 1024 * 1024

final class SpeedProbeRun: @unchecked Sendable {
    let id = UUID().uuidString
    var task: Task<Void, Never>?
    var started: Double?
    var completionSent = false
}
