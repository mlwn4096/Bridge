import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum IdentityError: LocalizedError {
    case generation(String), importFailed(OSStatus), legacyImport(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .generation(let detail): return "Could not create a device identity: \(detail)"
        case .importFailed(let status): return "Could not load device identity (\(status))."
        case .legacyImport(let step, let status): return "Could not load legacy device identity during \(step) (\(status))."
        }
    }
}

enum Secrets {
    static let service = "dev.bridge.mac.peer"
    // Legacy migration only. Never prompt during automatic reconnect.
    static func read(_ account: String, allowPrompt: Bool = false) -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ account: String) {
        let context = LAContext(); context.interactionNotAllowed = true
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context] as CFDictionary)
    }
}

struct DeviceIdentity {
    // PKCS#12 requires a nonempty format password on Apple platforms. File permissions
    // protect this local TLS key; peer authentication uses a separate salted verifier.
    private static let formatPassword = "BridgeDeviceIdentity"
    let identity: SecIdentity
    let fingerprint: String
    let directory: URL
    private let legacyStore: LegacyIdentityKeychain?
    func unlockLegacyStorage() throws { try legacyStore?.unlock() }
    static func load(in location: URL? = nil) throws -> DeviceIdentity {
        let directory = location ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bundle = directory.appendingPathComponent("tls-identity-v1.p12")
        if !FileManager.default.fileExists(atPath: bundle.path) {
            let key = directory.appendingPathComponent("identity-key.pem")
            let certificate = directory.appendingPathComponent("identity-cert.pem")
            let temporary = directory.appendingPathComponent("identity-new.p12")
            defer { try? FileManager.default.removeItem(at: key); try? FileManager.default.removeItem(at: certificate); try? FileManager.default.removeItem(at: temporary) }
            try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "3650",
                "-subj", "/CN=Bridge Local Device", "-keyout", key.path, "-out", certificate.path])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            try runOpenSSL(["pkcs12", "-export", "-inkey", key.path, "-in", certificate.path,
                "-out", temporary.path, "-passout", "pass:" + formatPassword, "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES"])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: bundle)
        }
        let data = try Data(contentsOf: bundle)
        let identity: SecIdentity
        let legacyStore: LegacyIdentityKeychain?
        if #available(macOS 15.0, *) {
            identity = try importIdentity(data); legacyStore = nil
        } else {
            (identity, legacyStore) = try importLegacyIdentity(data)
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw IdentityError.importFailed(errSecItemNotFound) }
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return DeviceIdentity(identity: identity, fingerprint: fingerprint, directory: directory, legacyStore: legacyStore)
    }
    @available(macOS 15.0, *)
    private static func importIdentity(_ data: Data) throws -> SecIdentity {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: formatPassword, kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard status == errSecSuccess, let records = items as? [[String: Any]],
              let value = records.first?[kSecImportItemIdentity as String] else { throw IdentityError.importFailed(status) }
        return value as! SecIdentity
    }
    /// macOS 13–14 needs an explicit private keychain to assemble a TLS identity.
    /// Retain it for the identity's lifetime; never import into the login keychain.
    static func importLegacyIdentity(_ data: Data) throws -> (SecIdentity, LegacyIdentityKeychain) {
        let store = try LegacyIdentityKeychain()
        var items: CFArray?
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Bridge local TLS" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else { throw IdentityError.legacyImport("access creation", accessStatus) }
        let options: [String: Any] = [kSecImportExportPassphrase as String: formatPassword,
                                     kSecImportExportKeychain as String: store.keychain,
                                     kSecImportExportAccess as String: access]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let records = items as? [[String: Any]],
              let value = records.first?[kSecImportItemIdentity as String] else {
            throw IdentityError.legacyImport("PKCS12 import", status)
        }
        return (value as! SecIdentity, store)
    }
    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "OpenSSL failed"
            throw IdentityError.generation(detail)
        }
    }
}

/// Ephemeral, encrypted storage for the pre-macOS-15 import API. The random
/// password is never persisted; the existing protected PKCS#12 stays authoritative.
final class LegacyIdentityKeychain {
    let keychain: SecKeychain
    let directory: URL
    private let password: Data
    init() throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeTLS-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let password = Data(UUID().uuidString.utf8)
        var reference: SecKeychain?
        let status = password.withUnsafeBytes { bytes in
            SecKeychainCreate(location.appendingPathComponent("identity.keychain").path,
                              UInt32(bytes.count), bytes.baseAddress, false, nil, &reference)
        }
        guard status == errSecSuccess, let reference else {
            try? FileManager.default.removeItem(at: location)
            throw IdentityError.legacyImport("keychain creation", status)
        }
        self.keychain = reference; self.directory = location; self.password = password
        let unlockStatus = password.withUnsafeBytes { bytes in
            SecKeychainUnlock(reference, UInt32(bytes.count), bytes.baseAddress, true)
        }
        guard unlockStatus == errSecSuccess else {
            SecKeychainDelete(reference)
            try? FileManager.default.removeItem(at: location)
            throw IdentityError.legacyImport("keychain unlock", unlockStatus)
        }
    }
    func unlock() throws {
        let status = password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }
        guard status == errSecSuccess else { throw IdentityError.legacyImport("keychain unlock", status) }
    }
    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
    }
}
