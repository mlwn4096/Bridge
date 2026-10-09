import Foundation

private struct TransferReceipt: Codable {
    let peer: String; let id: String; let name: String; let size: Int64; let hash: String; let date: Date
}
/// Bounded completion ledger avoids duplicate files when the final receipt was lost.
final class TransferReceiptStore {
    private let defaults: UserDefaults
    private let key = "completedFileReceiptsV1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func load() -> [TransferReceipt] {
        guard let data = defaults.data(forKey: key), data.count <= 512_000,
              let records = try? JSONDecoder().decode([TransferReceipt].self, from: data) else { return [] }
        return Array(records.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.suffix(500))
    }
    func matches(peer: String, id: String, name: String, size: Int64, hash: String) -> Bool {
        load().contains { $0.peer == peer && $0.id == id && $0.name == name && $0.size == size && $0.hash == hash }
    }
    func record(peer: String, id: String, name: String, size: Int64, hash: String) {
        var records = load().filter { !($0.peer == peer && $0.id == id) }
        records.append(TransferReceipt(peer: peer, id: id, name: name, size: size, hash: hash, date: Date()))
        if let data = try? JSONEncoder().encode(Array(records.suffix(500))) { defaults.set(data, forKey: key) }
    }
    func revoke(peer: String) {
        if let data = try? JSONEncoder().encode(load().filter { $0.peer != peer }) { defaults.set(data, forKey: key) }
    }
}
