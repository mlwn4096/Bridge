import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum IdentityError: LocalizedError {
    case generation(String), importFailed(OSStatus)
    var errorDescription: String? {
        switch self {
        case .generation(let detail): return "Could not create a device identity: \(detail)"
        case .importFailed(let status): return "Could not load device identity (\(status))."
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
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: formatPassword, kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard status == errSecSuccess, let records = items as? [[String: Any]],
              let value = records.first?[kSecImportItemIdentity as String] else { throw IdentityError.importFailed(status) }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw IdentityError.importFailed(errSecItemNotFound) }
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return DeviceIdentity(identity: identity, fingerprint: fingerprint, directory: directory)
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
