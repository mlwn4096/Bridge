import Foundation
import Network
import Security

// Model-facing mutable state stays on the main queue. Frame decoding and
// Network.framework callbacks use a private serial queue; deliveries return to main.
final class PeerConnection: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    var isUSB = false
    var authorized = false
    var deviceID = ""
    var supportsBinary = false
    var receiverProgress = false
    var supportsTransferFailure = false
    var supportsNotificationReplies = false
    var supportsDirectTransfer = false
    var supportsSpeedProbe = false
    var directSessionID = ""
    var onFileChunk: ((PeerConnection, BinaryFileChunk, @escaping () -> Void) -> Void)?
    var onMessage: ((PeerConnection, WireMessage) -> Void)?
    var onClose: ((PeerConnection) -> Void)?
    var lastSeenUptime = ProcessInfo.processInfo.systemUptime
    private let transportQueue = DispatchQueue(label: "Bridge.transport", qos: .userInitiated)
    private var decoder = TransportFrameDecoder()
    private var closed = false
    private var handshakeTimer: DispatchWorkItem?

    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready: self.receive()
                case .failed, .cancelled: self.close()
                default: break
                }
            }
        }
        connection.start(queue: transportQueue)
        let deadline = DispatchWorkItem { [weak self] in if self?.authorized != true { self?.close() } }
        handshakeTimer = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: deadline)
    }
    func send(_ message: WireMessage, completion: ((Bool) -> Void)? = nil) {
        guard !closed, let data = try? message.data() else { completion?(false); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async { if error != nil { self?.close() }; completion?(error == nil) }
        })
    }
    func close() {
        guard !closed else { return }; closed = true
        handshakeTimer?.cancel(); connection.cancel(); onClose?(self)
    }
    // Returns after submission, not drain. Caller keeps at most four receipts,
    // preserving submit order while allowing TCP to consume a continuous window.
    func submitBinaryBatch(_ chunks: [BinaryFileChunk], isActive: @escaping @MainActor () -> Bool) async throws -> AsyncThrowingStream<Void, Error> {
        let frames = try chunks.map { try $0.encoded() }
        var finish: AsyncThrowingStream<Void, Error>.Continuation!
        let receipt = AsyncThrowingStream<Void, Error> { finish = $0 }
        let completion = finish!
        try await withCheckedThrowingContinuation { (submitted: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                guard !self.closed, isActive() else {
                    completion.finish(throwing: CancellationError())
                    submitted.resume(throwing: CancellationError()); return
                }
                // These counters are confined to the serial network callback queue.
                var remaining = frames.count, failed = false
                guard remaining > 0 else { completion.finish(); submitted.resume(); return }
                self.connection.batch {
                    for frame in frames {
                        self.connection.send(content: frame, completion: .contentProcessed { error in
                            failed = failed || error != nil; remaining -= 1
                            if remaining == 0 {
                                if failed {
                                    completion.finish(throwing: WireError.invalidTransfer)
                                    DispatchQueue.main.async { self.close() }
                                } else { completion.finish() }
                            }
                        })
                    }
                }
                submitted.resume()
            }
        }
        return receipt
    }
    private func deliver(_ frames: [TransportFrame], index: Int, done: @escaping () -> Void) {
        var cursor = index
        while !closed && cursor < frames.count {
            lastSeenUptime = ProcessInfo.processInfo.systemUptime
            switch frames[cursor] {
            case .control(let message): onMessage?(self, message); cursor += 1
            case .file(let chunk):
                guard authorized, supportsBinary, let onFileChunk else { close(); return }
                let next = cursor + 1
                onFileChunk(self, chunk) { [weak self] in self?.deliver(frames, index: next, done: done) }
                return
            }
        }
        if !closed { done() }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            // Decoder is confined to transportQueue; only immutable parsed frames
            // cross to main. No next receive is scheduled until delivery finishes.
            let decoded = Result { try data.map { try self.decoder.append($0) } ?? [] }
            DispatchQueue.main.async {
                guard !self.closed else { return }
                switch decoded {
                case .success(let frames):
                    self.deliver(frames, index: 0) {
                        if complete || error != nil { self.close() } else { self.receive() }
                    }
                case .failure: self.close()
                }
            }
        }
    }

}

final class LocalServer {
    private var listener: NWListener?
    var onConnection: ((PeerConnection) -> Void)?
    var onState: ((String, UInt16?) -> Void)?
    func start(identity: DeviceIdentity) throws {
        let tls = NWProtocolTLS.Options()
        guard let localIdentity = sec_identity_create(identity.identity) else { throw IdentityError.importFailed(errSecParam) }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: "Bridge-" + String(identity.fingerprint.prefix(8)), type: "_bridge._tcp")
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.onState?("Ready to pair", listener?.port?.rawValue)
            case .failed(let error): self?.onState?("Local network unavailable: \(error.localizedDescription)", nil)
            case .waiting(let error): self?.onState?("Waiting for network: \(error.localizedDescription)", nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.onConnection?(PeerConnection(connection)) }
        self.listener = listener; listener.start(queue: .main)
    }
    func stop() { listener?.cancel(); listener = nil }
}

func localIPv4() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }
    var current: UnsafeMutablePointer<ifaddrs>? = first
    var candidates: [(String, String)] = []
    while let interface = current {
        defer { current = interface.pointee.ifa_next }
        guard let address = interface.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET),
              interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let name = String(cString: interface.pointee.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        candidates.append((name, String(cString: host)))
    }
    return candidates.sorted { ($0.0 == "en0" ? 0 : 1) < ($1.0 == "en0" ? 0 : 1) }.first?.1
}
