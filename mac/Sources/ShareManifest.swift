import Foundation

struct ShareManifest: Codable {
    let version: Int
    let created: Double
    let files: [String]
    let text: String
    func validate(now: Date = Date()) throws {
        guard version == 1, created.isFinite, created <= now.timeIntervalSince1970 + 60,
              now.timeIntervalSince1970 - created <= 86400,
              files.count <= 3, Set(files.map { $0.lowercased() }).count == files.count,
              files.allSatisfy({ TransferRules.validName($0) && !["manifest.json", "consumed.json"].contains($0.lowercased()) && !$0.hasPrefix(".") }),
              text.utf8.count <= WireMessage.maxClipboard, !files.isEmpty || !text.isEmpty else {
            throw ShareImportError.invalid
        }
    }
}
enum ShareImportError: LocalizedError {
    case invalid, disconnected
    var errorDescription: String? {
        switch self {
        case .invalid: return "This share has expired or contains unsupported items. Share it again from the original app."
        case .disconnected: return "Connect your phone in Bridge, then share again."
        }
    }
}
