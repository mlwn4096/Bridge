import Foundation

struct LinkHandoff {
    let id = UUID()
    let url: URL
    let title: String
    let host: String
    let expiresAt: Date
    init?(_ raw: String, title: String = "", now: Date = Date()) {
        guard raw.utf8.count <= 8192,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url else { return nil }
        self.url = url; self.host = host
        let clean = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = clean.isEmpty || ClipboardProtection.reason(clean) != nil ? host : clean
        expiresAt = now.addingTimeInterval(600)
    }
    func expired(at date: Date = Date()) -> Bool { date >= expiresAt }
}
