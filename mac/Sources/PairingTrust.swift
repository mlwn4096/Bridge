import Foundation
import Security
import CryptoKit

/// The Mac verifies a random 256-bit phone credential; it never needs to send
/// that credential. Persist only a salted, device-bound SHA-256 verifier.
/// Possession of this digest cannot authenticate as the phone (the protocol
/// requires the original random credential, sent inside pinned TLS).
struct PairingTrustRecord: Codable {
    let version: Int
    let deviceID: String
    let salt: Data
    let digest: Data
    init(deviceID: String, credential: String) throws {
        guard UUID(uuidString: deviceID) != nil,
              let bytes = Data(base64Encoded: credential), bytes.count == 32 else { throw PairingTrustError.invalid }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { buffer in SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!) }
        guard status == errSecSuccess else { throw IdentityError.importFailed(status) }
        self.version = 1; self.deviceID = deviceID; self.salt = salt
        self.digest = Self.hash(deviceID: deviceID, salt: salt, credential: bytes)
    }
    func validate(deviceID expected: String) throws {
        guard version == 1, UUID(uuidString: deviceID) != nil, deviceID == expected,
              salt.count == 32, digest.count == 32 else { throw PairingTrustError.invalid }
    }
    func matches(deviceID expected: String, credential: String) -> Bool {
        guard (try? validate(deviceID: expected)) != nil,
              let bytes = Data(base64Encoded: credential), bytes.count == 32 else { return false }
        let supplied = Self.hash(deviceID: expected, salt: salt, credential: bytes)
        return constantTimeEqual(digest.base64EncodedString(), supplied.base64EncodedString())
    }
    private static func hash(deviceID: String, salt: Data, credential: Data) -> Data {
        var input = Data("Bridge peer verifier v1\0".utf8)
        input.append(Data(deviceID.utf8)); input.append(0); input.append(salt); input.append(credential)
        return Data(SHA256.hash(data: input))
    }
}

enum PairingTrustError: LocalizedError {
    case invalid, unsafeLocation
    var errorDescription: String? {
        switch self {
        case .invalid: return "Pairing trust is invalid. Pair this phone again."
        case .unsafeLocation: return "Pairing trust storage is unavailable or has unsafe permissions."
        }
    }
}

final class PairingTrustStore {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bridge/PairingTrust", isDirectory: true)
    }
    func read(_ deviceID: String) throws -> PairingTrustRecord? {
        let file = try fileURL(deviceID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try validateDirectory()
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let size = attrs[.size] as? NSNumber, size.intValue <= 4096,
              file.standardizedFileURL.path == file.resolvingSymlinksInPath().path else { throw PairingTrustError.unsafeLocation }
        let record = try JSONDecoder().decode(PairingTrustRecord.self, from: Data(contentsOf: file))
        try record.validate(deviceID: deviceID)
        return record
    }
    func write(_ deviceID: String, credential: String) throws {
        let file = try fileURL(deviceID)
        let record = try PairingTrustRecord(deviceID: deviceID, credential: credential)
        // Refuse symlink ancestors before creating anything below them.
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw PairingTrustError.unsafeLocation }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateDirectory()
        if FileManager.default.fileExists(atPath: file.path) { _ = try read(deviceID) }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(record)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw PairingTrustError.unsafeLocation }
        // Atomic same-directory replacement preserves the owner-only mode.
        guard rename(temporary.path, file.path) == 0 else { throw PairingTrustError.unsafeLocation }
    }
    func delete(_ deviceID: String) throws {
        let file = try fileURL(deviceID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try validateDirectory()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func fileURL(_ deviceID: String) throws -> URL {
        guard UUID(uuidString: deviceID) != nil else { throw PairingTrustError.invalid }
        return directory.appendingPathComponent(deviceID + ".json")
    }
    private func validateDirectory() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw PairingTrustError.unsafeLocation }
    }
}
