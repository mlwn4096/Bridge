import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement

@main
struct BridgeApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(BridgeApplicationDelegate.self) private var appDelegate
    @StateObject private var model: BridgeModel
    @AppStorage(BridgeDownloads.completedKey) private var companionInstallCompleted = false
    init() {
        // usernoted can capture the sender icon on the first notification-center
        // lookup. Set it before BridgeModel queries settings or authorization,
        // rather than waiting for applicationDidFinishLaunching.
        if let iconURL = Bundle.main.url(forResource: "BridgeLauncherIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        _model = StateObject(wrappedValue: BridgeModel())
    }
    private static let menuIcon: NSImage = {
        let image = Bundle.main.url(forResource: "BridgeMenuIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "link", accessibilityDescription: "Bridge")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
    var body: some Scene {
        MenuBarExtra {
            BridgePopover().environmentObject(model)
                .background(BridgeMenuPanelCapture())
        } label: {
            Image(nsImage: Self.menuIcon)
                .renderingMode(.template)
                .help("Bridge — \(model.status)")
                .accessibilityLabel("Bridge, \(model.status)")
                .onAppear {
                    BridgeApplicationDelegate.openMainWindow = { BridgeWindows.open("bridge", using: openWindow) }
                    BridgeApplicationDelegate.openSettingsWindow = { BridgeWindows.open("settings", using: openWindow) }
                    if !BridgeApplicationDelegate.setupPresentedThisLaunch && !companionInstallCompleted && model.paired == nil {
                        BridgeApplicationDelegate.setupPresentedThisLaunch = true
                        DispatchQueue.main.async { BridgeWindows.open("setup", using: openWindow) }
                    }
                }
        }.menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { BridgeApplicationDelegate.showSettings() }.keyboardShortcut(",")
            }
        }
        if #available(macOS 15.0, *) {
            Window("Welcome to Bridge", id: "setup") { BridgeSetupWindow().environmentObject(model) }
                .defaultSize(width: 520, height: 680).defaultLaunchBehavior(.suppressed)
            Window("General", id: "settings") { BridgePreferences().environmentObject(model) }
                .defaultSize(width: 860, height: 610).defaultLaunchBehavior(.suppressed)
            Window("Developer tools", id: "developer") { DeveloperToolsView(bridgeConnected: model.connected) }.defaultSize(width: 900, height: 640).defaultLaunchBehavior(.suppressed)
            Window("Bridge", id: "bridge") {
                BridgeWindow().environmentObject(model)
                    .onAppear { BridgeApplicationDelegate.openMainWindow = { BridgeWindows.open("bridge", using: openWindow) } }
            }.defaultSize(width: 920, height: 680)
            .defaultLaunchBehavior(.suppressed)
        }
    }
}

struct BridgePopover: View {
    @AppStorage(BridgeDownloads.completedKey) private var companionInstallCompleted = false
    @StateObject private var ui = PopoverUIState()
    @EnvironmentObject var model: BridgeModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(bridgeSymbol: "iphone.gen3").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.paired?.name ?? "Bridge").font(.headline)
                    Label(model.status, systemImage: model.connected ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption).foregroundStyle(model.connected ? .green : .secondary)
                }
                Spacer()
                if let battery = model.battery {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            if model.batterySaver {
                                Image(bridgeSymbol: "leaf.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                                    .help("Battery Saver is on").accessibilityLabel("Battery Saver on")
                            }
                            BridgeBatteryIcon(level: battery, charging: model.charging, saver: model.batterySaver)
                        }
                        Text("\(battery)%").font(.caption.monospacedDigit())
                    }
                }
            }
            Divider()
            if model.pairingKeyBlocked {
                Button("Unlock pairing key…", systemImage: "lock.open") { model.unlockPairingKey() }
                    .buttonStyle(.borderedProminent)
            }
            if let request = model.pairingRequest {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Pair with \(request.name)?", systemImage: "lock.shield").font(.headline)
                    Text("Only approve the phone on which you just scanned this Mac’s QR code.").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Decline", role: .cancel) { model.rejectPairing() }; Spacer(); Button("Pair") { model.confirmPairing() }.buttonStyle(.borderedProminent) }
                }
            } else if model.paired == nil {
                if !companionInstallCompleted {
                    BridgeCompanionDownload(compact: true)
                } else {
                Text("Your Mac. Your Android. Together.").font(.headline)
                Text("Open Bridge on your phone and scan this code to connect securely over Wi-Fi.").font(.callout).foregroundStyle(.secondary)
                PairingView()
                }
            } else {
                Text("Quick actions").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    action("Send clipboard", icon: "doc.on.clipboard") { model.sendClipboard() }.disabled(!model.connected)
                    action(model.connected ? "Send files" : "Queue files", icon: "arrow.up.doc") { model.chooseFile() }
                    action(model.ringing ? "Stop ringing" : "Ring phone", icon: model.ringing ? "speaker.slash" : "bell.badge") { model.ringPhone() }.disabled(!model.connected)
                    action("Clipboard history", icon: "clock.arrow.circlepath") { BridgeApplicationDelegate.showPage("clipboard") }
                }.frame(maxWidth: .infinity)
                if !model.queuedFiles.isEmpty { Button("\(model.queuedFiles.count) files in send queue", systemImage: "tray.full") { BridgeApplicationDelegate.showPage("transfers") }.font(.caption) }
                if model.mediaAvailable {
                    Divider()
                    BridgeMediaControls().environmentObject(model)
                }
                if model.incomingHandoff != nil { BridgeHandoffCard().environmentObject(model) }
                if model.transfers.contains(where: { $0.state == "Accept to receive" }) {
                    Button("A file is waiting for approval", systemImage: "arrow.down.doc") { BridgeApplicationDelegate.showPage("transfers") }
                }
            }
            let activeOutgoing = model.transfers.filter { !$0.incoming && ["Preparing", "Waiting for phone", "Sending", "Finishing", "Verifying"].contains($0.state) }
            if !activeOutgoing.isEmpty {
                Divider()
                ForEach(Array(activeOutgoing.prefix(3))) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.cancelTransfer(item.id) } label: { Image(bridgeSymbol: "xmark.circle") }.buttonStyle(.plain).help("Cancel transfer")
                        }
                        if ["Sending", "Finishing"].contains(item.state) { ProgressView(value: item.progress); TransferMetricsCaption(item: item) }
                        else { Text(item.state).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !model.notice.isEmpty {
                HStack(alignment: .top) {
                    Text(model.notice).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(); Button { model.notice = "" } label: { Image(bridgeSymbol: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }
            }
            Divider()
            HStack {
                Button("Settings", systemImage: "gearshape") { BridgeApplicationDelegate.showSettings() }.buttonStyle(.bordered)
                Spacer()
                Button { ui.confirmQuit = true } label: {
                    Label("Quit", systemImage: "power").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red).padding(.horizontal, 10).frame(height: 32)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).help("Quit Bridge").accessibilityLabel("Quit Bridge")
                .popover(isPresented: $ui.confirmQuit, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quit Bridge?").font(.headline)
                        Text("Your phone will disconnect and active transfers will stop.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel") { ui.confirmQuit = false }.keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("Quit Bridge", role: .destructive) { NSApp.terminate(nil) }
                        }.buttonStyle(.bordered)
                    }.padding(16).frame(width: 260)
                }
            }.font(.callout)
        }.padding(20).frame(width: 380)
    }
    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 10) {
                Image(bridgeSymbol: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(.tint)
                Text(title).font(.callout.weight(.medium)).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 76).padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct BridgeBatteryIcon: View {
    let level: Int
    let charging: Bool
    let saver: Bool
    private var tint: Color { level <= 20 ? .red : (saver ? .yellow : (charging ? .green : .primary)) }
    private var fraction: CGFloat { CGFloat(max(0, min(100, level))) / 100 }
    var body: some View {
        HStack(spacing: 1) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.18))
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tint.opacity(0.65), lineWidth: 1)
                HStack(spacing: 0) {
                    Rectangle().fill(tint).frame(width: 22 * fraction)
                    Spacer(minLength: 0)
                }.frame(width: 22, height: 8).clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                if charging {
                    Image(bridgeSymbol: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.primary)
                        .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1)
                }
            }.frame(width: 26, height: 12)
            Capsule().fill(tint.opacity(0.65)).frame(width: 2, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level)% battery" + (charging ? ", charging" : "") + (saver ? ", Battery Saver on" : ""))
        .help(saver ? "Battery Saver is on" : (charging ? "Charging" : "On battery"))
    }
}

struct BridgeNotificationRow: View {
    @EnvironmentObject var model: BridgeModel
    let notification: PhoneNotification
    var showApp = true
    @StateObject private var ui = NotificationRowState()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showApp { BridgePhoneAppIcon(data: notification.appIconPNG); Text(notification.displayApp).font(.caption.weight(.medium)).lineLimit(1).help(notification.displayApp) }
                Text(notification.date, style: .time).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { model.dismissNotification(notification.id) } label: { Image(bridgeSymbol: "xmark") }
                    .buttonStyle(.plain).help("Dismiss on phone").accessibilityLabel("Dismiss on phone").disabled(!model.connected)
            }
            Text(notification.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !notification.body.isEmpty { BridgeSelectableText(text: notification.body, secondary: true, lineLimit: 4) }
            if !notification.actions.isEmpty {
                BridgeFlowLayout {
                    ForEach(notification.actions) { action in
                        if action.isReply {
                            Button(action.title) { ui.replyAction = action }.help("Reply from your Mac")
                        } else {
                            BridgeNotificationActionButton(action: action) { model.performNotificationAction(notification.id, actionID: action.id) }
                        }
                    }
                }.controlSize(.small).disabled(!model.connected)
            }
        }.bridgeCard()
        .sheet(item: $ui.replyAction) { action in
            BridgeNotificationReplyComposer(notification: notification, action: action).environmentObject(model)
        }
    }
}

struct BridgeNotificationReplyComposer: View {
    @EnvironmentObject var model: BridgeModel
    @Environment(\.dismiss) private var dismiss
    let notification: PhoneNotification
    let action: PhoneNotificationAction
    @StateObject private var ui = NotificationReplyComposerState()
    private var outcome: NotificationReplyOutcome? { model.notificationReplyResults[action.id] }
    private var available: Bool { model.canReplyToNotification(notification.id, actionID: action.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reply in \(notification.displayApp)").font(.title2.bold())
            Text(notification.title).font(.headline).lineLimit(3)
            if !notification.body.isEmpty { Text(notification.body).foregroundStyle(.secondary).lineLimit(4) }
            Text(action.placeholder.isEmpty ? "Your reply" : action.placeholder).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $ui.text).frame(minHeight: 110, maxHeight: 180)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel("Reply text").disabled(ui.submitted)
            Text("\(ui.text.utf8.count)/\(NotificationReplyPolicy.maxBytes) bytes").font(.caption).foregroundStyle(.secondary)
            if ui.submitted {
                Text(outcome?.message ?? "Handing reply to your phone…").foregroundStyle(.secondary)
            } else if !available {
                Text("This reply is no longer available. Connect your phone, enable previews, or open the latest notification.").foregroundStyle(.secondary)
            } else if !ui.localError.isEmpty { Text(ui.localError).foregroundStyle(.secondary) }
            Text("Keep your phone unlocked. Send hands your reply to the phone app; delivery depends on that app.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(ui.submitted ? "Done" : "Cancel") { ui.text = ""; dismiss() }.keyboardShortcut(.cancelAction)
                if !ui.submitted {
                    Button("Send") {
                        if model.replyToNotification(notification.id, actionID: action.id, text: ui.text) { ui.submitted = true }
                        else { ui.localError = "Reply unavailable. Refresh notifications and try again." }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!available || !NotificationReplyPolicy.validText(ui.text))
                }
            }
        }.padding(24).frame(width: 460)
        .onChange(of: model.connected) { connected in if !connected { ui.text = ""; dismiss() } }
        .onChange(of: model.notificationPreviews) { enabled in if !enabled { ui.text = ""; dismiss() } }
        .onChange(of: model.mirrorNotifications) { enabled in if !enabled { ui.text = ""; dismiss() } }
    }
}

@MainActor final class NotificationRowState: ObservableObject { @Published var replyAction: PhoneNotificationAction? }
@MainActor final class NotificationReplyComposerState: ObservableObject {
    @Published var text = ""
    @Published var submitted = false
    @Published var localError = ""
}

struct BridgeMediaControls: View {
    @EnvironmentObject var model: BridgeModel
    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Text(model.mediaTitle.isEmpty ? "Phone media" : model.mediaTitle).font(.headline).lineLimit(2)
                if !model.mediaArtist.isEmpty { Text(model.mediaArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity)
            HStack(spacing: 16) {
                control("Volume down", icon: "speaker.minus", action: "volumeDown")
                control("Previous", icon: "backward.end.fill", action: "previous").disabled(!model.mediaActions.contains("previous"))
                control(model.mediaPlaying ? "Pause" : "Play", icon: model.mediaPlaying ? "pause.fill" : "play.fill", action: model.mediaPlaying ? "pause" : "play")
                    .disabled(!model.mediaActions.contains(model.mediaPlaying ? "pause" : "play"))
                control("Next", icon: "forward.end.fill", action: "next").disabled(!model.mediaActions.contains("next"))
                control("Volume up", icon: "speaker.plus", action: "volumeUp")
            }.frame(maxWidth: .infinity).disabled(!model.connected)
        }
    }
    private func control(_ title: String, icon: String, action: String) -> some View {
        Button { model.mediaCommand(action) } label: {
            Label(title, systemImage: icon).labelStyle(.iconOnly).frame(width: 28, height: 28)
        }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}

struct PairingView: View {
    @EnvironmentObject var model: BridgeModel
    var body: some View {
        VStack(spacing: 10) {
            if let image = qrImage(model.pairingURL) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 196, height: 196).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Pairing QR code")
                Text("Same Wi-Fi · Encrypted pairing").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh code", systemImage: "arrow.clockwise") { model.refreshPairing() }
                    Button("Copy pairing link", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairingURL, forType: .string) }
                }.font(.caption)
            } else { ProgressView().padding(); Text("Waiting for local network access…").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity)
    }
    private func qrImage(_ value: String) -> NSImage? {
        guard !value.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

struct BridgeWindow: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var model: BridgeModel
    @StateObject private var ui: WindowUIState
    private let activatesApplication: Bool
    init(initialSelection: String = "devices", activatesApplication: Bool = true) {
        _ui = StateObject(wrappedValue: WindowUIState(selection: initialSelection))
        self.activatesApplication = activatesApplication
    }
    var body: some View {
        mainWindow
        .onReceive(NotificationCenter.default.publisher(for: .bridgeShowSettings)) { _ in ui.selection = "settings" }
        .onReceive(NotificationCenter.default.publisher(for: .bridgeNavigate)) { event in ui.selection = event.userInfo?["selection"] as? String ?? "devices" }
        .onChange(of: ui.settingsSearch) { _ in ui.selection = "settings" }
        .onAppear { if activatesApplication { NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true) } }
        .frame(minWidth: 720, minHeight: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BridgeWindowConfiguration())
    }
    private var mainWindow: some View {
        Group {
            if ui.selection == "settings" {
                BridgePreferences(search: ui.settingsSearch).environmentObject(model)
            } else { activityWindow }
        }
    }
    private var activityWindow: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(bridgeSymbol: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings", text: $ui.settingsSearch).textFieldStyle(.plain)
                        .accessibilityLabel("Search all Bridge settings")
                    if !ui.settingsSearch.isEmpty {
                        Button { ui.settingsSearch = "" } label: { Image(bridgeSymbol: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear settings search")
                    }
                }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 10).padding(.top, 10)
                List(selection: $ui.selection) {
                Label("Device", systemImage: "iphone.gen3").tag("devices")
                Label("Notifications", systemImage: "bell").tag("notifications")
                Label("Clipboard", systemImage: "clock.arrow.circlepath").tag("clipboard")
                Label("Transfers", systemImage: "arrow.up.arrow.down").tag("transfers")
                Section {
                    Label("Settings", systemImage: "gearshape").tag("settings")
                    Label("Support", systemImage: "questionmark.circle").tag("support")
                }
            }
            }.navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            Group {
                switch ui.selection {
                case "notifications": notificationList
                case "clipboard": BridgeClipboardHistory().environmentObject(model)
                case "transfers": transferList
                case "settings": BridgePreferences(search: ui.settingsSearch).environmentObject(model)
                case "support": BridgeSupportView()
                default: if model.paired == nil { BridgeOnboarding() } else { deviceDetail }
                }
            }.navigationTitle(ui.selection == "devices" ? "Your device" : ui.selection.capitalized)
                .safeAreaInset(edge: .bottom, spacing: 0) { BridgeFeedbackBar(model: model) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.visible)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseFile(); ui.selection = "transfers" } label: {
                    Image(bridgeSymbol: "arrow.up.doc").frame(width: 30, height: 30)
                }.buttonStyle(.bordered).bridgeCircularButtonBorder().help("Send files").disabled(!model.connected)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { ui.selection = "devices" } label: {
                    Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 10, height: 10)
                        .frame(width: 30, height: 30)
                }.buttonStyle(.bordered).bridgeCircularButtonBorder().help(model.status).accessibilityLabel(model.status)
            }
        }
        .frame(minWidth: 600, minHeight: 420)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            let queued = model.sendFiles(urls)
            if queued { ui.selection = "transfers" }
            return queued
        }
    }
    private var deviceDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    Image(bridgeSymbol: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 58, weight: .light)).foregroundStyle(.tint)
                        .frame(width: 110, height: 110)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 26))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.paired?.name ?? "Your phone").font(.system(size: 28, weight: .bold, design: .rounded))
                        Label(model.status, systemImage: model.connected ? "checkmark.circle.fill" : "wifi.slash")
                            .foregroundStyle(model.connected ? .green : .secondary)
                        if let battery = model.battery {
                            HStack(spacing: 8) {
                                BridgeBatteryIcon(level: battery, charging: model.charging, saver: model.batterySaver)
                                Text("\(battery)% · \(model.batterySaver ? "Battery Saver" : (model.charging ? "Charging" : "On battery"))")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !model.connected {
                    Label("Keep both devices on the same Wi-Fi and enable the connection in Bridge on Android. Bridge reconnects automatically.", systemImage: "wifi")
                        .font(.callout).foregroundStyle(.secondary).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                    if model.pairingKeyBlocked { Button("Unlock pairing key…") { model.unlockPairingKey() }.buttonStyle(.borderedProminent) }
                }
                BridgeDeviceInformation().environmentObject(model)
                Text("Quick actions").font(.headline)
                HStack(spacing: 12) {
                    dashboardAction("Send files", subtitle: "Choose from your Mac", icon: "arrow.up.doc") { model.chooseFile(); ui.selection = "transfers" }
                    dashboardAction("Send clipboard", subtitle: "Share copied text", icon: "doc.on.clipboard") { model.sendClipboard() }
                    dashboardAction(model.ringing ? "Stop ringing" : "Find phone", subtitle: model.ringing ? "Silence your phone" : "Ring to locate it", icon: model.ringing ? "speaker.slash" : "bell.badge") { model.ringPhone() }
                }.disabled(!model.connected)
                if model.mediaAvailable {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Now playing on your phone", systemImage: "music.note").font(.headline)
                        BridgeMediaControls()
                    }.padding(20).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                }
                if model.incomingHandoff != nil { BridgeHandoffCard() }
                if !model.incomingLink.isEmpty && model.incomingHandoff == nil { Button("Open link from phone") { model.openReceivedLink() } }
                HStack(spacing: 16) {
                    summaryCard("Notifications", count: model.notifications.count, icon: "bell", destination: "notifications")
                    summaryCard("Transfers", count: model.transfers.count, icon: "arrow.up.arrow.down", destination: "transfers")
                }
                Label("Your connection is private and encrypted", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func dashboardAction(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(bridgeSymbol: icon).font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading).padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
    private func summaryCard(_ title: String, count: Int, icon: String, destination: String) -> some View {
        Button { ui.selection = destination } label: {
            HStack(spacing: 12) {
                Image(bridgeSymbol: icon).foregroundStyle(.tint)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                Image(bridgeSymbol: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(18).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
    private var notificationList: some View { BridgeNotificationsView().environmentObject(model) }
    private var transferList: some View { BridgeTransfersView().environmentObject(model) }

}

struct BridgeSettings: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var model: BridgeModel
    @StateObject private var ui = SettingsUIState()
    static let searchIndex: [(String, String)] = [
        ("Connection", "Connection Connection Phone No paired phone Status Last connected Model Android Phone storage free Local address  (model.address): (model.localPort) Open Bridge at login"),
        ("Clipboard", "Clipboard Clipboard Automatically send copied Mac text Keep session clipboard history Memory only · up to 100 entries · unpinned text expires after 24 hours. Clipboard privacy & retention Keeps up to 100 exchanged text entries in memory. Unpinned entries expire after 24 hours. Turning this off or quitting Bridge clears everything, including pins. Likely sensitive text is skipped. Mac text updates your phone clipboard automatically when enabled. Likely credentials and verification codes are skipped; use Send clipboard to approve a single sensitive send. Send phone text through Android’s share menu. History is optional and never written to disk. Mac clipboard access Clipboard permissions…"),
        ("Notifications", "Notifications Notifications Mac system notifications Mirror phone notifications Show notification contents Notify about clipboard updates Allow Mac notifications… Open notification settings denied permission Send test notification Notification settings & privacy In System Settings → Notifications → Bridge, choose Banners or Alerts. Focus settings can silence notifications. Choose excluded apps on your phone. Android may hide sensitive notifications."),
        ("Files", "Files Files Clear file queue… Show Send to phone while connected and dragging Ask where to save When off, receive files in Downloads/Bridge. Existing files are preserved."),
        ("Battery", "Battery Battery Low-battery alerts Alert at  (model.lowBatteryThreshold)% For connected, noncharging phones. Mac notification permission is required for banners."),
        ("Device", "Device Device Unlock pairing key… Unpair phone…"),
        ("Automations", "Enable automations saved rules add rule refresh Shortcuts allow notifications automation privacy limits when then rule enabled shortcut phone connected disconnected battery low file received clipboard notify"),
        ("Optional tools", "Optional tools Optional tools Developer tools… developer USB developer tools require separate authorization on your phone."),
        ("Support", "Help report bug suggest feature coffee creator mlwn"),
        ("About Bridge", "About Bridge About Bridge Version CFBundleShortVersionString 1.0 A private bridge between your Mac and Android. Your content travels directly over your local network.")
    ]
    var search = ""
    var category: String? = nil
    private func matches(_ title: String, _ keywords: String) -> Bool {
        if search.isEmpty, let category {
            let group = ["Connection": "General", "Device": "General", "Optional tools": "Advanced", "About Bridge": "Support"][title] ?? title
            guard group == category else { return false }
        }
        let terms = search.lowercased().split(whereSeparator: { $0.isWhitespace })
        let values: String
        switch title {
        case "Connection", "Device": values = [model.paired?.name ?? "", model.status, model.phoneModel, model.phoneOS, model.address].joined(separator: " ")
        case "Battery": values = String(model.lowBatteryThreshold)
        case "Automations": values = model.automation.rules.map(\.shortcutName).joined(separator: " ")
        default: values = ""
        }
        let text = (title + " " + keywords + " " + values).lowercased()
        return terms.allSatisfy { text.contains($0) }
    }
    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            Text(title + ":").frame(width: 240, alignment: .trailing)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }
    }
    private func settingsValue(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title + ":").frame(width: 240, alignment: .trailing)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
    private func settingsGroup<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline).padding(.leading, 256)
            VStack(alignment: .leading, spacing: 14) { content() }
        }.padding(.vertical, 12)
    }
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if !search.isEmpty { VStack(alignment: .leading, spacing: 8) {
                Image(bridgeSymbol: "gearshape.fill").font(.largeTitle).foregroundStyle(.tint)
                Text(search.isEmpty ? "Make Bridge yours" : "Settings results").font(.title.bold()).padding(.leading, 256)
                Text(search.isEmpty ? "Your devices, working together. Choose how Bridge fits your day." : "Matching “\(search)” across all settings.").foregroundStyle(.secondary).padding(.leading, 256)
            }.padding(.vertical, 12) }
            if matches("Connection", "Connection Connection Phone No paired phone Status Last connected Model Android Phone storage free Local address  (model.address): (model.localPort) Open Bridge at login") { settingsGroup("Connection", icon: "wifi") {
                settingsValue("Phone", value: model.paired?.name ?? "No paired phone")
                settingsValue("Status", value: model.status)
                if let date = model.lastConnected { LabeledContent("Last connected") { Text(date, style: .relative) } }
                if !model.phoneModel.isEmpty { settingsValue("Model", value: model.phoneModel) }
                if !model.phoneOS.isEmpty { settingsValue("Android", value: model.phoneOS) }
                if let free = model.phoneStorageFree { settingsValue("Phone storage free", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) }
                settingsValue("Local address", value: "\(model.address):\(model.localPort)")
                settingsToggle("Open Bridge at login", isOn: $ui.loginEnabled).onChange(of: ui.loginEnabled) { value in
                    do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.notice = error.localizedDescription; ui.loginEnabled = SMAppService.mainApp.status == .enabled }
                }
            } }
            if matches("Clipboard", "Clipboard Clipboard Automatically send copied Mac text Keep session clipboard history Memory only · up to 100 entries · unpinned text expires after 24 hours. Clipboard privacy & retention Keeps up to 100 exchanged text entries in memory. Unpinned entries expire after 24 hours. Turning this off or quitting Bridge clears everything, including pins. Likely sensitive text is skipped. Mac text updates your phone clipboard automatically when enabled. Likely credentials and verification codes are skipped; use Send clipboard to approve a single sensitive send. Send phone text through Android’s share menu. History is optional and never written to disk. Mac clipboard access Clipboard permissions…") { settingsGroup("Clipboard", icon: "doc.on.clipboard") {
                settingsToggle("Automatically send copied Mac text", isOn: $model.autoClipboard)
                settingsToggle("Keep session clipboard history", isOn: $model.clipboardHistoryEnabled)
                Text("Memory only · up to 100 entries · unpinned text expires after 24 hours.").font(.caption).foregroundStyle(.secondary).padding(.leading, 256)
                DisclosureGroup("Clipboard privacy & retention") {
                    Text("Keeps up to 100 exchanged text entries in memory. Unpinned entries expire after 24 hours. Turning this off or quitting Bridge clears everything, including pins. Likely sensitive text is skipped.").font(.caption).foregroundStyle(.secondary)
                    Text("Mac text updates your phone clipboard automatically when enabled. Likely credentials and verification codes are skipped; use Send clipboard to approve a single sensitive send. Send phone text through Android’s share menu. History is optional and never written to disk.").font(.caption).foregroundStyle(.secondary)
                }
                settingsValue("Mac clipboard access", value: model.clipboardAccessDescription)
                Button("Clipboard permissions…") { model.openClipboardSettings() }.padding(.leading, 256)
            } }
            if matches("Notifications", "Notifications Notifications Mac system notifications Mirror phone notifications Show notification contents Notify about clipboard updates Allow Mac notifications… Open notification settings denied permission Send test notification Notification settings & privacy In System Settings → Notifications → Bridge, choose Banners or Alerts. Focus settings can silence notifications. Choose excluded apps on your phone. Android may hide sensitive notifications.") { settingsGroup("Notifications", icon: "bell.badge") {
                settingsValue("Mac system notifications", value: model.notificationStatus)
                settingsToggle("Mirror phone notifications", isOn: $model.mirrorNotifications)
                settingsToggle("Show notification contents", isOn: $model.notificationPreviews)
                settingsToggle("Notify about clipboard updates", isOn: $model.clipboardNotifications)
                Button(model.notificationStatus.hasPrefix("Disabled") ? "Open notification settings…" : "Allow Mac notifications…") { model.requestNotificationPermission() }.padding(.leading, 256)
                Button("Send test notification") { model.sendTestNotification() }.padding(.leading, 256)
                DisclosureGroup("Notification settings & privacy") {
                    Text("In System Settings → Notifications → Bridge, choose Banners or Alerts. Focus settings can silence notifications. Choose excluded apps on your phone. Android may hide sensitive notifications.").font(.caption).foregroundStyle(.secondary)
                }
            } }
            if matches("Files", "Files Files Clear file queue… Show Send to phone while connected and dragging Ask where to save When off, receive files in Downloads/Bridge. Existing files are preserved.") { settingsGroup("Files", icon: "folder") {
                Button("Clear file queue…", role: .destructive) { ui.confirmClearQueue = true }.padding(.leading, 256)
                settingsToggle("Show Send to phone while connected and dragging", isOn: $model.dragSendEnabled)
                settingsToggle("Ask where to save", isOn: $model.askWhereToSave)
                Text("When off, receive files in Downloads/Bridge. Existing files are preserved.").font(.caption).foregroundStyle(.secondary).padding(.leading, 256)
            } }
            if matches("Battery", "Battery Battery Low-battery alerts Alert at  (model.lowBatteryThreshold)% For connected, noncharging phones. Mac notification permission is required for banners.") { settingsGroup("Battery", icon: "battery.100") {
                settingsToggle("Low-battery alerts", isOn: $model.lowBatteryAlerts)
                Stepper("Alert at \(model.lowBatteryThreshold)%", value: $model.lowBatteryThreshold, in: 5...50, step: 5).disabled(!model.lowBatteryAlerts).padding(.leading, 256)
                Text("For connected, noncharging phones. Mac notification permission is required for banners.").font(.caption).foregroundStyle(.secondary).padding(.leading, 256)
            } }
            if matches("Device", "Device Device Unlock pairing key… Unpair phone…") { settingsGroup("Device", icon: "iphone") {
                Button("Unlock pairing key…") { model.unlockPairingKey() }.disabled(!model.pairingKeyBlocked).padding(.leading, 256)
                Button("Unpair phone…", role: .destructive) { ui.confirmUnpair = true }.disabled(model.paired == nil).padding(.leading, 256)
            } }
            if matches("Automations", "Enable automations saved rules add rule refresh Shortcuts allow notifications automation privacy limits when then rule enabled shortcut phone connected disconnected battery low file received clipboard notify") { settingsGroup("Automations", icon: "bolt") { BridgeAutomationView(automation: model.automation) } }
            if matches("Optional tools", "Optional tools Optional tools Developer tools… developer USB developer tools require separate authorization on your phone.") { settingsGroup("Optional tools", icon: "hammer") {
                Button("Developer tools…") { BridgeWindows.open("developer", using: openWindow) }.padding(.leading, 256)
                Text("USB developer tools require separate authorization on your phone.").font(.caption).foregroundStyle(.secondary).padding(.leading, 256)
            } }
            if matches("About Bridge", "About Bridge About Bridge Version CFBundleShortVersionString 1.0 A private bridge between your Mac and Android. Your content travels directly over your local network.") { settingsGroup("About Bridge", icon: "info.circle") {
                settingsValue("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0")
                Text("A private bridge between your Mac and Android. Your content travels directly over your local network.").font(.caption).foregroundStyle(.secondary).padding(.leading, 256)
            } }
            if matches("Support", "Help report bug suggest feature coffee creator mlwn") { settingsGroup("Support", icon: "questionmark.circle") {
                Button("Help & support", systemImage: "questionmark.circle") { BridgeApplicationDelegate.showPage("support") }.padding(.leading, 256)
                Text("Report a bug, suggest a feature or learn about the creator.").font(.caption).foregroundStyle(.secondary).padding(.leading, 256)
                Link("Buy me a coffee", destination: URL(string: "https://buymeacoffee.com/mlwn")!).padding(.leading, 256)
                Link("About the creator · mlwn.in", destination: URL(string: "https://mlwn.in")!).padding(.leading, 256)
            } }
            if !search.isEmpty && !Self.searchIndex.contains(where: { matches($0.0, $0.1) }) {
                BridgeEmptyState(title: "No matching settings", detail: "Try clipboard, notifications, files, battery or connection.", icon: "magnifyingglass")
            }
          }.padding(.horizontal, 40).padding(.vertical, 20)
            .frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
        }.toggleStyle(.checkbox)
        .onAppear { model.refreshNotificationStatus() }
        .confirmationDialog("Clear all queued files?", isPresented: $ui.confirmClearQueue) {
            Button("Clear queue", role: .destructive) { model.resetFileQueue() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Queued selections and Bridge-owned snapshots will be removed. Your original files will be kept.") }
        .confirmationDialog("Unpair your phone?", isPresented: $ui.confirmUnpair) {
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: { Text("Its credential will be revoked. Scan a new code to pair again.") }
    }
}


@MainActor final class WindowUIState: ObservableObject { @Published var selection: String; @Published var settingsSearch = ""; init(selection: String = "devices") { self.selection = selection } }
@MainActor final class SettingsUIState: ObservableObject { @Published var confirmClearQueue = false; @Published var confirmUnpair = false; @Published var loginEnabled = SMAppService.mainApp.status == .enabled }

@MainActor final class PopoverUIState: ObservableObject { @Published var confirmQuit = false; @Published var showHistory = false }

struct BridgeClipboardHistory: View {
    @EnvironmentObject var model: BridgeModel
    @StateObject private var ui = ClipboardHistoryUIState()
    private var entries: [ClipboardHistoryEntry] {
        model.clipboardHistory.entries.filter { ui.search.isEmpty || $0.text.localizedCaseInsensitiveContains(ui.search) || $0.sourceName.localizedCaseInsensitiveContains(ui.search) }
            .sorted { if $0.pinned != $1.pinned { return $0.pinned }; return $0.date > $1.date }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BridgeUI.spacing) {
            if !model.clipboardHistoryEnabled {
                BridgeEmptyState(title: "Clipboard history is off", detail: "Keep safe text in memory for this session. Nothing is written to disk.", icon: "doc.on.clipboard")
                Button("Enable session history") { model.clipboardHistoryEnabled = true }
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 8) {
                    TextField("Search text or device", text: $ui.search).textFieldStyle(.roundedBorder)
                    Button("Clear all", role: .destructive) { ui.confirmClear = true }.disabled(model.clipboardHistory.entries.isEmpty)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: BridgeUI.spacing) {
                        if entries.isEmpty { BridgeEmptyState(title: "No matching clipboard text", detail: "Exchange safe text with your phone to add an entry.", icon: "doc.on.clipboard") }
                        ForEach(entries) { BridgeClipboardRow(entry: $0) }
                    }.frame(maxWidth: BridgeUI.contentWidth, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }.padding(BridgeUI.margin).onAppear { model.clipboardHistory.prune() }
        .alert("Clear all clipboard history?", isPresented: $ui.confirmClear) {
            Button("Clear all", role: .destructive) { model.clipboardHistory.clear() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Pinned entries will also be deleted.") }
    }
}

@MainActor final class ClipboardHistoryUIState: ObservableObject { @Published var search = ""; @Published var confirmClear = false }

struct TransferMetricsCaption: View {
    let item: TransferItem
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let stalled = item.lastProgressUptime > 0 && ProcessInfo.processInfo.systemUptime - item.lastProgressUptime > 5
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metrics(stalled: stalled) }
                VStack(alignment: .leading, spacing: 3) { metrics(stalled: stalled) }
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func metrics(stalled: Bool) -> some View {
        Text("\(Int(min(1, max(0, item.progress)) * 100))%")
        if stalled { Text("Waiting for data…") }
        else if item.bytesPerSecond > 0 {
            Text(String(format: "%.1f MB/s", item.bytesPerSecond / 1_000_000))
            if let remaining = TransferTelemetry.remaining(size: item.size, progress: item.progress, speed: item.bytesPerSecond) { Text(remaining) }
        } else { Text("Estimating speed…") }
    }
}

struct BridgeHandoffCard: View {
    @EnvironmentObject var model: BridgeModel
    var body: some View {
        if let handoff = model.incomingHandoff {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Continue from \(model.paired?.name ?? "Pixel")", systemImage: "safari").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.dismissHandoff() } label: { Image(bridgeSymbol: "xmark") }
                        .buttonStyle(.plain).help("Dismiss page").accessibilityLabel("Dismiss page")
                }
                Text(handoff.title).font(.headline).lineLimit(2)
                if handoff.title != handoff.host { Text(handoff.host).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Button("Open on Mac", systemImage: "arrow.up.forward.app") { model.openReceivedLink() }
                    .buttonStyle(.bordered)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

extension Notification.Name {
    static let bridgeShowSettings = Notification.Name("BridgeShowSettings")
    static let bridgeNavigate = Notification.Name("BridgeNavigate")
}

@MainActor final class BridgeApplicationDelegate: NSObject, NSApplicationDelegate {
    static var setupPresentedThisLaunch = false
    static var openMainWindow: (() -> Void)?
    static var openSettingsWindow: (() -> Void)?
    static weak var menuPanel: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching Bridge again keeps it in the menu bar; only explicitly
        // requested Settings/Activity windows should be presented.
        if flag { sender.activate(ignoringOtherApps: true) }
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        BridgeRuntime.open(urls)
    }
    static func showPage(_ selection: String) {
        menuPanel?.orderOut(nil)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .bridgeNavigate, object: nil, userInfo: ["selection": selection]) }
    }
    static func showSettings() {
        menuPanel?.orderOut(nil)
        openSettingsWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct BridgeOnboarding: View {
    @AppStorage(BridgeDownloads.completedKey) private var companionInstallCompleted = false
    @EnvironmentObject var model: BridgeModel
    var body: some View {
        if !companionInstallCompleted && model.pairingRequest == nil {
            ScrollView { BridgeCompanionDownload().frame(maxWidth: .infinity) }
        } else {
        ScrollView {
            VStack(spacing: 24) {
                Image(bridgeSymbol: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 54, weight: .light)).foregroundStyle(.tint)
                    .frame(width: 112, height: 112)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                VStack(spacing: 8) {
                    Text("Welcome to Bridge").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Your phone and Mac, working together.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Label("Connect both devices to the same Wi-Fi", systemImage: "wifi")
                    Label("Open Bridge on Android and tap Pair Mac", systemImage: "iphone")
                    Label("Scan this code, then approve your phone here", systemImage: "qrcode.viewfinder")
                }.font(.callout).frame(maxWidth: 420, alignment: .leading)
                if model.pairingKeyBlocked {
                    Button("Unlock pairing key…", systemImage: "lock.open") { model.unlockPairingKey() }.buttonStyle(.borderedProminent)
                } else if let request = model.pairingRequest {
                    VStack(spacing: 14) {
                        Label("Connect to \(request.name)?", systemImage: "lock.shield").font(.headline)
                        Text("Approve only the phone that just scanned this code.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Decline") { model.rejectPairing() }
                            Button("Pair phone") { model.confirmPairing() }.buttonStyle(.borderedProminent)
                        }
                    }.padding(24).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 20))
                } else { PairingView().frame(maxWidth: 420) }
                Label("Encrypted connection. No cloud account required.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.notice.isEmpty { Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(36).frame(maxWidth: .infinity)
        }.navigationTitle("Pair your phone")
        }
    }
}

@MainActor final class SettingsCategoryState: ObservableObject { @Published var category = "Connection" }
