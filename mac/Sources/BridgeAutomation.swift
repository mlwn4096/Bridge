import Foundation
import Combine
import UserNotifications

enum BridgeAutomationEvent: String, Codable, CaseIterable, Identifiable {
    case phoneConnected, phoneDisconnected, fileReceived, lowBattery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .phoneConnected: return "Phone connected"
        case .phoneDisconnected: return "Phone disconnected"
        case .fileReceived: return "File received"
        case .lowBattery: return "Phone battery is low"
        }
    }
}

enum BridgeAutomationAction: String, Codable, CaseIterable, Identifiable {
    case notification, shortcut
    var id: String { rawValue }
    var title: String { self == .notification ? "Show a notification" : "Run a Mac Shortcut" }
}

struct BridgeAutomationRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = false
    var event: BridgeAutomationEvent = .phoneConnected
    var action: BridgeAutomationAction = .notification
    var shortcutName = ""
    var cooldownSeconds: TimeInterval = 60

    static func validShortcutName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.utf8.count <= 512 &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var isValid: Bool {
        cooldownSeconds.isFinite && cooldownSeconds >= 60 && cooldownSeconds <= 86_400 &&
        (action != .shortcut || Self.validShortcutName(shortcutName))
    }
    func matches(_ incoming: BridgeAutomationEvent, now: TimeInterval, lastRun: TimeInterval?) -> Bool {
        enabled && isValid && event == incoming && now.isFinite &&
        (lastRun == nil || now - lastRun! >= cooldownSeconds)
    }
}

/// Executes only new local events after explicit configuration; never stores event payloads.
@MainActor
final class BridgeAutomation: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var rules: [BridgeAutomationRule]
    @Published private(set) var shortcutNames: [String] = []
    @Published private(set) var loadingShortcuts = false
    @Published private(set) var status = "Automations are off by default."
    private let defaults: UserDefaults
    private var lastRuns: [UUID: TimeInterval] = [:]
    private var runningShortcut = false
    private static let rulesKey = "bridge.automation.rules.v1"
    private static let enabledKey = "bridge.automation.enabled.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        if let data = defaults.data(forKey: Self.rulesKey),
           let saved = try? JSONDecoder().decode([BridgeAutomationRule].self, from: data),
           saved.count <= 8, Set(saved.map(\.id)).count == saved.count,
           saved.allSatisfy({ !$0.enabled || $0.isValid }) {
            rules = saved
        } else { rules = []; enabled = false }
    }

    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        status = value ? "Only future matching events run configured rules." : "Automations are off."
    }
    func addRule() {
        guard rules.count < 8 else { return }
        rules.append(BridgeAutomationRule()); persist()
    }
    func update(_ rule: BridgeAutomationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var checked = rule
        if checked.enabled && !checked.isValid { checked.enabled = false }
        rules[index] = checked; persist()
    }
    func remove(_ id: UUID) { rules.removeAll { $0.id == id }; lastRuns.removeValue(forKey: id); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Self.rulesKey) }
    }

    /// Context is local, optional, and never passed to Shortcuts. Omit secrets and clipboard text.
    func emit(_ event: BridgeAutomationEvent, context: String = "") {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for rule in rules where rule.matches(event, now: now, lastRun: lastRuns[rule.id]) {
            lastRuns[rule.id] = now
            switch rule.action {
            case .notification:
                let safeContext = String(context.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
                Task {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    guard enabled, rules.contains(where: { $0.id == rule.id && $0.enabled }),
                          settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
                    let content = UNMutableNotificationContent()
                    content.title = "Bridge · \(event.title)"
                    content.body = safeContext
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bridge.automation.\(rule.id).\(UUID())", content: content, trigger: nil))
                }
                status = "Handled \(event.title.lowercased())."
            case .shortcut:
                guard !runningShortcut else { status = "A Shortcut is already running; this event was skipped."; continue }
                runningShortcut = true
                let name = rule.shortcutName
                Task {
                    guard enabled, rules.contains(where: { $0.id == rule.id && $0.enabled }) else { runningShortcut = false; return }
                    do {
                        _ = try await Self.runShortcuts(arguments: ["run", name], captureOutput: false)
                        status = "Ran \(name)."
                    } catch { status = error.localizedDescription }
                    runningShortcut = false
                }
            }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
    func refreshShortcuts() {
        guard !loadingShortcuts else { return }
        loadingShortcuts = true
        Task {
            defer { loadingShortcuts = false }
            do {
                let output = try await Self.runShortcuts(arguments: ["list"], captureOutput: true)
                shortcutNames = Array(Set(output.split(separator: "\n").map(String.init).filter(BridgeAutomationRule.validShortcutName))).sorted()
                status = shortcutNames.isEmpty ? "No Mac Shortcuts found. Create one in Shortcuts, then refresh." : "Choose a Shortcut to run for future events."
            } catch { status = error.localizedDescription }
        }
    }

    private nonisolated static func runShortcuts(arguments: [String], captureOutput: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Bridge-Shortcuts-\(UUID().uuidString)")
                    let output: FileHandle
                    if captureOutput {
                        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AutomationError.failed }
                        output = try FileHandle(forWritingTo: file)
                    } else { output = .nullDevice }
                    defer { if captureOutput { try? output.close(); try? FileManager.default.removeItem(at: file) } }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run()
                    let deadline = ProcessInfo.processInfo.systemUptime + 30
                    while process.isRunning {
                        if ProcessInfo.processInfo.systemUptime >= deadline {
                            process.terminate()
                            let grace = ProcessInfo.processInfo.systemUptime + 1
                            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.05) }
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            process.waitUntilExit(); throw AutomationError.timeout
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw AutomationError.failed }
                    var result = ""
                    if captureOutput {
                        try output.synchronize()
                        let input = try FileHandle(forReadingFrom: file)
                        defer { try? input.close() }
                        guard let data = try input.read(upToCount: 131_073), data.count <= 131_072,
                              let text = String(data: data, encoding: .utf8) else { throw AutomationError.failed }
                        result = text
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private enum AutomationError: LocalizedError {
        case failed, timeout
        var errorDescription: String? {
            self == .timeout ? "Shortcut timed out after 30 seconds." : "Shortcuts could not complete this request. Check the Shortcut in the Shortcuts app."
        }
    }
}
