import SwiftUI
import AppKit

@main struct PolishRunner {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--render") {
            do { try NativePolishRenderer.renderAll(); return } catch { print("Render failed: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--checks") {
            let suite = "BridgeUIPolishQA." + UUID().uuidString
            let model = BridgeModel(preview: true, automationDefaults: UserDefaults(suiteName: suite)!)
            let upright = BridgeUprightLabel(labelWithString: "Normal selectable text").isFlipped
            let console = DeveloperConsole(preview: true)
            let windowFlags = windowConfigurationFlags()
            Task { @MainActor in
                do { try await checks(model: model, upright: upright, console: console, suite: suite, windowFlags: windowFlags); exit(0) }
                catch { print("UI checks failed: \(error)"); exit(1) }
            }
            // Hosting real AppKit-backed views needs the main thread's native
            // event loop; dispatchMain alone can deadlock SwiftUI layout updates.
            NSApplication.shared.run()
        } else { PolishQAApp.main() }
    }
    @MainActor static func windowConfigurationFlags() -> (Bool, Bool) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        let configuration = WindowConfigurationView()
        window.contentView = configuration
        configuration.configure()
        return (window.styleMask.contains(.resizable), window.collectionBehavior.contains(.fullScreenPrimary) && !window.collectionBehavior.contains(.fullScreenAuxiliary))
    }
    @MainActor static func checks(model: BridgeModel, upright: Bool, console: DeveloperConsole, suite: String, windowFlags: (Bool, Bool)) async throws {
        print("Starting UI behavior checks")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
        check(windowFlags.0, "Main window is resizable")
        check(windowFlags.1, "Main window has native primary fullscreen behavior")
        check(BridgeSymbols.name("bridge.nonexistent.symbol") == "questionmark.circle", "Missing system symbol has a visible fallback")
        check(BridgeSymbols.name("iphone.nonexistent.symbol") == "iphone", "Missing phone symbol has a meaningful fallback")
        check(BridgeWindows.legacyController("unknown", model: model) == nil, "Unknown window IDs do not open a window")
        for name in ["setup", "settings", "developer", "bridge"] {
            let controller = BridgeWindows.legacyController(name, model: model)!
            check(controller === BridgeWindows.legacyController(name, model: model), "Legacy windows are reused")
            check(controller.window?.isVisible == false, "Legacy windows are created without launch presentation")
            check(controller.window?.isRestorable == false, "Legacy windows do not reopen through state restoration")
            check(controller.window?.styleMask.contains(.resizable) == true, "Legacy window supports native resizing")
            controller.close()
        }
        let id = UUID().uuidString
        model.transfers = [TransferItem(id: id, name: "Test folder.zip", size: 10, incoming: false, state: "Queued")]
        model.showTransferNotice("Folder queued as Test folder.zip", ids: [id])
        model.cancelTransfer(id)
        check(model.notice.isEmpty && model.transfers[0].state == "Cancelled", "Cancellation clears its associated feedback")
        model.showTransferNotice("Message for other file", ids: ["other"])
        model.cancelTransfer(id)
        check(model.notice == "Message for other file", "Unrelated transfer does not erase feedback")
        model.notice = "Older message"
        try await Task.sleep(nanoseconds: 4_200_000_000)
        model.notice = "Newer message"
        try await Task.sleep(nanoseconds: 4_200_000_000)
        check(model.notice == "Newer message", "Older expiry cannot erase replacement feedback")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        // Allow scheduler jitter under a concurrent production build, while
        // still requiring expiration within a bounded window.
        let expirationLimit = ContinuousClock.now.advanced(by: .seconds(1.5))
        while !model.notice.isEmpty && ContinuousClock.now < expirationLimit {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(model.notice.isEmpty, "Temporary feedback expires")
        var note = PhoneNotification(id: "test", app: "", title: "Title", body: "Body", date: Date(), packageID: "com.example.test")
        check(note.displayApp == "com.example.test", "Package identifier fallback")
        note = PhoneNotification(id: "test", app: "Friendly App", title: "Title", body: "Body", date: Date(), packageID: "com.example.test")
        check(note.displayApp == "Friendly App", "Friendly label takes precedence")
        for (title, expected) in [("Previous track", "backward.end.fill"), (" Pause playback ", "pause.fill"), ("Next song", "forward.end.fill"), ("Play", "play.fill")] { check(NotificationActionAppearance.symbol(title) == expected, "Media action classification") }
        for title in ["Reply", "Open next message", "Play my playlist later", "Mark read"] { check(NotificationActionAppearance.symbol(title) == nil, "Other action labels stay intact") }
        model.automation.addRule()
        var rule = model.automation.rules[0]; rule.enabled = true; model.automation.update(rule)
        model.automation.setEnabled(false)
        check(model.automation.rules[0].enabled && !model.automation.enabled, "Global disable preserves saved rule preference")
        check(upright, "Native result label has an explicit upright coordinate system")
        check(console.devices.isEmpty && !console.hasCommandOutput, "No USB authorization does not create output panel")
        print("Passed \(count) UI feedback, labels, automation preferences and empty-state checks")
    }
}

struct PolishQAApp: App {
    var body: some Scene {
        WindowGroup("Bridge UI QA — fixtures only") { PolishQARoot() }.defaultSize(width: 900, height: 850)
    }
}
@MainActor final class PolishQAState: ObservableObject {
    @Published var screen = "Search"
    @Published var dark = false
    @Published var empty = false
    @Published var disconnected = false
    let model: BridgeModel
    let console = DeveloperConsole(preview: true)
    let suite = "BridgeUIFixtures." + UUID().uuidString
    init() {
        model = BridgeModel(preview: true, automationDefaults: UserDefaults(suiteName: suite)!)
        model.clipboardHistoryEnabled = true
        model.automation.addRule()
        var rule = model.automation.rules[0]; rule.enabled = true; model.automation.update(rule)
        model.automation.setEnabled(false)
        load()
    }
    func load() {
        model.paired = PairedDevice(id: "C1E60DB8-35BC-41F2-9F1B-C67B1B651DB8", name: "Pixel 9 Pro")
        model.connected = !disconnected; model.status = disconnected ? "Disconnected" : "Connected"
        model.phoneChip = "Google Tensor G4"; model.phoneCores = 8; model.phoneSecurityPatch = "2026-10-01"
        model.phoneMemoryTotal = 16_000_000_000; model.phoneMemoryAvailable = 6_000_000_000; model.phoneInfoUpdated = Date()
        model.battery = 72; model.phoneModel = "Google Pixel 9 Pro"; model.phoneOS = "17"; model.phoneStorageTotal = 256_000_000_000; model.phoneStorageFree = 60_000_000_000
        model.address = "192.168.1.20"; model.localPort = 51234
        model.transfers = empty ? [] : [
            TransferItem(id: "FCA72311-7D76-4BCE-A40E-9033EC3848CF", name: "A very long project filename with spaces and a descriptive export name that must stay compact even in narrow windows — archive.zip", size: 41_000_000, incoming: false, state: "Cancelled"),
            TransferItem(id: "62EA8F5D-3750-4DC8-8CA5-07E84E09FA78", name: "Photo export.zip", size: 12_000_000, incoming: true, progress: 0.42, bytesPerSecond: 3_000_000, state: "Receiving"),
            TransferItem(id: "6460D0F2-1C94-467C-97A2-75B9A005B0B5", name: "Readme.txt", size: 1024, incoming: true, state: "Complete")]
        model.notifications = empty ? [] : [
            PhoneNotification(id: "qa-media", app: "YouTube Music", title: "A track with a comfortably readable title", body: "Artist · Album", date: Date(), actions: [PhoneNotificationAction(id: UUID().uuidString, title: "Previous track"), PhoneNotificationAction(id: UUID().uuidString, title: "Pause playback"), PhoneNotificationAction(id: UUID().uuidString, title: "Next track")]),
            PhoneNotification(id: "qa-package", app: "", title: "A notification with a long title that wraps without pushing dismissal out of reach", body: "This is a fixture for testing wrapping, contrast and grouped notification actions. It is not a real phone notification.", date: Date(), packageID: "com.example.fallback")]
        model.clipboardHistory.clear()
        if !empty {
            model.clipboardHistory.record("A short clipboard note for visual QA.", sourceID: "mac", sourceName: "This Mac")
            model.clipboardHistory.record(String(repeating: "A long clipboard paragraph checks that previews stay readable and actions remain grouped. Expand it to inspect all text.\n\n", count: 24), sourceID: "phone", sourceName: "Pixel 9 Pro")
            if let entry = model.clipboardHistory.entries.first { model.clipboardHistory.togglePin(entry.id) }
        }
    }
    func resize(_ wide: Bool) { NSApp.windows.first(where: { $0.title.contains("Bridge UI QA") })?.setContentSize(NSSize(width: wide ? 1200 : 720, height: 850)) }
}
struct PolishQARoot: View {
    @StateObject private var qa = PolishQAState()
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("QA fixtures only · no phone connection or persistent history").font(.caption).foregroundStyle(.secondary)
                BridgeFlowLayout {
                    Picker("Screen", selection: $qa.screen) { ForEach(["Device", "Search", "Transfers", "Notifications", "Clipboard", "Developer", "Settings", "Support"], id: \.self) { Text($0).tag($0) } }.frame(width: 230)
                    Button("Narrow") { qa.resize(false) }
                    Button("Wide") { qa.resize(true) }
                    Toggle("Dark", isOn: $qa.dark)
                    Toggle("Empty", isOn: $qa.empty).onChange(of: qa.empty) { _ in qa.load() }
                    Toggle("Disconnected", isOn: $qa.disconnected).onChange(of: qa.disconnected) { _ in qa.load() }
                }
            }.padding(12).background(.bar)
            Divider()
            Group {
                switch qa.screen {
                case "Search": BridgeSearchView(model: qa.model)
                case "Developer": DeveloperToolsView(bridgeConnected: qa.model.connected, console: qa.console)
                default: BridgeWindow(initialSelection: ["Device": "devices", "Transfers": "transfers", "Notifications": "notifications", "Clipboard": "clipboard", "Settings": "settings", "Support": "support"][qa.screen] ?? "devices", activatesApplication: false).environmentObject(qa.model).id(qa.screen)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 720, minHeight: 760).preferredColorScheme(qa.dark ? .dark : .light)
    }
}

@MainActor enum NativePolishRenderer {
    static let output = URL(fileURLWithPath: "dist/qa/polish", isDirectory: true)
    static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        view.layoutSubtreeIfNeeded()
    }
    static func snapshot(_ view: NSView, _ name: String) throws {
        settle(view)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
    static func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    static func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    static func renderAll() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let qa = PolishQAState()
        for dark in [false, true] {
            let note = PhoneNotification(id: "reply-fixture", app: "Messages", title: "Alex", body: "Can you send the latest draft?", date: Date())
            let action = PhoneNotificationAction(id: UUID().uuidString, title: "Reply", isReply: true, placeholder: "Message")
            let host = NSHostingView(rootView: BridgeNotificationReplyComposer(notification: note, action: action).environmentObject(qa.model).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 508, height: 520)
            try snapshot(host, "notification-reply" + (dark ? "-dark" : "-light"))
        }
        for dark in [false, true] {
            for category in ["General", "Clipboard", "Notifications", "Files", "Battery", "Automations", "Advanced", "Support"] {
                let host = NSHostingView(rootView: BridgePreferences(initialCategory: category).environmentObject(qa.model).preferredColorScheme(dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 860, height: 610)
                try snapshot(host, "preferences-" + category.lowercased() + (dark ? "-dark" : "-light"))
            }
        }
        var screenshots = 0
        for dark in [false, true] {
            qa.dark = dark
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp?.appearance = appearance
            for width: CGFloat in [720, 1200] {
                for screen in ["Device", "Search", "Transfers", "Notifications", "Clipboard", "Developer", "Settings", "Support"] {
                    qa.screen = screen
                    let host = NSHostingView(rootView: PolishCaptureScreen(qa: qa))
                    host.appearance = appearance; host.frame = NSRect(x: 0, y: 0, width: width, height: 850)
                    try snapshot(host, "\(screen.lowercased())-\(Int(width))-\(dark ? "dark" : "light")")
                    screenshots += 1
                    if screen == "Search" {
                        for scroll in scrolls(host) { scroll.contentView.scroll(to: NSPoint(x: 0, y: 280)); scroll.reflectScrolledClipView(scroll.contentView) }
                        try snapshot(host, "search-scrolled-\(Int(width))-\(dark ? "dark" : "light")")
                        // Exercise text-field editing on this offscreen component, not user UI.
                        if let field = fields(host).first(where: { $0.placeholderString?.contains("Search filenames") == true }) {
                            field.stringValue = "archive"
                            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                            try snapshot(host, "search-filtered-\(Int(width))-\(dark ? "dark" : "light")")
                        }
                        host.frame.size.width = width == 720 ? 1200 : 720
                        try snapshot(host, "search-resized-\(Int(width))-\(dark ? "dark" : "light")")
                    }
                    if screen == "Settings" {
                        for scroll in scrolls(host) { scroll.contentView.scroll(to: NSPoint(x: 0, y: 500)); scroll.reflectScrolledClipView(scroll.contentView) }
                        try snapshot(host, "settings-scrolled-\(Int(width))-\(dark ? "dark" : "light")")
                    }
                }
            }
        }
        for query in ["clipboard", "shortcut", "coffee", "no such preference"] {
            let host = NSHostingView(rootView: BridgeSettings(search: query).environmentObject(qa.model))
            host.appearance = NSAppearance(named: .aqua); host.frame = NSRect(x: 0, y: 0, width: 720, height: 850)
            try snapshot(host, "settings-query-" + query.replacingOccurrences(of: " ", with: "-"))
        }
        let popover = NSHostingView(rootView: BridgePopover().environmentObject(qa.model).background(Color(nsColor: .windowBackgroundColor)))
        popover.appearance = NSAppearance(named: .aqua)
        popover.frame = NSRect(origin: .zero, size: popover.fittingSize)
        try snapshot(popover, "menu-quick-actions")
        if let entry = qa.model.clipboardHistory.entries.first {
            for dark in [false, true] {
                for width: CGFloat in [440, 900] {
                    let host = NSHostingView(rootView: BridgeClipboardRow(entry: entry, initiallyExpanded: true).environmentObject(qa.model).frame(width: width).preferredColorScheme(dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    try snapshot(host, "clipboard-expanded-\(Int(width))-\(dark ? "dark" : "light")")
                }
            }
        }
        qa.empty = true; qa.disconnected = true; qa.load()
        for screen in ["Search", "Transfers", "Notifications", "Clipboard", "Developer", "Settings", "Support"] {
            qa.screen = screen
            let host = NSHostingView(rootView: PolishCaptureScreen(qa: qa))
            host.appearance = NSAppearance(named: .aqua); host.frame = NSRect(x: 0, y: 0, width: 720, height: 850)
            try snapshot(host, "\(screen.lowercased())-empty-disconnected")
        }
        qa.empty = false; qa.load()
        var heights: [String] = []
        for width: CGFloat in [440, 900] {
            let row = NSHostingView(rootView: BridgeTransferRow(item: qa.model.transfers[0]).environmentObject(qa.model).frame(width: width))
            let size = row.fittingSize
            precondition(size.height > 40 && size.height < 130, "Cancelled row stretched: \(size)")
            row.frame = NSRect(origin: .zero, size: size); try snapshot(row, "cancelled-row-\(Int(width))")
            heights.append("Cancelled row at \(Int(width)) points: \(Int(size.height)) points high")
        }
        try (heights.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("measurements.txt"), atomically: true, encoding: .utf8)
        print("Rendered \(screenshots) primary native component variants plus scroll/filter/resize/empty cases")
        heights.forEach { print($0) }
    }
}
struct PolishCaptureScreen: View {
    @ObservedObject var qa: PolishQAState
    var body: some View {
        Group {
            switch qa.screen {
            case "Search": BridgeSearchView(model: qa.model)
            case "Developer": DeveloperToolsView(bridgeConnected: qa.model.connected, console: qa.console)
            default: BridgeWindow(initialSelection: ["Device": "devices", "Transfers": "transfers", "Notifications": "notifications", "Clipboard": "clipboard", "Settings": "settings", "Support": "support"][qa.screen] ?? "devices", activatesApplication: false).environmentObject(qa.model)
            }
        }.preferredColorScheme(qa.dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
