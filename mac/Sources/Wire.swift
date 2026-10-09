import Foundation
import CryptoKit

enum WireError: Error { case invalidFrame, tooLarge, invalidTransfer }

struct WireMessage {
    static let version = 1
    static let maxFrame = 131_072
    static let maxClipboard = 32_768
    static let chunkSize = 32_768
    let type: String
    let id: String
    let payload: [String: Any]

    init(_ type: String, id: String = UUID().uuidString, _ payload: [String: Any] = [:]) {
        self.type = type; self.id = id; self.payload = payload
    }
    init(data: Data) throws {
        guard data.count <= Self.maxFrame,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == Self.version,
              let type = object["type"] as? String, type.count <= 64,
              let id = object["id"] as? String, id.count <= 128,
              let payload = object["payload"] as? [String: Any] else { throw WireError.invalidFrame }
        self.type = type; self.id = id; self.payload = payload
    }
    func data() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["v": Self.version, "type": type, "id": id, "payload": payload], options: [.sortedKeys])
        guard data.count <= Self.maxFrame else { throw WireError.tooLarge }
        return data + Data([10])
    }
    func string(_ key: String) -> String { payload[key] as? String ?? "" }
    func integer(_ key: String) -> Int64 { (payload[key] as? NSNumber)?.int64Value ?? 0 }
}

struct FrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [WireMessage] {
        buffer.append(data)
        var messages: [WireMessage] = []
        while let newline = buffer.firstIndex(of: 10) {
            let frame = Data(buffer[..<newline])
            guard !frame.isEmpty else { throw WireError.invalidFrame }
            messages.append(try WireMessage(data: frame))
            buffer.removeSubrange(...newline)
        }
        guard buffer.count <= WireMessage.maxFrame else { throw WireError.tooLarge }
        return messages
    }
}

enum TransferRules {
    static func availableDestination(in folder: URL, name: String, reserved: Set<URL> = []) throws -> URL {
        guard validName(name) else { throw WireError.invalidTransfer }
        let original = folder.appendingPathComponent(name)
        let ext = original.pathExtension
        let stem = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
        for number in 0...9999 {
            let candidateName = number == 0 ? name : stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
            guard validName(candidateName) else { continue }
            let candidate = folder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path), !reserved.contains(candidate) { return candidate }
        }
        throw WireError.invalidTransfer
    }
    static let maxBytes: Int64 = 17_179_869_184
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func hashFile(_ url: URL, shouldCancel: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            if shouldCancel() { throw CancellationError() }
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) } }
}

func randomSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("Secure random unavailable") }
    return Data(bytes).base64EncodedString()
}

import Security

func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

struct BinaryFileChunk {
    static let maxData = 262_144
    static let metadataBytes = 44 // canonical UUID ASCII (36) + big-endian sequence (8)
    let transferID: String
    let sequence: Int64
    let data: Data
    func encoded() throws -> Data {
        guard transferID.utf8.count == 36, UUID(uuidString: transferID)?.uuidString == transferID.uppercased(), sequence >= 0,
              !data.isEmpty, data.count <= Self.maxData else { throw WireError.invalidTransfer }
        var result = Data([0])
        let length = UInt32(Self.metadataBytes + data.count)
        for shift in stride(from: 24, through: 0, by: -8) { result.append(UInt8((length >> shift) & 255)) }
        result.append(Data(transferID.utf8))
        for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((UInt64(sequence) >> shift) & 255)) }
        result.append(data)
        return result
    }
}
enum TransportFrame { case control(WireMessage), file(BinaryFileChunk) }
struct TransportFrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [TransportFrame] {
        buffer.append(data)
        var frames: [TransportFrame] = []
        while !buffer.isEmpty {
            if buffer.first == 0 {
                guard buffer.count >= 5 else { break }
                let length = buffer.dropFirst().prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > BinaryFileChunk.metadataBytes, length <= BinaryFileChunk.metadataBytes + BinaryFileChunk.maxData else { throw WireError.tooLarge }
                guard buffer.count >= 5 + Int(length) else { break }
                let body = Data(buffer.dropFirst(5).prefix(Int(length)))
                guard let id = String(data: body.prefix(36), encoding: .ascii), UUID(uuidString: id)?.uuidString == id.uppercased() else { throw WireError.invalidTransfer }
                let sequence = body.dropFirst(36).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard sequence <= UInt64(Int64.max) else { throw WireError.invalidTransfer }
                frames.append(.file(BinaryFileChunk(transferID: id, sequence: Int64(sequence), data: Data(body.dropFirst(44)))))
                buffer.removeFirst(5 + Int(length))
            } else {
                guard let newline = buffer.firstIndex(of: 10) else {
                    guard buffer.count <= WireMessage.maxFrame else { throw WireError.tooLarge }; break
                }
                frames.append(.control(try WireMessage(data: Data(buffer[..<newline]))))
                buffer.removeSubrange(...newline)
            }
        }
        guard buffer.count <= BinaryFileChunk.maxData + 49 else { throw WireError.tooLarge }
        return frames
    }
}
