import Foundation

struct ClipboardHistoryEntry: Identifiable {
    let id: UUID
    let text: String
    let sourceID: String
    let sourceName: String
    let date: Date
    var pinned = false
}
struct ClipboardHistoryStore {
    private(set) var entries: [ClipboardHistoryEntry] = []
    mutating func record(_ text: String, sourceID: String, sourceName: String, now: Date = Date()) {
        prune(now: now)
        guard !text.isEmpty, text.utf8.count <= 32768, ClipboardProtection.reason(text) == nil else { return }
        let pinned = entries.first { $0.text == text && $0.sourceID == sourceID }?.pinned ?? false
        entries.removeAll { $0.text == text && $0.sourceID == sourceID }
        var entry = ClipboardHistoryEntry(id: UUID(), text: text, sourceID: sourceID, sourceName: sourceName, date: now)
        entry.pinned = pinned
        entries.insert(entry, at: 0)
        // Hard cap applies even to pins, keeping memory bounded.
        entries = Array(entries.prefix(100))
    }
    mutating func prune(now: Date = Date()) { entries.removeAll { !$0.pinned && now.timeIntervalSince($0.date) >= 86400 } }
    mutating func togglePin(_ id: UUID) { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].pinned.toggle() } }
    mutating func delete(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func clear() { entries.removeAll() }
}
