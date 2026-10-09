import AppIntents
import Foundation

private struct BridgeIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor private func connectedBridge() throws -> BridgeModel {
    guard let model = BridgeRuntime.model else {
        throw BridgeIntentError(message: "Open Bridge and try the shortcut again.")
    }
    guard model.connected else {
        throw BridgeIntentError(message: "Connect your paired phone to Bridge before running this shortcut.")
    }
    return model
}

struct RingPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Ring My Phone"
    static var description = IntentDescription("Ring your connected phone for up to 30 seconds. Your phone’s sound settings are respected.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try connectedBridge()
        if !model.ringing { model.ringPhone() }
        return .result(dialog: "Ring requested on your phone.")
    }
}

struct StopRingingPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Ringing My Phone"
    static var description = IntentDescription("Stop a phone ring started by Bridge.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        let model = try connectedBridge()
        if model.ringing { model.ringPhone() }
        return .result()
    }
}

struct SendTextToPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Text to Phone"
    static var description = IntentDescription("Send text to your paired phone’s clipboard. Sensitive content requires confirmation in Bridge.")
    static var openAppWhenRun = true
    @Parameter(title: "Text") var text: String
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to my phone") }

    @MainActor func perform() async throws -> some IntentResult {
        let model = try connectedBridge()
        guard model.sendSelectedText(text, manual: true) else { throw BridgeIntentError(message: model.notice) }
        return .result()
    }
}

struct SendLinkToPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Link to Phone"
    static var description = IntentDescription("Send an HTTP or HTTPS link to your paired phone. The phone shows a notification to open it.")
    static var openAppWhenRun = true
    @Parameter(title: "Link") var link: URL
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$link) to my phone") }

    @MainActor func perform() async throws -> some IntentResult {
        let model = try connectedBridge()
        guard model.sendWebLink(link.absoluteString) else { throw BridgeIntentError(message: model.notice) }
        return .result()
    }
}

struct PhoneBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Phone Battery"
    static var description = IntentDescription("Return your connected phone’s current battery percentage.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let model = try connectedBridge()
        guard let battery = model.battery else { throw BridgeIntentError(message: "Phone battery status is not available yet. Try again in a moment.") }
        return .result(value: battery, dialog: "Your phone battery is at \(battery) percent.")
    }
}

struct PauseSendQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Bridge Send Queue"
    static var description = IntentDescription("Pause outgoing queued files. Interrupted files restart from the beginning when resumed.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        guard let model = BridgeRuntime.model else { throw BridgeIntentError(message: "Open Bridge first.") }
        model.queuedFiles.filter { !$0.paused }.map(\.id).forEach { model.pauseTransfer($0) }
        return .result()
    }
}
struct ResumeSendQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Bridge Send Queue"
    static var description = IntentDescription("Resume paused queued files. Files send when your paired phone connects.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        guard let model = BridgeRuntime.model else { throw BridgeIntentError(message: "Open Bridge first.") }
        model.queuedFiles.filter { $0.paused }.map(\.id).forEach { model.resumeTransfer($0) }
        return .result()
    }
}
struct BridgeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PauseSendQueueIntent(), phrases: ["Pause sending with \(.applicationName)"], shortTitle: "Pause Queue", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeSendQueueIntent(), phrases: ["Resume sending with \(.applicationName)"], shortTitle: "Resume Queue", systemImageName: "play.circle")
        AppShortcut(intent: RingPhoneIntent(), phrases: ["Ring my phone with \(.applicationName)"],
                    shortTitle: "Ring My Phone", systemImageName: "bell.badge")
        AppShortcut(intent: PhoneBatteryIntent(), phrases: ["Check my phone battery with \(.applicationName)"],
                    shortTitle: "Phone Battery", systemImageName: "battery.100percent")
        AppShortcut(intent: SendTextToPhoneIntent(), phrases: ["Send text to my phone with \(.applicationName)"],
                    shortTitle: "Send Text", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: SendLinkToPhoneIntent(), phrases: ["Send a link to my phone with \(.applicationName)"],
                    shortTitle: "Send Link", systemImageName: "link")
    }
}
