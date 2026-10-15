import SwiftUI
import AppKit

// A finite, deterministic command vocabulary. Input is never interpreted as
// code, a shell command or a remote request; execution calls existing actions.
enum BridgeCommandIntent: String, CaseIterable, Identifiable {
    case sendFiles = "send files"
    case clipboard = "copy to phone"
    case ring = "ring phone"
    case pause = "pause queue"
    case resume = "resume queue"
    var id: String { rawValue }
    static func parse(_ phrase: String) -> Self? {
        Self(rawValue: phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    var preview: String {
        switch self {
        case .sendFiles: return "Open a file chooser. The files you select will be added to your paired phone’s send queue."
        case .clipboard: return "Read the Mac clipboard and send its text to your connected phone. Bridge’s sensitive-text confirmation still applies."
        case .ring: return "Start ringing your connected phone. An already ringing phone keeps ringing."
        case .pause: return "Pause every current outgoing queued transfer. Transfers already in progress restart from the beginning when resumed."
        case .resume: return "Resume all paused outgoing queued transfers to your paired phone."
        }
    }
}

private enum SearchKind: String, CaseIterable, Identifiable {
    case all = "All", files = "Files", notifications = "Notifications", clipboard = "Clipboard", links = "Links"
    var id: String { rawValue }
}
private enum SearchSource: String, CaseIterable, Identifiable {
    case all = "All sources", mac = "This Mac", phone = "Phone"
    var id: String { rawValue }
}
private enum SearchTime: String, CaseIterable, Identifiable {
    case all = "All retained", day = "Past 24 hours", week = "Past 7 days"
    var id: String { rawValue }
    var interval: TimeInterval? {
        switch self { case .all: return nil; case .day: return 86400; case .week: return 604800 }
    }
}

struct BridgeSearchView: View {
    @ObservedObject var model: BridgeModel
    @StateObject private var ui = SearchUIState()
    private func matches(_ text: String, date: Date, fromMac: Bool) -> Bool {
        let needle = ui.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty || text.localizedStandardContains(needle) else { return false }
        guard ui.source == .all || (ui.source == .mac) == fromMac else { return false }
        if let interval = ui.time.interval, Date().timeIntervalSince(date) > interval { return false }
        return true
    }
    private var files: [TransferItem] {
        guard ui.kind == .all || ui.kind == .files else { return [] }
        return model.transfers.filter { matches($0.name, date: $0.date, fromMac: !$0.incoming) }
    }
    private var notifications: [PhoneNotification] {
        guard ui.kind == .all || ui.kind == .notifications else { return [] }
        return model.notifications.filter { matches("\($0.app) \($0.title) \($0.body)", date: $0.date, fromMac: false) }
    }
    private var clipboard: [ClipboardHistoryEntry] {
        guard model.clipboardHistoryEnabled, ui.kind == .all || ui.kind == .clipboard else { return [] }
        return model.clipboardHistory.entries.filter { matches($0.text, date: $0.date, fromMac: $0.sourceID == "mac") }
    }
    private var link: LinkHandoff? {
        guard ui.kind == .all || ui.kind == .links, let value = model.incomingHandoff, !value.expired(),
              matches("\(value.title) \(value.url.absoluteString)", date: value.expiresAt.addingTimeInterval(-600), fromMac: false) else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search & commands").font(.largeTitle.bold())
            Text("Find retained Bridge activity on this Mac. Searches stay local.").foregroundStyle(.secondary)
            TextField("Search filenames, notifications, saved clipboard text and the current link", text: $ui.query)
                .textFieldStyle(.roundedBorder)
            BridgeFlowLayout {
                Picker("Type", selection: $ui.kind) { ForEach(SearchKind.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Source", selection: $ui.source) { ForEach(SearchSource.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Time", selection: $ui.time) { ForEach(SearchTime.allCases) { Text($0.rawValue).tag($0) } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: BridgeUI.spacing) {
                    ForEach(files) { file in
                        resultCard(icon: "doc", title: file.name, detail: "\(file.incoming ? "From phone" : "From Mac") · \(file.state)") {
                            if canOpen(file) { Button("Open saved file") { open(file) } }
                        }
                    }
                    ForEach(notifications) { notification in
                        resultCard(icon: "bell", title: "\(notification.displayApp) · \(notification.title)", detail: notification.body) {
                            BridgeFlowLayout {
                                ForEach(notification.actions.filter { !$0.isReply }) { action in
                                    BridgeNotificationActionButton(action: action) { model.performNotificationAction(notification.id, actionID: action.id) }
                                }
                                Button("Dismiss on phone") { model.dismissNotification(notification.id) }
                            }.disabled(!model.connected)
                        }
                    }
                    ForEach(clipboard) { entry in
                        resultCard(icon: "doc.on.clipboard", title: "Clipboard · \(entry.sourceName)", detail: String(entry.text.prefix(500))) {
                            Button("Copy text") { model.copyHistoryEntry(entry) }
                        }
                    }
                    if let handoff = link {
                        resultCard(icon: "link", title: handoff.title, detail: handoff.url.absoluteString) {
                            Button("Open link") { model.openReceivedLink() }
                        }
                    }
                    if files.isEmpty && notifications.isEmpty && clipboard.isEmpty && link == nil {
                        Text("No matching retained activity.").foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
            DisclosureGroup("Search scope & privacy") {
                Text("Search covers filenames, retained notifications, the current unexpired incoming link, and safe clipboard history when enabled. It does not scan file contents, index your phone or retain a separate search database.").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            Divider()
            commandPalette
        }.frame(maxWidth: BridgeUI.contentWidth).padding(BridgeUI.margin)
            .frame(maxWidth: .infinity).frame(minWidth: 540, minHeight: 600)
            .safeAreaInset(edge: .bottom, spacing: 0) { BridgeFeedbackBar(model: model) }
    }
    @ViewBuilder private func resultCard<Actions: View>(icon: String, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(bridgeSymbol: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                BridgeSelectableText(text: title, semibold: true, lineLimit: 2).help(title)
                BridgeSelectableText(text: detail, secondary: true, lineLimit: 5)
                actions()
            }
            Spacer(minLength: 0)
        }.bridgeCard()
    }
    private var commandPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commands").font(.headline)
            TextField("Try “send files”, “copy to phone”, “ring phone”, “pause queue” or “resume queue”", text: $ui.command)
                .textFieldStyle(.roundedBorder).onChange(of: ui.command) { _ in ui.commandStatus = "" }
            if let intent = BridgeCommandIntent.parse(ui.command) {
                HStack(alignment: .top) {
                    Text(intent.preview).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Execute") { execute(intent) }.disabled(!canExecute(intent))
                }
            } else if !ui.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Choose one of the five supported phrases above. Commands are deterministic; this is not an AI assistant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !ui.commandStatus.isEmpty { Text(ui.commandStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func canOpen(_ file: TransferItem) -> Bool {
        guard file.state == "Complete", let url = file.destination, url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
    private func open(_ file: TransferItem) {
        guard canOpen(file), let destination = file.destination else { return }
        if !NSWorkspace.shared.open(destination) { model.notice = "Could not open this saved file." }
    }
    private func canExecute(_ intent: BridgeCommandIntent) -> Bool {
        switch intent {
        case .sendFiles: return model.paired != nil
        case .clipboard, .ring: return model.connected
        case .pause: return model.queuedFiles.contains { !$0.paused }
        case .resume: return model.queuedFiles.contains { $0.paused }
        }
    }
    private func execute(_ intent: BridgeCommandIntent) {
        guard canExecute(intent) else { return }
        switch intent {
        case .sendFiles: model.chooseFile(); ui.commandStatus = "File chooser finished. Check the transfer queue for selected files."
        case .clipboard: model.sendClipboard(); ui.commandStatus = model.notice
        case .ring:
            if !model.ringing { model.ringPhone() }
            ui.commandStatus = "Requested phone ringing."
        case .pause:
            let ids = model.queuedFiles.filter { !$0.paused }.map(\.id)
            ids.forEach { model.pauseTransfer($0) }; ui.commandStatus = "Pause requested for \(ids.count) queued file(s)."
        case .resume:
            let ids = model.queuedFiles.filter { $0.paused }.map(\.id)
            ids.forEach { model.resumeTransfer($0) }; ui.commandStatus = "Resume requested for \(ids.count) queued file(s)."
        }
    }
}

@MainActor private final class SearchUIState: ObservableObject {
    @Published var query = ""
    @Published var kind = SearchKind.all
    @Published var source = SearchSource.all
    @Published var time = SearchTime.all
    @Published var command = ""
    @Published var commandStatus = ""
}
