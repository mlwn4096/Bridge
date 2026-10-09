import AppKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let message = NSTextField(wrappingLabelWithString: "Send files, a link, or selected text to your paired phone.")
    private let sendButton = NSButton(title: "Continue in Bridge", target: nil, action: nil)
    private var preparing = false
    private var preparationTask: Task<Void, Never>?
    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 210))
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Bridge")!)
        icon.contentTintColor = .controlAccentColor
        let heading = NSTextField(labelWithString: "Send with Bridge")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        message.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelShare))
        sendButton.target = self; sendButton.action = #selector(prepareShare)
        sendButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, sendButton]); buttons.orientation = .horizontal; buttons.spacing = 12
        let stack = NSStackView(views: [icon, heading, message, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            icon.heightAnchor.constraint(equalToConstant: 28), icon.widthAnchor.constraint(equalToConstant: 28)
        ])
        view = content
    }
    @objc private func cancelShare() { preparationTask?.cancel(); extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    @objc private func prepareShare() {
        guard !preparing else { return }; preparing = true; sendButton.isEnabled = false
        message.stringValue = "Preparing your selection…"
        preparationTask = Task { @MainActor in
            var batch: URL?
            do {
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("BridgeShares", isDirectory: true)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                // Old cancelled shares contain user data; remove them after one day.
                for folder in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                    if let date = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       Date().timeIntervalSince(date) > 86400 { try? FileManager.default.removeItem(at: folder) }
                }
                let id = UUID().uuidString
                let directory = base.appendingPathComponent(id, isDirectory: true); batch = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                var files: [String] = []; var texts: [String] = []
                let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                for item in items {
                    try Task.checkCancellation()
                    let attachments = item.attachments ?? []
                    if attachments.isEmpty, let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
                    for provider in attachments {
                        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            let object = try await load(provider, type: UTType.fileURL.identifier)
                            guard let url = Self.providerURL(object), url.isFileURL else { throw ShareError.invalidSelection }
                            guard files.count < 3 else { throw ShareError.tooManyFiles }
                            let existing = files
                            let name = try await Task.detached(priority: .userInitiated) { try Self.copy(url, to: directory, existing: existing) }.value
                            try Task.checkCancellation(); files.append(name)
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                            let object = try await load(provider, type: UTType.url.identifier)
                            guard let url = Self.providerURL(object), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ShareError.invalidSelection }
                            texts.append(url.absoluteString)
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                            let object = try await load(provider, type: UTType.plainText.identifier)
                            if let text = object as? String { texts.append(text) }
                            else if let data = object as? Data, let text = String(data: data, encoding: .utf8) { texts.append(text) }
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                            guard files.count < 3 else { throw ShareError.tooManyFiles }
                            let type = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? UTType.image.identifier : UTType.movie.identifier
                            let name = try await copyRepresentation(provider, type: type, to: directory, existing: files); files.append(name)
                        }
                    }
                }
                try Task.checkCancellation()
                let text = texts.joined(separator: "\n")
                guard !files.isEmpty || !text.isEmpty, text.utf8.count <= 32768 else { throw ShareError.invalidSelection }
                let manifest: [String: Any] = ["version": 1, "created": Date().timeIntervalSince1970, "files": files, "text": text]
                try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
                var components = URLComponents(); components.scheme = "bridge-app"; components.host = "share"
                components.queryItems = [URLQueryItem(name: "batch", value: id)]
                guard let url = components.url, NSWorkspace.shared.open(url) else { throw ShareError.cannotOpen }
                extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            } catch {
                if let batch { try? FileManager.default.removeItem(at: batch) }
                message.stringValue = error.localizedDescription
                preparing = false; sendButton.isEnabled = true
            }
        }
    }
    private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: ShareError.invalidSelection) }
            }
        }
    }
    private func copyRepresentation(_ provider: NSItemProvider, type: String, to directory: URL, existing: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }; guard let url else { throw ShareError.invalidSelection }
                    continuation.resume(returning: try Self.copy(url, to: directory, existing: existing))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    nonisolated private static func providerURL(_ value: NSSecureCoding) -> URL? {
        if let url = value as? URL { return url }
        if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let text = value as? String { return URL(string: text) }
        return nil
    }
    nonisolated private static func copy(_ url: URL, to directory: URL, existing: [String]) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let size = attributes.fileSize, size >= 0, Int64(size) <= 16 * 1024 * 1024 * 1024 else { throw ShareError.invalidSelection }
        var name = url.lastPathComponent
        guard !name.isEmpty, !["manifest.json", "consumed.json"].contains(name.lowercased()), !name.hasPrefix("."), !name.contains("/"), name.utf8.count <= 240 else { throw ShareError.invalidSelection }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            while name.utf8.count > 220 { name.removeLast() }
            name = String(UUID().uuidString.prefix(8)) + "-" + name
        }
        try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
        return name
    }
}
private enum ShareError: LocalizedError {
    case invalidSelection, tooManyFiles, cannotOpen
    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "Choose up to three regular files (16 GiB each), a web link, or text up to 32 KB. Compress folders first."
        case .tooManyFiles: return "Share up to three files at a time."
        case .cannotOpen: return "Open Bridge from Applications once, then try sharing again."
        }
    }
}
