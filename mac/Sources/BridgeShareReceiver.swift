import AppKit
import Foundation

@MainActor final class BridgeShareReceiver {
    private weak var model: BridgeModel?
    private var observer: NSObjectProtocol?
    private var reviewing = false
    private var pendingURLs: [URL] = []
    init(model: BridgeModel) {
        self.model = model
        BridgeRuntime.model = model
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("BridgeOpenURLs"), object: nil, queue: .main) { [weak self] note in
            guard let urls = note.userInfo?["urls"] as? [URL] else { return }
            Task { @MainActor in self?.receive(urls) }
        }
        BridgeRuntime.receiverReady = true
        let pending = BridgeRuntime.pendingURLs
        BridgeRuntime.pendingURLs = []
        if !pending.isEmpty { Task { @MainActor [weak self] in self?.receive(pending) } }
    }
    private func receive(_ urls: [URL]) {
        if reviewing {
            pendingURLs.append(contentsOf: urls.prefix(max(0, 16 - pendingURLs.count)))
            return
        }
        reviewing = true
        defer {
            reviewing = false
            if !pendingURLs.isEmpty {
                let pending = pendingURLs; pendingURLs = []
                Task { @MainActor [weak self] in self?.receive(pending) }
            }
        }
        for url in urls.prefix(8) {
            guard url.scheme == "bridge-app", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.fragment == nil else { continue }
            let query = parts.queryItems ?? []
            if parts.host == "share", query.count == 1, query[0].name == "batch", let id = query[0].value, UUID(uuidString: id) != nil {
                receiveShare(id)
            } else if parts.host == "command", query.count == 1, query[0].name == "request", let id = query[0].value, UUID(uuidString: id) != nil {
                receiveCommand(id)
            } else if parts.host == "settings", query.isEmpty { BridgeApplicationDelegate.showSettings() }
        }
    }
    private func receiveShare(_ id: String) {
        guard let model else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent("Library/Containers/dev.bridge.mac.share/Data/Library/Application Support/BridgeShares"),
                     home.appendingPathComponent("Library/Application Support/BridgeShares")]
        guard let directory = roots.map({ $0.appendingPathComponent(id, isDirectory: true) }).first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) else {
            model.notice = "Shared selection could not be found. Open Bridge and share again."; return
        }
        do {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            try requireOwnedRegularFile(manifestURL, maximum: 65536)
            guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw ShareImportError.invalid }
            let manifest = try JSONDecoder().decode(ShareManifest.self, from: Data(contentsOf: manifestURL))
            try manifest.validate()
            let files = manifest.files.map { directory.appendingPathComponent($0) }
            for file in files { try requireOwnedRegularFile(file, maximum: TransferRules.maxBytes) }
            guard model.paired != nil, model.connected || manifest.text.isEmpty else { throw ShareImportError.disconnected }
            let approvedPeerID = model.paired?.id
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = "Send to \(model.paired?.name ?? "your phone")?"
            let descriptions = manifest.files + (manifest.text.isEmpty ? [] : [String(manifest.text.prefix(300))])
            alert.informativeText = descriptions.joined(separator: "\n")
            alert.addButton(withTitle: "Send"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                try? FileManager.default.removeItem(at: directory); return
            }
            guard model.paired?.id == approvedPeerID, model.paired != nil, model.connected || manifest.text.isEmpty else { throw ShareImportError.disconnected }
            // Consume the selection before asynchronous sends begin. A repeated
            // launch URL must not enqueue the same files or text a second time.
            try FileManager.default.moveItem(at: manifestURL, to: directory.appendingPathComponent("consumed.json"))
            if !files.isEmpty, !model.queueImportedFiles(files) { throw NSError(domain: "Bridge", code: 1, userInfo: [NSLocalizedDescriptionKey: model.notice]) }
            if !manifest.text.isEmpty {
                if LinkHandoff(manifest.text) != nil { _ = model.sendWebLink(manifest.text) }
                else { _ = model.sendSelectedText(manifest.text) }
            }
            // Files are copied into private queue storage before the extension
            // expires its batch; cancelling the review removes immediately.
        } catch { model.notice = error.localizedDescription }
    }
    private func requireOwnedRegularFile(_ url: URL, maximum: Int64) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = attrs[.size] as? NSNumber, size.int64Value >= 0, size.int64Value <= maximum,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw ShareImportError.invalid }
    }
    private func receiveCommand(_ id: String) {
        guard let model else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bridge/Commands", isDirectory: true)
        let request = directory.appendingPathComponent(id + ".json")
        let reply = directory.appendingPathComponent(id + ".result.json")
        // Validate before either request IO or reply IO; an invalid directory
        // must never be used by the error-reporting path either.
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            model.notice = "Bridge command directory is unavailable or unsafe."; return
        }
        var result: [String: Any]
        do {
            try requireOwnedRegularFile(request, maximum: 65536)
            guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path,
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: request)) as? [String: Any],
                  let created = value["created"] as? Double, created.isFinite,
                  abs(Date().timeIntervalSince1970 - created) < 30,
                  let command = value["command"] as? String else { throw ShareImportError.invalid }
            try FileManager.default.removeItem(at: request) // consume once
            switch command {
            case "devices":
                result = ["ok": true, "connected": model.connected, "name": model.paired?.name ?? "", "status": model.status, "battery": model.battery as Any? ?? NSNull()]
            case "clipboard.get":
                result = ["ok": true, "text": model.incomingClipboard]
            case "clipboard.set":
                guard let text = value["text"] as? String else { throw ShareImportError.invalid }
                let accepted = model.sendSelectedText(text)
                result = ["ok": accepted, "message": model.notice]
            case "send":
                guard let paths = value["files"] as? [String], !paths.isEmpty, paths.count <= 100 else { throw ShareImportError.invalid }
                let accepted = model.sendFiles(paths.map { URL(fileURLWithPath: $0) })
                result = ["ok": accepted, "message": model.notice, "state": "queued"]
            case "link":
                guard let link = value["text"] as? String else { throw ShareImportError.invalid }
                let accepted = model.sendWebLink(link)
                result = ["ok": accepted, "message": model.notice]
            case "ring":
                guard model.connected else { throw ShareImportError.disconnected }
                if !model.ringing { model.ringPhone() }
                result = ["ok": true, "message": "Ring requested"]
            case "pause", "resume", "cancel":
                guard let suppliedID = value["transferID"] as? String, UUID(uuidString: suppliedID) != nil,
                      let id = model.queuedFiles.first(where: { $0.id.caseInsensitiveCompare(suppliedID) == .orderedSame })?.id else { throw ShareImportError.invalid }
                if command == "pause" { model.pauseTransfer(id) }
                else if command == "resume" { model.resumeTransfer(id) }
                else { model.cancelTransfer(id) }
                let remaining = model.queuedFiles.first { $0.id == id }
                let accepted = command == "cancel" ? remaining == nil : remaining?.paused == (command == "pause")
                result = ["ok": accepted, "message": model.notice]
            case "transfers":
                result = ["ok": true, "transfers": model.transfers.map { ["id": $0.id, "name": $0.name, "state": $0.state, "progress": $0.progress] as [String: Any] }]
            default: throw ShareImportError.invalid
            }
        } catch { result = ["ok": false, "message": error.localizedDescription] }
        do {
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: reply, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reply.path)
        } catch { model.notice = "Bridge command could not return its result." }
    }
}
@MainActor enum BridgeRuntime {
    static weak var model: BridgeModel?
    static var receiverReady = false
    static var pendingURLs: [URL] = []
    static func open(_ urls: [URL]) {
        guard receiverReady else {
            pendingURLs.append(contentsOf: urls.prefix(max(0, 16 - pendingURLs.count)))
            return
        }
        NotificationCenter.default.post(name: Notification.Name("BridgeOpenURLs"), object: nil, userInfo: ["urls": urls])
    }
}
