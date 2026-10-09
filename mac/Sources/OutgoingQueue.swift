import Foundation

struct QueuedFile: Codable, Identifiable {
    let id: String
    let deviceID: String
    let path: String
    let name: String
    let size: Int64
    let modified: Date
    let created: Date
    var epoch: String = ""
    var paused = false
    var attempts = 0
    var lastError = ""
    var retryAfter = Date.distantPast
    var ownedCopy = false
}

enum QueueError: LocalizedError {
    case full, invalid, changed
    var errorDescription: String? {
        switch self {
        case .full: return "The queue holds up to 100 files. Remove some before adding more."
        case .invalid: return "The transfer queue is unavailable. Check its storage permissions."
        case .changed: return "This queued file changed or moved. Remove it and choose the file again."
        }
    }
}

/// Metadata only: a queue never keeps a plaintext copy of clipboard text or credentials.
final class OutgoingQueueStore {
    private let file: URL
    private(set) var entries: [QueuedFile] = []
    init(directory: URL? = nil, resetBlocked: Bool = false) throws {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bridge/OutgoingQueue", isDirectory: true)
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath() else { throw QueueError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw QueueError.invalid }
        file = directory.appendingPathComponent("queue.json")
        let blocked = directory.appendingPathComponent("queue.blocked.json")
        let hasBlocked = FileManager.default.fileExists(atPath: blocked.path)
        guard !hasBlocked || resetBlocked else { throw QueueError.invalid }
        let input = hasBlocked ? blocked : file
        if FileManager.default.fileExists(atPath: input.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: input.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 512_000 else { throw QueueError.invalid }
            entries = try JSONDecoder().decode([QueuedFile].self, from: Data(contentsOf: input))
            guard entries.count <= 100, Set(entries.map(\.id)).count == entries.count,
                  entries.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.deviceID) != nil && $0.size >= 0 && $0.size <= TransferRules.maxBytes && TransferRules.validName($0.name) && $0.path.hasPrefix("/") }) else { throw QueueError.invalid }
        }
        if resetBlocked {
            entries.forEach(removeOwnedCopy)
            entries = []; try save()
            if hasBlocked { try FileManager.default.removeItem(at: blocked) }
        }
    }
    @discardableResult func recordFailure(_ id: String, reason: String, now: Date = Date()) throws -> QueuedFile? {
        guard var entry = entries.first(where: { $0.id == id }) else { return nil }
        entry.attempts = min(3, max(0, min(3, entry.attempts)) + 1)
        entry.paused = entry.paused || entry.attempts >= 3
        entry.lastError = String(reason.prefix(240))
        entry.retryAfter = now.addingTimeInterval(Double(entry.attempts * 15))
        try replace(entry)
        return entry
    }
    @discardableResult func pauseAfterRejection(_ id: String, reason: String) throws -> QueuedFile? {
        guard var entry = entries.first(where: { $0.id == id }) else { return nil }
        entry.paused = true; entry.lastError = String(reason.prefix(240)); try replace(entry); return entry
    }
    func quarantine() {
        let blocked = file.deletingLastPathComponent().appendingPathComponent("queue.blocked.json")
        if FileManager.default.fileExists(atPath: file.path) { _ = rename(file.path, blocked.path) }
    }
    func enqueue(_ urls: [URL], deviceID: String, ownedCopy: Bool = false, epoch: String = "") throws -> [QueuedFile] {
        guard UUID(uuidString: deviceID) != nil else { throw QueueError.invalid }
        guard !urls.isEmpty, entries.count + urls.count <= 100 else { throw QueueError.full }
        let additions = try urls.map { url -> QueuedFile in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, TransferRules.validName(url.lastPathComponent), FileManager.default.isReadableFile(atPath: url.path), let size = values.fileSize, size >= 0, Int64(size) <= TransferRules.maxBytes, let modified = values.contentModificationDate else { throw QueueError.invalid }
            return QueuedFile(id: UUID().uuidString, deviceID: deviceID, path: url.path, name: url.lastPathComponent, size: Int64(size), modified: modified, created: Date(), epoch: epoch, ownedCopy: ownedCopy)
        }
        let old = entries; entries += additions
        do { try save() } catch { entries = old; throw error }
        return additions
    }
    func snapshotImports(_ sources: [URL], cancelled: () -> Bool) throws -> [URL] {
        var copies: [URL] = []
        do {
            for source in sources {
                guard !cancelled(), source.isFileURL, TransferRules.validName(source.lastPathComponent),
                      (try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true else { throw QueueError.invalid }
                let parent = file.deletingLastPathComponent().appendingPathComponent("Bridge-Archive-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let copy = parent.appendingPathComponent(source.lastPathComponent)
                copies.append(copy)
                let input = try FileHandle(forReadingFrom: source)
                guard FileManager.default.createFile(atPath: copy.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { try? input.close(); throw QueueError.invalid }
                let output = try FileHandle(forWritingTo: copy)
                do {
                    var bytes: Int64 = 0
                    while true {
                        guard !cancelled() else { throw QueueError.invalid }
                        let data = try input.read(upToCount: 1_048_576) ?? Data()
                        if data.isEmpty { break }
                        bytes += Int64(data.count); guard bytes <= TransferRules.maxBytes else { throw QueueError.invalid }
                        try output.write(contentsOf: data)
                    }
                    try output.synchronize(); try output.close(); try input.close()
                } catch { try? output.close(); try? input.close(); throw error }
            }
            guard !cancelled() else { throw QueueError.invalid }
            return copies
        } catch { for copy in copies { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }; throw error }
    }
    func adoptArchive(_ source: URL) throws -> URL {
        let parent = source.deletingLastPathComponent()
        guard parent.lastPathComponent.hasPrefix("Bridge-Archive-"),
              parent.deletingLastPathComponent().resolvingSymlinksInPath().path == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
              (try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true else { throw QueueError.invalid }
        let destination = file.deletingLastPathComponent().appendingPathComponent("Bridge-Archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: source.deletingLastPathComponent(), to: destination)
        return destination.appendingPathComponent(source.lastPathComponent)
    }
    func removeOwnedCopy(_ entry: QueuedFile) {
        let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
        guard entry.ownedCopy, parent.lastPathComponent.hasPrefix("Bridge-Archive-"),
              parent.deletingLastPathComponent().standardizedFileURL == file.deletingLastPathComponent().standardizedFileURL,
              parent.standardizedFileURL == parent.resolvingSymlinksInPath() else { return }
        try? FileManager.default.removeItem(at: parent)
    }
    func validateSource(_ entry: QueuedFile) throws -> URL {
        let url = URL(fileURLWithPath: entry.path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize.map(Int64.init) == entry.size, values.contentModificationDate == entry.modified else { throw QueueError.changed }
        return url
    }
    func replace(_ entry: QueuedFile) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let previous = entries[index]; entries[index] = entry
        do { try save() } catch { entries[index] = previous; throw error }
    }
    @discardableResult func remove(_ id: String) throws -> QueuedFile? {
        let removed = entries.first(where: { $0.id == id }), old = entries
        entries.removeAll { $0.id == id }
        do { try save() } catch { entries = old; throw error }
        return removed
    }
    func clear(deviceID: String) throws {
        let old = entries; entries.removeAll { $0.deviceID == deviceID }
        do { try save() } catch { entries = old; throw error }
    }
    private func save() throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(entries), attributes: [.posixPermissions: 0o600]), rename(temporary.path, file.path) == 0 else { throw QueueError.invalid }
    }
}
