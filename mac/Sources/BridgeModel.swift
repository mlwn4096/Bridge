import AppKit
import SwiftUI
import UserNotifications
import CryptoKit
import CoreFoundation
import CoreServices

struct PairedDevice: Codable { var id: String; var name: String }
struct PairingRequest: Identifiable { let id: UUID; let deviceID: String; let name: String; let credential: String }
struct PhoneNotificationAction: Identifiable { let id: String; let title: String; var isReply = false; var placeholder = "Reply" }
struct PhoneNotification: Identifiable {
    let id: String; let app: String; let title: String; let body: String; let date: Date
    var actions: [PhoneNotificationAction] = []
    var packageID = ""
    var appIconPNG: Data? = nil
    var displayApp: String { let label = app.trimmingCharacters(in: .whitespacesAndNewlines); return label.isEmpty ? (packageID.isEmpty ? "Phone" : packageID) : label }
}
struct TransferItem: Identifiable {
    let id: String; let name: String; let size: Int64; let incoming: Bool
    var progress: Double = 0; var bytesPerSecond: Double = 0; var lastProgressUptime: Double = 0; var state: String = "Waiting"; var destination: URL?; var date: Date = Date()
}
// File IO is serialized by fileIOQueue; binary writes/cancellation additionally share a lock.
// Main-thread finalization follows transport backpressure completion, so it cannot overlap a write.
private final class IncomingFile: @unchecked Sendable {
    let handle: FileHandle; let temporary: URL; let destination: URL; let expectedHash: String; let size: Int64
    var received: Int64 = 0; var sequence: Int64 = 0; var hash = SHA256()
    var binary = false
    var started = ProcessInfo.processInfo.systemUptime
    var lastUI = 0.0
    var lastReport = 0.0
    private let lock = NSLock()
    private var cancelled = false
    func appendBinary(_ chunk: BinaryFileChunk) throws -> (Double, Double) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, binary, chunk.sequence == sequence, received + Int64(chunk.data.count) <= size else { throw WireError.invalidTransfer }
        try handle.write(contentsOf: chunk.data); hash.update(data: chunk.data)
        received += Int64(chunk.data.count); sequence += 1
        let speed = Double(received) / max(0.001, ProcessInfo.processInfo.systemUptime - started)
        return (Double(received) / Double(max(1, size)), speed)
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; try? handle.close(); try? FileManager.default.removeItem(at: temporary)
    }
    init(handle: FileHandle, temporary: URL, destination: URL, expectedHash: String, size: Int64) {
        self.handle = handle; self.temporary = temporary; self.destination = destination; self.expectedHash = expectedHash; self.size = size
    }
}
private final class OutgoingFile {
    let url: URL; let size: Int64; var sent: Int64 = 0; var sequence: Int64 = 0; var handle: FileHandle?
    var hashTask: Task<Void, Never>?
    var sendTask: Task<Void, Never>?
    var binary = false
    var expectedHash = ""
    var rateEstimator: TransferRateEstimator?
    init(url: URL, size: Int64) { self.url = url; self.size = size }
}

@MainActor final class BridgeModel: ObservableObject {
    let automation: BridgeAutomation
    @Published var lastConnected: Date?
    @Published var phoneModel = ""
    @Published var phoneOS = ""
    @Published var phoneChip = ""
    @Published var phoneSecurityPatch = ""
    @Published var phoneCores = 0
    @Published var phoneMemoryTotal: Int64?
    @Published var phoneMemoryAvailable: Int64?
    @Published var phoneInfoUpdated: Date?
    @Published var phoneStorageTotal: Int64?
    @Published var phoneFiles: [PhoneFileEntry] = []
    @Published var phoneFilesMessage = ""
    @Published var phoneFolder = ""
    @Published var phoneFilesRequest = ""
    @Published var phoneFilesOffset = 0
    @Published var phoneFilesNextOffset = -1
    @Published var phoneStorageFree: Int64?
    @Published var pairingKeyBlocked = false
    @Published var status = "Starting Bridge…"
    @Published var connected = false
    @Published var paired: PairedDevice?
    @Published var battery: Int?; @Published var charging = false
    @Published var batterySaver = false
    private var hasBatteryStatus = false
    var batterySymbol: String {
        if charging { return "battery.100percent.bolt" }
        switch battery ?? 0 {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    @Published var pairingURL = ""
    @Published var address = ""
    @Published var localPort: UInt16 = 0
    @Published var pairingRequest: PairingRequest?
    @Published var notifications: [PhoneNotification] = []
    @Published var notificationReplyResults: [String: NotificationReplyOutcome] = [:]
    private var pendingNotificationReplies: Set<String> = []
    @Published var transfers: [TransferItem] = []
    @Published var queuedFiles: [QueuedFile] = []
    private var outgoingQueue: OutgoingQueueStore?
    private var queuePumpScheduled = false
    private var suppressedQueueIDs: Set<String> = []
    private let transferReceipts = TransferReceiptStore()
    private var queueGeneration = UUID()
    private var queueEpoch = ""
    private var folderTasks: [UUID: Task<Void, Never>] = [:]
    @Published var clipboardHistory = ClipboardHistoryStore()
    @Published var clipboardHistoryEnabled = UserDefaults.standard.bool(forKey: "clipboardHistoryEnabled") {
        didSet {
            if !preview { UserDefaults.standard.set(clipboardHistoryEnabled, forKey: "clipboardHistoryEnabled") }
            if !clipboardHistoryEnabled { clipboardHistory.clear() }
        }
    }
    @Published var incomingClipboard = ""
    @Published var incomingLink = ""
    @Published var incomingHandoff: LinkHandoff?
    @Published var notice = "" {
        didSet {
            noticeTask?.cancel(); noticeTransferIDs = []
            guard !notice.isEmpty else { return }
            let message = notice
            // Count from presentation time, even if the main actor is busy.
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            noticeTask = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard let self, !Task.isCancelled, self.notice == message else { return }
                self.notice = ""
            }
        }
    }
    private var noticeTask: Task<Void, Never>?
    private var noticeTransferIDs: Set<String> = []
    func showTransferNotice(_ message: String, ids: Set<String>) { notice = message; noticeTransferIDs = ids }
    private func clearTransferNotice(_ id: String) { if noticeTransferIDs.contains(id) { notice = "" } }
    @Published var notificationStatus = "Checking…"
    @Published var clipboardNotifications: Bool = UserDefaults.standard.bool(forKey: "clipboardNotifications") {
        didSet { UserDefaults.standard.set(clipboardNotifications, forKey: "clipboardNotifications") }
    }
    @Published var dragSendEnabled = UserDefaults.standard.object(forKey: "dragSendEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dragSendEnabled, forKey: "dragSendEnabled") }
    }
    private var dragSendOverlay: DragSendOverlay?
    private let notificationPresenter = BridgeNotificationPresenter()
    @Published var ringing = false
    @Published var mediaAvailable = false
    @Published var mediaTitle = ""
    @Published var mediaArtist = ""
    @Published var mediaPlaying = false
    @Published var mediaActions: Set<String> = []
    private var mediaSessionID = ""
    @Published var autoClipboard: Bool { didSet { if !preview { UserDefaults.standard.set(autoClipboard, forKey: "autoClipboard") }; clipboardCount = NSPasteboard.general.changeCount } }
    @Published var mirrorNotifications: Bool { didSet {
        if !preview { UserDefaults.standard.set(mirrorNotifications, forKey: "mirrorNotifications") }
        if !mirrorNotifications {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifications.map { notificationIdentifier($0.id) })
            notifications = []
        }
        syncPreferences()
    } }
    @Published var notificationPreviews: Bool { didSet {
        if !preview { UserDefaults.standard.set(notificationPreviews, forKey: "notificationPreviews") }
        if !notificationPreviews {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifications.map { notificationIdentifier($0.id) })
            notifications = notifications.map { PhoneNotification(id: $0.id, app: $0.app, title: "New notification", body: "Open your phone to view its contents.", date: $0.date, packageID: $0.packageID, appIconPNG: $0.appIconPNG) }
        }
        syncPreferences()
    } }
    @Published var launchAtLogin = false
    @Published var lowBatteryAlerts: Bool = UserDefaults.standard.object(forKey: "lowBatteryAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lowBatteryAlerts, forKey: "lowBatteryAlerts"); checkLowBattery() }
    }
    @Published var lowBatteryThreshold: Int = max(5, min(50, UserDefaults.standard.object(forKey: "lowBatteryThreshold") as? Int ?? 20)) {
        didSet { UserDefaults.standard.set(lowBatteryThreshold, forKey: "lowBatteryThreshold"); checkLowBattery() }
    }
    @Published var askWhereToSave: Bool = UserDefaults.standard.object(forKey: "askWhereToSave") as? Bool ?? !(UserDefaults.standard.object(forKey: "autoReceiveFiles") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(askWhereToSave, forKey: "askWhereToSave") }
    }
    private var shareReceiver: BridgeShareReceiver?
    private let pairingTrust = PairingTrustStore()
    private var legacyTrustReadAttempted = false
    private let preview: Bool
    private var identity: DeviceIdentity?
    private let server = LocalServer()
    private var peers: [UUID: PeerConnection] = [:]
    private var active: PeerConnection?
    private var token = randomSecret()
    private var tokenExpires = Date()
    private let usbTransport = USBTransport()
    private var port: UInt16?
    private var heartbeatTimer: Timer?
    private var clipboardTimer: Timer?
    private var clipboardCount = 0
    private var seenIDs: [String] = []
    private var pendingClipboardID: String?
    private var connectionNoticeGeneration = UUID()
    private var lastConnectionBanner = Date.distantPast
    private var offers: [String: WireMessage] = [:]
    private var saveRequests: [String] = []
    private var savePanel: NSSavePanel?
    private var savePanelTransferID: String?
    private let fileIOQueue = DispatchQueue(label: "Bridge.fileIO", qos: .utility)
    private var receiving: [String: IncomingFile] = [:]
    private var sending: [String: OutgoingFile] = [:]

    init(preview: Bool = false, automationDefaults: UserDefaults? = nil) {
        self.preview = preview
        automation = BridgeAutomation(defaults: automationDefaults ?? .standard)
        autoClipboard = UserDefaults.standard.object(forKey: "autoClipboard") as? Bool ?? true
        mirrorNotifications = UserDefaults.standard.object(forKey: "mirrorNotifications") as? Bool ?? true
        notificationPreviews = UserDefaults.standard.object(forKey: "notificationPreviews") as? Bool ?? false
        if let data = UserDefaults.standard.data(forKey: "pairedDevice") { paired = try? JSONDecoder().decode(PairedDevice.self, from: data) }
        if let paired {
            lastConnected = UserDefaults.standard.object(forKey: "lastConnected." + paired.id) as? Date
            queueEpoch = UserDefaults.standard.string(forKey: "queueEpoch." + paired.id) ?? UUID().uuidString
            if !preview { UserDefaults.standard.set(queueEpoch, forKey: "queueEpoch." + paired.id) }
        }
        if preview { status = "Ready to pair"; return }
        // Register this installed bundle's current named icon before creating
        // the notification-center identity; preserve the bundle ID and pairing.
        let registration = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        if registration != noErr { NSLog("Bridge app registration returned %d", registration) }
        do {
            outgoingQueue = try OutgoingQueueStore()
            for entry in outgoingQueue?.entries.filter({ $0.deviceID != paired?.id || $0.epoch != queueEpoch }) ?? [] { removeQueuedFile(entry.id) }
            restoreQueuedTransfers()
        }
        catch { notice = error.localizedDescription }
        notificationPresenter.onHandoffResponse = { [weak self] id in
            guard let self, self.incomingHandoff?.id.uuidString == id else { return }
            self.openReceivedLink()
        }
        notificationPresenter.onFileResponse = { [weak self] id in
            guard let file = self?.transfers.first(where: { $0.id == id && $0.incoming && $0.state == "Complete" }),
                  let destination = file.destination, FileManager.default.fileExists(atPath: destination.path) else { return }
            NSWorkspace.shared.open(destination)
        }
        notificationPresenter.onPhoneNotificationOpen = { _ in BridgeApplicationDelegate.showPage("notifications") }
        notificationPresenter.onPhoneNotificationResponse = { [weak self] key in self?.dismissNotification(key) }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "bridge.phone", actions: [], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "bridge.link", actions: [UNNotificationAction(identifier: "bridge.open", title: "Open link", options: [.foreground])], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "bridge.file", actions: [UNNotificationAction(identifier: "bridge.open", title: "Open file", options: [.foreground])], intentIdentifiers: [], options: [])
        ])
        UNUserNotificationCenter.current().delegate = notificationPresenter
        refreshNotificationStatus()
        shareReceiver = BridgeShareReceiver(model: self)
        start()
        dragSendOverlay = DragSendOverlay(model: self)
        Task { @MainActor [weak self] in
            guard let self else { return }
            NSApplication.shared.servicesProvider = BridgeServices(model: self)
            NSUpdateDynamicServices()
        }
    }
    func start() {
        do {
            let identity = try DeviceIdentity.load(); self.identity = identity
            server.onConnection = { [weak self] peer in self?.add(peer) }
            server.onState = { [weak self] state, port in
                guard let self else { return }; self.port = port; self.localPort = port ?? 0
                if !self.connected { self.status = state }; self.refreshPairing()
                if let port { self.usbTransport.start(port: port) }
            }
            try server.start(identity: identity)
            clipboardCount = NSPasteboard.general.changeCount
            clipboardTimer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkClipboard() }
            }
            if let clipboardTimer { RunLoop.main.add(clipboardTimer, forMode: .common) }
            heartbeatTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.heartbeat() }
            }
            if let heartbeatTimer { RunLoop.main.add(heartbeatTimer, forMode: .common) }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPairing(); self?.heartbeat() }
            }
        } catch { status = "Setup needs attention"; notice = error.localizedDescription }
    }
    func refreshPairing() {
        guard let identity, let port else { return }
        token = randomSecret(); tokenExpires = Date().addingTimeInterval(300)
        address = localIPv4() ?? ""
        guard !address.isEmpty else { pairingURL = ""; if !connected { status = "Connect this Mac to Wi-Fi" }; return }
        var url = URLComponents(); url.scheme = "bridge"; url.host = "pair"
        url.queryItems = [URLQueryItem(name: "host", value: address), URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fingerprint", value: identity.fingerprint), URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "name", value: Host.current().localizedName ?? "Mac"),
            URLQueryItem(name: "service", value: "Bridge-" + String(identity.fingerprint.prefix(8)))]
        pairingURL = url.string ?? ""
    }
    func requestNotificationPermission() {
        if notificationStatus.hasPrefix("Disabled") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.refreshNotificationStatus()
                if let error { self.notice = error.localizedDescription }
                else if !granted { self.notice = "Enable Bridge in System Settings → Notifications to receive banners." }
            }
        }
    }
    func refreshNotificationStatus() {
        guard !preview else { notificationStatus = "Preview · no system permission request"; return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .notDetermined: self.notificationStatus = "Permission not requested"
                case .denied: self.notificationStatus = "Disabled in System Settings"
                case .authorized, .provisional, .ephemeral:
                    self.notificationStatus = settings.alertSetting == .enabled ? "System alerts allowed" : "Banners disabled in System Settings"
                @unknown default: self.notificationStatus = "System managed"
                }
            }
        }
    }
    func sendTestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.refreshNotificationStatus()
                if granted { self.systemNotification("Bridge notifications", body: "System notification banners are working.", id: "bridge.test") }
                else { self.notice = error?.localizedDescription ?? "Enable Bridge in System Settings → Notifications to receive banners." }
            }
        }
    }
    private func systemNotification(_ title: String, body: String, id: String = UUID().uuidString, category: String = "", metadata: [String: String] = [:]) {
        guard !preview else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        content.categoryIdentifier = category; content.userInfo = metadata
        BridgeNotificationArtwork.attach(to: content)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor in self?.notice = "Notification failed: " + error.localizedDescription } }
        }
    }
    private func add(_ peer: PeerConnection) {
        guard peers.count < 4 else { peer.close(); return }
        peers[peer.id] = peer
        peer.onFileChunk = { [weak self] peer, chunk, done in
            guard let self else { done(); return }; self.receiveBinary(peer, chunk, done: done)
        }
        peer.onMessage = { [weak self] peer, message in self?.receive(peer, message) }
        peer.onClose = { [weak self] peer in self?.disconnected(peer) }
        peer.start()
    }
    private func receive(_ peer: PeerConnection, _ message: WireMessage) {
        if !peer.authorized {
            peer.isUSB = message.string("transport") == "usb"
            if message.type == "pairRequest" {
                let deviceID = message.string("deviceID"), credential = message.string("credential")
                guard paired == nil, pairingRequest == nil, Date() < tokenExpires,
                      constantTimeEqual(message.string("token"), token), UUID(uuidString: deviceID) != nil,
                      Data(base64Encoded: credential)?.count == 32, !message.string("name").isEmpty else { peer.send(WireMessage("error", ["message": "Pairing unavailable or expired"])); peer.close(); return }
                peer.supportsBinary = (message.payload["capabilities"] as? [String] ?? []).contains("binaryFileV1")
                peer.receiverProgress = (message.payload["capabilities"] as? [String] ?? []).contains("receiverProgressV1")
                peer.supportsTransferFailure = (message.payload["capabilities"] as? [String] ?? []).contains("fileFailureV1")
                peer.supportsNotificationReplies = (message.payload["capabilities"] as? [String] ?? []).contains("notificationReplyV1")
                pairingRequest = PairingRequest(id: peer.id, deviceID: deviceID, name: String(message.string("name").prefix(80)), credential: credential)
                NSApp.activate(ignoringOtherApps: true)
            } else if message.type == "auth", let paired, message.string("deviceID") == paired.id {
                do {
                    var trust = try pairingTrust.read(paired.id)
                    if trust == nil && !legacyTrustReadAttempted {
                        legacyTrustReadAttempted = true
                        if let credential = Secrets.read(paired.id) {
                            try pairingTrust.write(paired.id, credential: credential)
                            trust = try pairingTrust.read(paired.id)
                        }
                    }
                    guard let trust else {
                        pairingKeyBlocked = true; status = "Unlock existing pairing once"
                        notice = "Click Unlock pairing key once to upgrade your existing pairing. Future reconnects won’t access Keychain."
                        peer.close(); return
                    }
                    guard trust.matches(deviceID: paired.id, credential: message.string("credential")) else { peer.close(); return }
                } catch {
                    pairingKeyBlocked = true; status = "Pairing trust needs attention"
                    notice = error.localizedDescription; peer.close(); return
                }
                peer.supportsBinary = (message.payload["capabilities"] as? [String] ?? []).contains("binaryFileV1")
                peer.receiverProgress = (message.payload["capabilities"] as? [String] ?? []).contains("receiverProgressV1")
                peer.supportsTransferFailure = (message.payload["capabilities"] as? [String] ?? []).contains("fileFailureV1")
                peer.supportsNotificationReplies = (message.payload["capabilities"] as? [String] ?? []).contains("notificationReplyV1")
                authorize(peer, deviceID: paired.id)
                peer.send(WireMessage("authAccepted", ["name": Host.current().localizedName ?? "Mac", "capabilities": ["binaryFileV1", "receiverProgressV1", "fileFailureV1", "notificationReplyV1"]]))
                peer.send(WireMessage("deviceInfo", BridgeLocalDeviceInfo.snapshot()))
                syncPreferences()
            } else { peer.close() }
            return
        }
        // A replaced connection can still deliver callbacks already queued by
        // Network.framework. Only the current session may mutate app state.
        guard active === peer else { return }
        if message.type == "ack" {
            if message.string("messageID") == pendingClipboardID {
                notice = "Phone received clipboard text"; pendingClipboardID = nil
                if clipboardNotifications { systemNotification("Clipboard sent", body: "Text is ready to paste on your phone.", id: "bridge.clipboard.sent") }
            }
            return
        }
        if seenIDs.contains(message.id) { peer.send(WireMessage("ack", ["messageID": message.id])); return }
        seenIDs.append(message.id); if seenIDs.count > 2048 { seenIDs.removeFirst(1024) }
        peer.send(WireMessage("ack", ["messageID": message.id]))
        switch message.type {
        case "usbSwitchRequest":
            // Both endpoints must be idle before replacing the active route.
            if sending.isEmpty && receiving.isEmpty && offers.isEmpty {
                peer.send(WireMessage("usbSwitchReady"))
            }
        case "ping": peer.send(WireMessage("pong"))
        case "pong": break
        case "battery":
            let level = Int(message.integer("level"))
            guard (0...100).contains(level) else { return }
            battery = level; charging = message.payload["charging"] as? Bool ?? false
            let saver = message.payload["powerSave"] as? Bool ?? false
            if hasBatteryStatus && saver != batterySaver {
                systemNotification(saver ? "Phone Battery Saver enabled" : "Phone Battery Saver disabled",
                    body: saver ? "Your Pixel is conserving battery." : "Your Pixel has returned to normal power mode.", id: "bridge.batterySaver")
            }
            batterySaver = saver; hasBatteryStatus = true
            checkLowBattery()
        case "media":
            mediaAvailable = message.payload["available"] as? Bool ?? false
            mediaSessionID = message.string("sessionID")
            mediaTitle = String(message.string("title").prefix(300)); mediaArtist = String(message.string("artist").prefix(300))
            mediaPlaying = message.payload["playing"] as? Bool ?? false
            mediaActions = Set(message.payload["actions"] as? [String] ?? [])
        case "mediaCommandResult":
            if message.payload["accepted"] as? Bool != true { notice = "Phone media changed or this control isn’t supported. Try again." }
        case "clipboard":
            let text = message.string("text")
            guard !text.isEmpty, text.utf8.count <= WireMessage.maxClipboard else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            clipboardCount = NSPasteboard.general.changeCount; incomingClipboard = text
            if clipboardHistoryEnabled { clipboardHistory.record(text, sourceID: paired?.id ?? "phone", sourceName: paired?.name ?? "Phone") }
            notice = "Phone text copied to your Mac clipboard"
            if clipboardNotifications { systemNotification("Clipboard received", body: "Phone text is ready to paste on your Mac.", id: "bridge.clipboard.received") }
        case "notification": mirror(message)
        case "notificationRemoved":
            notifications.removeAll { $0.id == message.string("key") }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier(message.string("key"))])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier(message.string("key"))])
        case "notificationDismissResult":
            if message.payload["accepted"] as? Bool != true { notice = "Phone couldn’t dismiss this notification. It may have expired or be protected." }
        case "notificationReplyResult":
            let id = message.string("actionID")
            guard pendingNotificationReplies.remove(id) != nil else { return }
            let accepted = message.payload["accepted"] as? Bool == true
            notificationReplyResults[id] = NotificationReplyOutcome(accepted: accepted, message: String(message.string("message").prefix(240)))
            notice = accepted ? "Reply handed to phone app" : "Phone could not accept the reply"
        case "notificationActionResult":
            notice = message.payload["accepted"] as? Bool == true ? "Action requested on phone" : "Action unavailable. Unlock your phone or wait for an updated notification."
        case "link":
            let link = message.string("url")
            if let handoff = LinkHandoff(link, title: message.string("title")) {
                incomingLink = handoff.url.absoluteString; incomingHandoff = handoff
                systemNotification("Link from your phone", body: "\(handoff.host) · Click to open", id: "bridge.link", category: "bridge.link", metadata: ["handoffID": handoff.id.uuidString])
            }
        case "fileOffer": offer(message)
        case "fileAccept": beginSending(message.string("transferID"), binary: message.string("encoding") == "binary-v1")
        case "fileReject":
            let id = message.string("transferID")
            guard sending[id] != nil else { return }
            do {
                if try outgoingQueue?.pauseAfterRejection(id, reason: "Phone could not accept this file. Check Android Bridge, then retry.") != nil {
                    cleanupOutgoing(id); suppressedQueueIDs.insert(id); updateTransfer(id, state: "Paused", progress: 0)
                    restoreQueuedTransfers(); scheduleQueuePump(); notice = "Phone could not accept the file. It remains queued; retry from Activity."
                }
            } catch { disableFileQueue(error.localizedDescription) }
        case "fileFailed":
            let id = message.string("transferID")
            guard peer.supportsTransferFailure, sending[id] != nil else { return }
            failTransfer(id, String(message.string("reason").prefix(240)))
        case "fileCancel": cancelTransfer(message.string("transferID"), send: false)
        case "fileChunk": receiveChunk(message)
        case "fileProgress":
            let id = message.string("transferID")
            guard active === peer, peer.receiverProgress, let file = sending[id], file.binary,
                  let number = message.payload["receivedBytes"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue == Double(number.int64Value), var estimator = file.rateEstimator,
                  estimator.record(number.int64Value, now: ProcessInfo.processInfo.systemUptime) else { return }
            file.rateEstimator = estimator
            guard let index = transfers.firstIndex(where: { $0.id == id }), ["Sending", "Finishing"].contains(transfers[index].state) else { return }
            if transfers[index].state == "Finishing" && estimator.bytes == file.size { transfers[index].state = "Verifying" }
            transfers[index].lastProgressUptime = ProcessInfo.processInfo.systemUptime
            transfers[index].progress = Double(estimator.bytes) / Double(max(1, file.size))
            transfers[index].bytesPerSecond = estimator.rate
        case "fileComplete": finishReceiving(message.string("transferID"))
        case "fileReceived":
            let id = message.string("transferID")
            guard let file = sending[id], let transfer = transfers.first(where: { $0.id == id }),
                  (["Finishing", "Verifying"].contains(transfer.state) || (transfer.state == "Waiting for phone" && message.payload["alreadyReceived"] as? Bool == true && message.string("sha256") == file.expectedHash && message.integer("size") == file.size)) else { return }
            updateTransfer(id, state: "Complete", progress: 1); cleanupOutgoing(id); removeQueuedFile(id); scheduleQueuePump()
            systemNotification("File sent to phone", body: file.url.lastPathComponent, id: "bridge.transfer." + id)
        case "phoneFiles":
            guard message.string("requestID") == phoneFilesRequest else { return }
            phoneFilesMessage = String(message.string("error").prefix(240))
            phoneFolder = message.string("folder")
            phoneFilesOffset = Int(max(0, min(10000, message.integer("offset"))))
            let nextOffset = message.integer("nextOffset")
            phoneFilesNextOffset = nextOffset > Int64(phoneFilesOffset) && nextOffset <= 10000 ? Int(nextOffset) : -1
            phoneFiles = (message.payload["entries"] as? [[String: Any]] ?? []).prefix(1000).compactMap { PhoneFileEntry($0) }
        case "deviceInfo":
            phoneChip = String(message.string("chip").prefix(120))
            phoneSecurityPatch = String(message.string("securityPatch").prefix(40))
            phoneCores = Int(max(0, min(256, message.integer("cores"))))
            phoneMemoryTotal = message.integer("memoryTotal") > 0 ? message.integer("memoryTotal") : nil
            phoneMemoryAvailable = phoneMemoryTotal.map { min($0, max(0, message.integer("memoryAvailable"))) }
            phoneInfoUpdated = Date()
            phoneModel = String(message.string("model").prefix(120)); phoneOS = String(message.string("os").prefix(80))
            let total = message.integer("storageTotal")
            phoneStorageTotal = total > 0 ? total : nil
            let free = message.integer("storageFree")
            if free >= 0 { phoneStorageFree = free }
        case "ringState": ringing = message.payload["ringing"] as? Bool ?? false
        case "unpair": unpair(send: false)
        case "error":
            notice = String(message.string("message").prefix(240))
            systemNotification("Phone reported a problem", body: notice, id: "bridge.peerError")
        default: break
        }
    }
    func unlockPairingKey() {
        guard let paired else { return }
        do {
            if try pairingTrust.read(paired.id) == nil {
                guard let credential = Secrets.read(paired.id, allowPrompt: true) else {
                    notice = "Existing pairing could not be unlocked. Try again or unpair and scan a new code."; return
                }
                try pairingTrust.write(paired.id, credential: credential)
            }
            pairingKeyBlocked = false; status = "Waiting for \(paired.name)"
            notice = "Pairing upgraded. Your phone will reconnect without routine Keychain prompts."
        } catch { notice = error.localizedDescription }
    }
    func confirmPairing() {
        guard let request = pairingRequest, let peer = peers[request.id] else { return }
        do {
            try pairingTrust.write(request.deviceID, credential: request.credential)
            queueEpoch = UUID().uuidString; UserDefaults.standard.set(queueEpoch, forKey: "queueEpoch." + request.deviceID)
            let device = PairedDevice(id: request.deviceID, name: request.name)
            paired = device; UserDefaults.standard.set(try JSONEncoder().encode(device), forKey: "pairedDevice")
            authorize(peer, deviceID: request.deviceID); pairingRequest = nil; tokenExpires = .distantPast; pairingURL = ""
            peer.send(WireMessage("pairAccepted", ["name": Host.current().localizedName ?? "Mac", "capabilities": ["binaryFileV1", "receiverProgressV1", "fileFailureV1", "notificationReplyV1"]]))
            peer.send(WireMessage("deviceInfo", BridgeLocalDeviceInfo.snapshot()))
            syncPreferences(); requestNotificationPermission()
        } catch { notice = error.localizedDescription; rejectPairing() }
    }
    func rejectPairing() { if let request = pairingRequest { peers[request.id]?.close() }; pairingRequest = nil }
    private func authorize(_ peer: PeerConnection, deviceID: String) {
        if let previous = active, previous !== peer {
            // Cancel before changing active: the old disconnect callback cannot
            // clean up once the replacement session has become current.
            for id in Array(sending.keys) { suspendQueuedTransfer(id) }
            for id in Set(receiving.keys).union(offers.keys) { cancelTransfer(id, send: false) }
            pendingClipboardID = nil
            notifications = []
            previous.close()
        }
        active = peer; peer.authorized = true; peer.deviceID = deviceID
        pairingKeyBlocked = false
        lastConnected = Date(); UserDefaults.standard.set(lastConnected, forKey: "lastConnected." + deviceID)
        automation.emit(.phoneConnected, context: paired?.name ?? "Phone")
        connected = true; status = peer.isUSB ? "Connected via USB" : "Connected"; seenIDs = []; clipboardCount = NSPasteboard.general.changeCount
        connectionNoticeGeneration = UUID()
        scheduleQueuePump()
        if Date().timeIntervalSince(lastConnectionBanner) > 30 {
            lastConnectionBanner = Date()
            systemNotification("\(paired?.name ?? "Phone") connected", body: "Your devices are ready to share.", id: "bridge.connection")
        }
    }
    private func disconnected(_ peer: PeerConnection) {
        peers.removeValue(forKey: peer.id)
        if pairingRequest?.id == peer.id { pairingRequest = nil }
        guard active === peer else { return }
        automation.emit(.phoneDisconnected, context: paired?.name ?? "Phone")
        active = nil; connected = false; battery = nil; ringing = false
        phoneChip = ""; phoneSecurityPatch = ""; phoneCores = 0; phoneMemoryTotal = nil; phoneMemoryAvailable = nil; phoneInfoUpdated = nil
        phoneStorageFree = nil; phoneStorageTotal = nil; phoneFiles = []; phoneFilesMessage = ""; phoneFolder = ""; phoneFilesRequest = ""; phoneModel = ""; phoneOS = ""
        batterySaver = false; hasBatteryStatus = false
        mediaAvailable = false; mediaSessionID = ""; mediaTitle = ""; mediaArtist = ""; mediaActions = []
        status = paired == nil ? "Ready to pair" : "Waiting for \(paired?.name ?? "phone")"
        let generation = UUID(); connectionNoticeGeneration = generation
        let deviceID = paired?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.connected, self.paired != nil, self.paired?.id == deviceID,
                  self.connectionNoticeGeneration == generation else { return }
            self.systemNotification("Phone disconnected", body: "Bridge will reconnect when your phone is available.", id: "bridge.connection")
        }
        for id in Array(receiving.keys) { cancelTransfer(id, send: false) }
        for id in Array(sending.keys) { suspendQueuedTransfer(id) }
        for id in Array(offers.keys) { cancelTransfer(id, send: false) }
    }
    func unpair(send: Bool = true) {
        if send, let active { active.send(WireMessage("unpair")) }
        queueGeneration = UUID(); folderTasks.values.forEach { $0.cancel() }; folderTasks.removeAll()
        for id in Array(sending.keys) { cleanupOutgoing(id) }
        for id in Set(receiving.keys).union(offers.keys) { cancelTransfer(id, send: false) }
        active = nil; connected = false
        if let paired {
            transferReceipts.revoke(peer: paired.id)
            for entry in outgoingQueue?.entries.filter({ $0.deviceID == paired.id }) ?? [] { removeQueuedFile(entry.id) }
            do { try pairingTrust.delete(paired.id) }
            catch { notice = "Phone unpaired, but local trust cleanup failed: " + error.localizedDescription }
            Secrets.delete(paired.id)
        }
        legacyTrustReadAttempted = false
        paired = nil; queuedFiles = []; queueEpoch = ""; lastConnected = nil; battery = nil; ringing = false; mediaAvailable = false; phoneModel = ""; phoneOS = ""; phoneStorageFree = nil
        UserDefaults.standard.removeObject(forKey: "pairedDevice")
        let connections = Array(peers.values); connections.forEach { $0.close() }
        clipboardHistory.clear(); notifications = []; incomingClipboard = ""; dismissHandoff(); refreshPairing()
    }
    private func heartbeat() {
        scheduleQueuePump()
        if let active {
            if ProcessInfo.processInfo.systemUptime - active.lastSeenUptime > 50 { active.close() } else { active.send(WireMessage("ping")); active.send(WireMessage("deviceInfo", BridgeLocalDeviceInfo.snapshot())) }
        } else if Date() > tokenExpires { refreshPairing() }
    }
    func syncPreferences() { active?.send(WireMessage("preferences", ["notifications": mirrorNotifications, "previews": notificationPreviews])) }
    private func checkClipboard() {
        if incomingHandoff?.expired() == true { dismissHandoff() }
        if clipboardHistoryEnabled && clipboardHistory.entries.contains(where: { !$0.pinned && Date().timeIntervalSince($0.date) >= 86400 }) {
            clipboardHistory.prune()
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardCount else { return }; clipboardCount = pasteboard.changeCount
        guard autoClipboard, connected else { return }; sendClipboard(manual: false)
    }
    var clipboardAccessDescription: String {
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return "Always allowed"
        case .alwaysDeny: return "Denied"
        case .ask: return "Ask before reading"
        case .default: return "Not requested yet"
        @unknown default: return "System managed"
        }
    }
    func openClipboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") { NSWorkspace.shared.open(url) }
    }
    func sendClipboard(manual: Bool = true) {
        guard active != nil, connected else { notice = "Connect your phone before sending text"; return }
        if manual { NSApp.activate(ignoringOtherApps: true) }
        let pasteboard = NSPasteboard.general
        if pasteboard.accessBehavior == .alwaysDeny {
            notice = "Clipboard access is denied. Allow Bridge in System Settings → Privacy & Security → Clipboard."
            return
        }
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        guard !(pasteboard.types ?? []).contains(where: { blocked.contains($0.rawValue) }) else { notice = "Sensitive clipboard content skipped"; return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            notice = "No readable clipboard text. Access: \(clipboardAccessDescription). Copy plain text and try again."
            return
        }
        _ = sendSelectedText(text, manual: manual)
    }
    @discardableResult func sendSelectedText(_ text: String, manual: Bool = true) -> Bool {
        guard let active, connected else { notice = "Connect your phone before sending text"; return false }
        guard !text.isEmpty, text.utf8.count <= WireMessage.maxClipboard else { notice = "Send between 1 byte and 32 KB of text"; return false }
        if let reason = ClipboardProtection.reason(text) {
            guard manual else { notice = "\(reason): automatic clipboard sync skipped"; return false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Send sensitive clipboard text?"
            alert.informativeText = "\(reason). This text will replace your phone clipboard."
            alert.addButton(withTitle: "Don’t Sync")
            alert.addButton(withTitle: "Sync Once")
            guard alert.runModal() == .alertSecondButtonReturn else { notice = "Sensitive clipboard text kept on this Mac"; return false }
        }
        if clipboardHistoryEnabled { clipboardHistory.record(text, sourceID: "mac", sourceName: "This Mac") }
        let message = WireMessage("clipboard", ["text": text]); pendingClipboardID = message.id
        notice = "Sending clipboard text…"
        active.send(message) { [weak self] success in if !success { self?.notice = "Clipboard send interrupted; reconnect and try again" } }
        return true
    }
    func copyHistoryEntry(_ entry: ClipboardHistoryEntry) {
        guard clipboardHistoryEnabled, clipboardHistory.entries.contains(where: { $0.id == entry.id }) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string)
        clipboardCount = NSPasteboard.general.changeCount
        notice = "History text copied on Mac"
    }
    @discardableResult func sendWebLink(_ raw: String, title: String = "") -> Bool {
        guard let active, connected else { notice = "Connect your phone before sending a link"; return false }
        guard let link = LinkHandoff(raw, title: title) else { notice = "Choose an http or https link"; return false }
        if let reason = ClipboardProtection.reason(raw) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = "Send sensitive link?"; alert.informativeText = reason
            alert.addButton(withTitle: "Don’t send"); alert.addButton(withTitle: "Send once")
            guard alert.runModal() == .alertSecondButtonReturn else { notice = "Link kept on this Mac"; return false }
        }
        active.send(WireMessage("link", ["url": link.url.absoluteString, "title": link.title])) { [weak self] success in
            self?.notice = success ? "Link sent to your phone" : "Link send interrupted; try again"
        }
        return true
    }
    func sendLinkFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { notice = "Copy an http or https link first"; return }
        _ = sendWebLink(text)
    }
    func dismissHandoff() {
        incomingHandoff = nil; incomingLink = ""
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["bridge.link"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["bridge.link"])
    }
    func openReceivedLink() {
        guard let handoff = incomingHandoff, !handoff.expired() else { dismissHandoff(); return }
        if NSWorkspace.shared.open(handoff.url) { dismissHandoff() }
        else { notice = "Could not open the page. Try again." }
    }
    func browsePhone(_ folder: String = "", offset: Int = 0) {
        guard connected else { phoneFilesMessage = "Connect your phone to browse files."; return }
        phoneFiles = []; phoneFilesNextOffset = -1; phoneFilesMessage = "Loading…"; phoneFilesRequest = UUID().uuidString
        let request = phoneFilesRequest
        active?.send(WireMessage("listPhoneFiles", ["folder": folder, "requestID": request, "offset": offset]))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.phoneFilesRequest == request, self.phoneFilesMessage == "Loading…" else { return }
            self.phoneFilesMessage = "No reply from your phone. Update Android Bridge and try Refresh."
        }
    }
    func downloadPhoneFile(_ id: String) {
        guard connected else { return }
        active?.send(WireMessage("downloadPhoneFile", ["document": id]))
    }
    func ringPhone() { active?.send(WireMessage("ring", ["start": !ringing])); ringing.toggle() }
    private func checkLowBattery() {
        guard !preview, let paired, let battery else { return }
        let automationKey = "automation.lowBatteryEpisode." + paired.id
        let automationDecision = BatteryAlertDecision.evaluate(level: battery, charging: charging, enabled: true,
            threshold: lowBatteryThreshold, latched: UserDefaults.standard.bool(forKey: automationKey))
        UserDefaults.standard.set(automationDecision.latched, forKey: automationKey)
        if automationDecision.notify { automation.emit(.lowBattery, context: "\(battery)% battery remaining") }
        let key = "lowBatteryEpisode." + paired.id
        let decision = BatteryAlertDecision.evaluate(level: battery, charging: charging, enabled: lowBatteryAlerts,
            threshold: lowBatteryThreshold, latched: UserDefaults.standard.bool(forKey: key))
        UserDefaults.standard.set(decision.latched, forKey: key)
        if decision.notify {
            systemNotification("\(paired.name) battery is low", body: "\(battery)% remaining. Connect your phone to a charger.", id: "bridge.lowBattery." + paired.id)
            notice = "Phone battery is low: \(battery)%"
        }
    }
    func mediaCommand(_ action: String) {
        guard connected, mediaAvailable, !mediaSessionID.isEmpty else { return }
        active?.send(WireMessage("mediaCommand", ["sessionID": mediaSessionID, "action": action]))
    }
    private func mirror(_ message: WireMessage) {
        guard mirrorNotifications else { return }
        let key = String(message.string("key").prefix(512)); guard !key.isEmpty else { return }
        let appLabel = String(message.string("app").prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        let packageID = String(message.string("package").prefix(200))
        let app = appLabel.isEmpty ? (packageID.isEmpty ? "Phone" : packageID) : appLabel
        let title = notificationPreviews ? String(message.string("title").prefix(300)) : "New notification"
        let body = notificationPreviews ? String(message.string("body").prefix(2000)) : "Open your phone to view its contents."
        let appIconPNG = BridgeNotificationArtwork.decodeAppIcon(message.string("appIconPNG"))
        let isUpdate = notifications.contains { $0.id == key }
        notifications.removeAll { $0.id == key }
        let actions: [PhoneNotificationAction] = notificationPreviews ? (message.payload["actions"] as? [[String: Any]] ?? []).prefix(3).compactMap { item in
            guard let id = item["id"] as? String, UUID(uuidString: id) != nil,
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            let isReply = item["kind"] as? String == "reply"
            guard !isReply || active?.supportsNotificationReplies == true else { return nil }
            return PhoneNotificationAction(id: id, title: String(title.prefix(80)), isReply: isReply,
                placeholder: String((item["placeholder"] as? String ?? "Reply").prefix(80)))
        } : []
        notifications.insert(PhoneNotification(id: key, app: app, title: title, body: body, date: Date(), actions: actions, packageID: packageID, appIconPNG: appIconPNG), at: 0)
        if notifications.count > 100 { notifications.removeLast() }
        let content = UNMutableNotificationContent(); content.title = app + ": " + title; content.body = body
        content.categoryIdentifier = "bridge.phone"; content.userInfo = ["phoneKey": key]
        BridgeNotificationArtwork.attach(to: content, appIconPNG: appIconPNG)
        if !isUpdate { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationIdentifier(key), content: content, trigger: nil))
    }
    private func notificationIdentifier(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }
    func dismissNotification(_ key: String) {
        guard connected, mirrorNotifications else { notice = "Connect your phone before dismissing its notification"; return }
        active?.send(WireMessage("notificationDismiss", ["key": key]))
    }
    func performNotificationAction(_ key: String, actionID: String) {
        guard connected, mirrorNotifications, notificationPreviews,
              let index = notifications.firstIndex(where: { $0.id == key }), notifications[index].actions.contains(where: { $0.id == actionID && !$0.isReply }) else { return }
        notifications[index].actions.removeAll { $0.id == actionID }
        active?.send(WireMessage("notificationAction", ["key": key, "actionID": actionID]))
        notice = "Requesting phone action…"
    }
    func refreshPhoneNotifications() {
        guard connected, mirrorNotifications else { return }
        active?.send(WireMessage("refreshNotifications"))
    }
    func canReplyToNotification(_ key: String, actionID: String) -> Bool {
        connected && mirrorNotifications && notificationPreviews && active?.supportsNotificationReplies == true &&
        notifications.contains { $0.id == key && $0.actions.contains { $0.id == actionID && $0.isReply } }
    }
    @discardableResult func replyToNotification(_ key: String, actionID: String, text: String) -> Bool {
        guard canReplyToNotification(key, actionID: actionID), NotificationReplyPolicy.validText(text), let peer = active else { return false }
        if notificationReplyResults.count >= 100 { notificationReplyResults = notificationReplyResults.filter { pendingNotificationReplies.contains($0.key) } }
        notificationReplyResults.removeValue(forKey: actionID)
        pendingNotificationReplies.insert(actionID)
        if let index = notifications.firstIndex(where: { $0.id == key }) { notifications[index].actions.removeAll { $0.id == actionID } }
        peer.send(WireMessage("notificationReply", ["key": key, "actionID": actionID, "text": text])) { [weak self] success in
            guard !success, let self, self.pendingNotificationReplies.remove(actionID) != nil else { return }
            self.notificationReplyResults[actionID] = NotificationReplyOutcome(accepted: nil, message: "Connection interrupted. Check the conversation before trying again.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.pendingNotificationReplies.remove(actionID) != nil else { return }
            self.notificationReplyResults[actionID] = NotificationReplyOutcome(accepted: nil, message: "No reply confirmation. Check the conversation before trying again.")
        }
        return true
    }
    private func validLink(_ value: String) -> Bool { value.utf8.count <= 8192 && URLComponents(string: value).map { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil } == true }

    func chooseFile() {
        guard paired != nil else { notice = "Pair your phone first"; return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        sendFiles(panel.urls)
    }
    @discardableResult func sendFiles(_ urls: [URL]) -> Bool {
        guard let paired, let queue = outgoingQueue else { notice = "Pair your phone before queuing files"; return false }
        guard !urls.isEmpty, queue.entries.count + urls.count <= 100 else { notice = QueueError.full.localizedDescription; return false }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !folders.contains($0) }
        do {
            let added = files.isEmpty ? [] : try queue.enqueue(files, deviceID: paired.id, epoch: queueEpoch)
            restoreQueuedTransfers(); scheduleQueuePump()
            showTransferNotice(connected ? "Files added to the send queue" : "Queued for \(paired.name). They’ll send when your phone reconnects.", ids: Set(added.map(\.id)))
        } catch { notice = error.localizedDescription; return false }
        for folder in folders {
            notice = "Preparing folder as a ZIP archive…"
            let preparationID = UUID(), generation = queueGeneration
            folderTasks[preparationID] = Task.detached { [weak self] in
                do {
                    let archive = try FolderArchive.create(folder: folder, cancelled: { Task.isCancelled })
                    await MainActor.run {
                        guard let self, self.queueGeneration == generation, self.paired?.id == paired.id, let queue = self.outgoingQueue else { FolderArchive.remove(archive); return }
                        defer { self.folderTasks.removeValue(forKey: preparationID) }
                        do {
                            let durable = try queue.adoptArchive(archive)
                            let added: [QueuedFile]
                            do { added = try queue.enqueue([durable], deviceID: paired.id, ownedCopy: true, epoch: self.queueEpoch) }
                            catch { FolderArchive.remove(durable); throw error }
                            self.restoreQueuedTransfers(); self.scheduleQueuePump(); self.showTransferNotice("Folder queued as \(durable.lastPathComponent)", ids: Set(added.map(\.id)))
                        } catch { FolderArchive.remove(archive); self.notice = error.localizedDescription }
                    }
                } catch { await MainActor.run { if let self { self.folderTasks.removeValue(forKey: preparationID); if self.queueGeneration == generation { self.notice = error.localizedDescription } } } }
            }
        }
        return true
    }
    @discardableResult func queueImportedFiles(_ urls: [URL]) -> Bool {
        guard let paired, let queue = outgoingQueue, queue.entries.count + urls.count <= 100 else { notice = "Pair your phone and make space in the file queue first"; return false }
        let generation = queueGeneration, preparationID = UUID()
        folderTasks[preparationID] = Task.detached { [weak self] in
            do {
                let copies = try queue.snapshotImports(urls, cancelled: { Task.isCancelled })
                await MainActor.run {
                    guard let self else { copies.forEach(FolderArchive.remove); return }
                    defer { self.folderTasks.removeValue(forKey: preparationID) }
                    guard self.queueGeneration == generation, self.paired?.id == paired.id else { copies.forEach(FolderArchive.remove); return }
                    do { let added = try queue.enqueue(copies, deviceID: paired.id, ownedCopy: true, epoch: self.queueEpoch); self.restoreQueuedTransfers(); self.scheduleQueuePump(); self.showTransferNotice("Shared files added to the send queue", ids: Set(added.map(\.id))) }
                    catch { copies.forEach(FolderArchive.remove); self.notice = error.localizedDescription }
                }
            } catch { await MainActor.run { if let self { self.folderTasks.removeValue(forKey: preparationID); if self.queueGeneration == generation { self.notice = error.localizedDescription } } } }
        }
        notice = "Preparing shared files for your send queue"
        return true
    }
    func sendFile(_ url: URL) { _ = sendFiles([url]) }
    private func restoreQueuedTransfers() {
        guard outgoingQueue != nil else { return }
        queuedFiles = outgoingQueue?.entries.filter { $0.deviceID == paired?.id && $0.epoch == queueEpoch } ?? []
        for entry in queuedFiles where !transfers.contains(where: { $0.id == entry.id }) {
            addTransfer(TransferItem(id: entry.id, name: entry.name, size: entry.size, incoming: false, state: entry.paused ? "Paused" : "Queued", date: entry.created))
        }
    }
    private func scheduleQueuePump() {
        guard !queuePumpScheduled else { return }
        queuePumpScheduled = true
        DispatchQueue.main.async { [weak self] in self?.queuePumpScheduled = false; self?.pumpQueue() }
    }
    private func pumpQueue() {
        guard connected, let deviceID = paired?.id, let queue = outgoingQueue else { return }
        for entry in queue.entries where sending.count < 3 && entry.deviceID == deviceID && entry.epoch == queueEpoch && !entry.paused && entry.retryAfter <= Date() && sending[entry.id] == nil && !suppressedQueueIDs.contains(entry.id) {
            do { startQueuedFile(entry, url: try queue.validateSource(entry)) }
            catch { var failed = entry; failed.paused = true; failed.lastError = error.localizedDescription; try? queue.replace(failed); updateTransfer(entry.id, state: "Paused"); notice = error.localizedDescription }
        }
        queuedFiles = queue.entries.filter { $0.deviceID == deviceID && $0.epoch == queueEpoch }
    }
    private func startQueuedFile(_ entry: QueuedFile, url: URL) {
        let id = entry.id, size = entry.size
        let file = OutgoingFile(url: url, size: size); sending[id] = file
        updateTransfer(id, state: "Preparing", progress: 0)
        file.hashTask = Task.detached {
            do {
                let hash = try TransferRules.hashFile(url, shouldCancel: { Task.isCancelled })
                await MainActor.run {
                    guard self.connected, self.sending[id] === file else { return }
                    file.expectedHash = hash
                    self.updateTransfer(id, state: "Waiting for phone")
                    file.binary = self.active?.supportsBinary == true
                    self.active?.send(WireMessage("fileOffer", ["transferID": id, "name": entry.name, "size": size, "sha256": hash, "encoding": file.binary ? "binary-v1" : "json"]))
                }
            } catch { await MainActor.run { if self.sending[id] === file { self.failTransfer(id, error.localizedDescription) } } }
        }
    }
    func pauseTransfer(_ id: String) {
        guard var entry = outgoingQueue?.entries.first(where: { $0.id == id }) else { return }
        entry.paused = true; suppressedQueueIDs.insert(id)
        do { try outgoingQueue?.replace(entry) } catch { disableFileQueue(error.localizedDescription) }
        active?.send(WireMessage("fileCancel", ["transferID": id])); cleanupOutgoing(id)
        updateTransfer(id, state: "Paused", progress: 0); restoreQueuedTransfers(); scheduleQueuePump()
    }
    func resumeTransfer(_ id: String) {
        guard var entry = outgoingQueue?.entries.first(where: { $0.id == id }) else { return }
        entry.paused = false; entry.attempts = 0; entry.retryAfter = .distantPast; entry.lastError = ""
        do { try outgoingQueue?.replace(entry) } catch { notice = error.localizedDescription; return }
        suppressedQueueIDs.remove(id)
        updateTransfer(id, state: "Queued", progress: 0); restoreQueuedTransfers(); scheduleQueuePump()
    }
    private func suspendQueuedTransfer(_ id: String) {
        cleanupOutgoing(id)
        if let entry = outgoingQueue?.entries.first(where: { $0.id == id }) { updateTransfer(id, state: entry.paused ? "Paused" : "Queued", progress: 0) }
    }
    private func removeQueuedFile(_ id: String) {
        do {
            if let entry = try outgoingQueue?.remove(id) { outgoingQueue?.removeOwnedCopy(entry) }; suppressedQueueIDs.remove(id)
        } catch { disableFileQueue(error.localizedDescription) }
        restoreQueuedTransfers()
    }
    private func disableFileQueue(_ error: String) {
        outgoingQueue?.quarantine(); outgoingQueue = nil
        for id in Array(sending.keys) { active?.send(WireMessage("fileCancel", ["transferID": id])); cleanupOutgoing(id); updateTransfer(id, state: "Paused", progress: 0) }
        notice = "File queue disabled after a storage error. Clear the queue in Settings before using it again. " + error
    }
    func resetFileQueue() {
        for id in Array(sending.keys) { active?.send(WireMessage("fileCancel", ["transferID": id])); cleanupOutgoing(id); updateTransfer(id, state: "Cancelled") }
        do {
            outgoingQueue = try OutgoingQueueStore(resetBlocked: true); suppressedQueueIDs = []
            queuedFiles.forEach { updateTransfer($0.id, state: "Cancelled") }; queuedFiles = []
            notice = "File queue cleared. Your original files were kept."
        } catch { disableFileQueue(error.localizedDescription) }
    }
    private func offer(_ message: WireMessage) {
        let id = message.string("transferID"), name = message.string("name"), size = message.integer("size")
        guard UUID(uuidString: id) != nil, offers[id] == nil, receiving[id] == nil, sending[id] == nil, offers.count + receiving.count < 3,
              (message.string("encoding") != "binary-v1" || active?.supportsBinary == true),
              TransferRules.validName(name), size >= 0, size <= TransferRules.maxBytes, TransferRules.validHash(message.string("sha256")) else { active?.send(WireMessage("fileReject", ["transferID": id])); return }
        if let paired, transferReceipts.matches(peer: paired.id, id: id, name: name, size: size, hash: message.string("sha256")) {
            active?.send(WireMessage("fileReceived", ["transferID": id, "alreadyReceived": true, "sha256": message.string("sha256"), "size": size])); return
        }
        offers[id] = message; addTransfer(TransferItem(id: id, name: name, size: size, incoming: true, state: "Choosing save location"))
        if askWhereToSave {
            saveRequests.append(id)
            showNextSaveLocation()
        } else {
            do {
                let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Bridge", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = try TransferRules.availableDestination(in: folder, name: name, reserved: Set(receiving.values.map { $0.destination }))
                beginReceiving(id, destination: destination)
            } catch { failTransfer(id, error.localizedDescription) }
        }
    }
    func acceptTransfer(_ id: String) {
        guard offers[id] != nil, connected else { return }
        if !saveRequests.contains(id) { saveRequests.append(id) }
        showNextSaveLocation()
    }
    private func showNextSaveLocation() {
        guard savePanel == nil else { return }
        saveRequests.removeAll { offers[$0] == nil }
        guard connected, !saveRequests.isEmpty else { return }
        let id = saveRequests.removeFirst()
        guard let offer = offers[id] else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.nameFieldStringValue = offer.string("name"); panel.title = "Save file from phone"
        panel.prompt = "Save"; panel.canCreateDirectories = true
        savePanel = panel
        savePanelTransferID = id
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.savePanel = nil
                self.savePanelTransferID = nil
                if self.offers[id] != nil {
                    if response == .OK, let destination = panel.url { self.beginReceiving(id, destination: destination) }
                    else { self.cancelTransfer(id) }
                }
                self.showNextSaveLocation()
            }
        }
    }
    private func beginReceiving(_ id: String, destination: URL) {
        guard let offer = offers[id], connected else { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".bridge-" + id + ".partial")
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw WireError.invalidTransfer }
            receiving[id] = IncomingFile(handle: try FileHandle(forWritingTo: temporary), temporary: temporary,
                destination: destination, expectedHash: offer.string("sha256"), size: offer.integer("size"))
            receiving[id]?.binary = offer.string("encoding") == "binary-v1"
            offers.removeValue(forKey: id); updateTransfer(id, state: "Receiving")
            active?.send(WireMessage("fileAccept", ["transferID": id, "encoding": receiving[id]?.binary == true ? "binary-v1" : "json"]))
        } catch { try? FileManager.default.removeItem(at: temporary); failTransfer(id, error.localizedDescription) }
    }
    private func beginSending(_ id: String, binary: Bool = false) {
        guard let file = sending[id], file.handle == nil, file.sendTask == nil else { return }
        if binary {
            guard file.binary, let peer = active, peer.supportsBinary else { failTransfer(id, "Invalid binary negotiation"); return }
            beginBinarySending(id, file: file, peer: peer); return
        }
        file.binary = false
        do { file.handle = try FileHandle(forReadingFrom: file.url); updateTransfer(id, state: "Sending"); sendNextChunk(id) }
        catch { failTransfer(id, error.localizedDescription) }
    }
    private func beginBinarySending(_ id: String, file: OutgoingFile, peer: PeerConnection) {
        updateTransfer(id, state: "Sending")
        file.rateEstimator = TransferRateEstimator(total: file.size, started: ProcessInfo.processInfo.systemUptime)
        file.sendTask = Task.detached {
            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                var sent: Int64 = 0, sequence: Int64 = 0
                let started = ProcessInfo.processInfo.systemUptime
                var lastUI = started
                // Keep up to four ordered 1 MiB batches in flight. Read/encode the
                // next batch while preceding batches drain; memory stays bounded.
                func readBatch() throws -> [BinaryFileChunk] {
                    try Task.checkCancellation()
                    var batch: [BinaryFileChunk] = []
                    for _ in 0..<4 {
                        guard sent < file.size else { break }
                        let count = Int(min(Int64(BinaryFileChunk.maxData), file.size - sent))
                        guard let data = try handle.read(upToCount: count), !data.isEmpty else { throw WireError.invalidTransfer }
                        batch.append(BinaryFileChunk(transferID: id, sequence: sequence, data: data))
                        sent += Int64(data.count); sequence += 1
                    }
                    return batch
                }
                var pending: [(AsyncThrowingStream<Void, Error>, Int64)] = []
                func drainOldest() async throws {
                    let (receipt, submitted) = pending.removeFirst()
                    for try await _ in receipt { }
                    try Task.checkCancellation()
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastUI >= 0.25 || submitted == file.size {
                        let progress = Double(submitted) / Double(max(1, file.size)), speed = Double(submitted) / max(0.001, now - started)
                        await MainActor.run {
                            guard self.sending[id] === file, self.active === peer else { return }
                            if !peer.receiverProgress {
                                self.updateTransfer(id, state: "Sending", progress: progress)
                                if let index = self.transfers.firstIndex(where: { $0.id == id }) { self.transfers[index].bytesPerSecond = speed; self.transfers[index].lastProgressUptime = now }
                            }
                        }
                        lastUI = now
                    }
                }
                while sent < file.size {
                    if pending.count == 4 { try await drainOldest() }
                    let batch = try readBatch()
                    try Task.checkCancellation()
                    let receipt = try await peer.submitBinaryBatch(batch, isActive: { self.sending[id] === file && self.active === peer })
                    pending.append((receipt, sent))
                }
                while !pending.isEmpty { try await drainOldest() }
                try Task.checkCancellation()
                // Verify source length remained stable, preserving integrity semantics.
                guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw WireError.invalidTransfer }
                await MainActor.run {
                    guard self.sending[id] === file, self.active === peer else { return }
                    if peer.receiverProgress {
                        let received = file.rateEstimator?.bytes ?? 0
                        self.updateTransfer(id, state: received == file.size ? "Verifying" : "Finishing")
                    } else { self.updateTransfer(id, state: "Verifying", progress: 1) }
                    peer.send(WireMessage("fileComplete", ["transferID": id]))
                }
            } catch {
                await MainActor.run { if self.sending[id] === file { self.failTransfer(id, error.localizedDescription) } }
            }
        }
    }
    private func receiveBinary(_ peer: PeerConnection, _ chunk: BinaryFileChunk, done: @escaping () -> Void) {
        guard peer.authorized, active === peer, peer.supportsBinary else { peer.close(); done(); return }
        // A cancelled transfer can still have a bounded batch in flight.
        guard let file = receiving[chunk.transferID] else { done(); return }
        guard file.binary else { peer.close(); done(); return }
        fileIOQueue.async {
            let result = Result { try file.appendBinary(chunk) }
            DispatchQueue.main.async {
                defer { done() }
                guard self.receiving[chunk.transferID] === file else { return }
                switch result {
                case .success(let value):
                    let now = ProcessInfo.processInfo.systemUptime
                    if peer.receiverProgress && (now - file.lastReport >= 0.5 || value.0 >= 1) {
                        file.lastReport = now
                        peer.send(WireMessage("fileProgress", ["transferID": chunk.transferID, "receivedBytes": file.received]))
                    }
                    if now - file.lastUI >= 0.25 || value.0 >= 1 {
                        file.lastUI = now
                        self.updateTransfer(chunk.transferID, state: "Receiving", progress: value.0)
                        if let index = self.transfers.firstIndex(where: { $0.id == chunk.transferID }) { self.transfers[index].bytesPerSecond = value.1; self.transfers[index].lastProgressUptime = now }
                    }
                case .failure(let error): self.failTransfer(chunk.transferID, error.localizedDescription)
                }
            }
        }
    }
    private func sendNextChunk(_ id: String) {
        guard let file = sending[id], let handle = file.handle, let active else { return }
        do {
            let data = try handle.read(upToCount: WireMessage.chunkSize) ?? Data()
            if data.isEmpty {
                guard file.sent == file.size else { throw WireError.invalidTransfer }
                active.send(WireMessage("fileComplete", ["transferID": id])); updateTransfer(id, state: "Verifying"); return
            }
            guard file.sent + Int64(data.count) <= file.size else { throw WireError.invalidTransfer }
            let message = WireMessage("fileChunk", ["transferID": id, "sequence": file.sequence, "data": data.base64EncodedString()])
            file.sequence += 1; file.sent += Int64(data.count)
            active.send(message) { [weak self] success in
                guard success else { return }
                self?.updateTransfer(id, state: "Sending", progress: Double(file.sent) / Double(max(1, file.size)))
                self?.sendNextChunk(id)
            }
        } catch { failTransfer(id, error.localizedDescription) }
    }
    private func receiveChunk(_ message: WireMessage) {
        let id = message.string("transferID")
        guard let file = receiving[id], !file.binary else { return }
        guard let data = Data(base64Encoded: message.string("data")), !data.isEmpty, data.count <= WireMessage.chunkSize,
              message.integer("sequence") == file.sequence, file.received + Int64(data.count) <= file.size else { failTransfer(id, "Invalid transfer chunk"); return }
        do {
            try file.handle.write(contentsOf: data); file.hash.update(data: data)
            file.received += Int64(data.count); file.sequence += 1
            updateTransfer(id, state: "Receiving", progress: Double(file.received) / Double(max(1, file.size)))
        } catch { failTransfer(id, error.localizedDescription) }
    }
    private func finishReceiving(_ id: String) {
        guard let file = receiving[id] else { return }
        do {
            let hash = file.hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard file.received == file.size, hash == file.expectedHash else { throw WireError.invalidTransfer }
            try file.handle.close()
            // Preserve an existing file; choose another destination instead of overwriting it.
            try FileManager.default.moveItem(at: file.temporary, to: file.destination)
            receiving.removeValue(forKey: id)
            updateTransfer(id, state: "Complete", progress: 1)
            if let index = transfers.firstIndex(where: { $0.id == id }) { transfers[index].destination = file.destination }
            automation.emit(.fileReceived, context: "File received from your phone")
            systemNotification("File received from phone", body: file.destination.lastPathComponent + " · Click to open", id: "bridge.transfer." + id, category: "bridge.file", metadata: ["transferID": id])
            if let paired, let name = transfers.first(where: { $0.id == id })?.name { transferReceipts.record(peer: paired.id, id: id, name: name, size: file.size, hash: file.expectedHash) }
            active?.send(WireMessage("fileReceived", ["transferID": id]))
        } catch { failTransfer(id, error.localizedDescription) }
    }
    func cancelTransfer(_ id: String, send: Bool = true) {
        clearTransferNotice(id)
        if outgoingQueue?.entries.contains(where: { $0.id == id }) == true { suppressedQueueIDs.insert(id) }
        saveRequests.removeAll { $0 == id }
        if savePanelTransferID == id { savePanel?.cancel(nil) }
        if send { active?.send(WireMessage("fileCancel", ["transferID": id])) }
        offers.removeValue(forKey: id)
        if let file = receiving.removeValue(forKey: id) { fileIOQueue.async { file.cancel() } }
        cleanupOutgoing(id); removeQueuedFile(id); updateTransfer(id, state: "Cancelled"); scheduleQueuePump()
    }
    private func failTransfer(_ id: String, _ error: String) {
        if let original = outgoingQueue?.entries.first(where: { $0.id == id }) {
            active?.send(WireMessage("fileCancel", ["transferID": id])); cleanupOutgoing(id)
            let entry: QueuedFile
            do { entry = try outgoingQueue?.recordFailure(id, reason: error) ?? original }
            catch { disableFileQueue(error.localizedDescription); return }
            updateTransfer(id, state: entry.paused ? "Paused" : "Retrying", progress: 0); restoreQueuedTransfers(); scheduleQueuePump()
            notice = entry.paused ? "\(entry.name) paused after three failed attempts. Retry or remove it in Activity." : "\(entry.name) will retry automatically. \(error)"
        } else {
            let wasReceiving = offers[id] != nil || receiving[id] != nil
            cancelTransfer(id, send: false)
            if wasReceiving { active?.send(WireMessage(active?.supportsTransferFailure == true ? "fileFailed" : "fileReject", ["transferID": id, "reason": String(error.prefix(240))])) }
            updateTransfer(id, state: "Failed"); notice = error
        }
        systemNotification("File transfer interrupted", body: String(error.prefix(240)), id: "bridge.transfer." + id)
    }
    private func cleanupOutgoing(_ id: String) { if let file = sending.removeValue(forKey: id) { file.hashTask?.cancel(); file.sendTask?.cancel(); try? file.handle?.close() } }
    private func addTransfer(_ transfer: TransferItem) {
        if transfers.count >= 50 { transfers.removeAll { ["Complete", "Cancelled", "Failed"].contains($0.state) } }
        transfers.insert(transfer, at: 0)
    }
    private func updateTransfer(_ id: String, state: String, progress: Double? = nil) {
        if let index = transfers.firstIndex(where: { $0.id == id }) { if transfers[index].state != state { clearTransferNotice(id) }; transfers[index].state = state; if let progress { transfers[index].progress = progress } }
    }
}
