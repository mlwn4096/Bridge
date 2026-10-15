import SwiftUI
import AppKit

/// Symbol availability varies independently of Swift API availability. Cache
/// lookups so frequently refreshed transfer rows do not repeatedly load symbols.
enum BridgeSymbols {
    private static let cache = NSCache<NSString, NSString>()
    static func name(_ requested: String) -> String {
        if let cached = cache.object(forKey: requested as NSString) { return cached as String }
        let fallback = requested.contains("iphone") || requested == "smartphone" ? "iphone" : "questionmark.circle"
        let resolved = NSImage(systemSymbolName: requested, accessibilityDescription: nil) == nil ? fallback : requested
        cache.setObject(resolved as NSString, forKey: requested as NSString)
        return resolved
    }
}

extension Image {
    init(bridgeSymbol name: String) { self.init(systemName: BridgeSymbols.name(name)) }
}

extension View {
    @ViewBuilder func bridgeCircularButtonBorder() -> some View {
        if #available(macOS 14.0, *) { buttonBorderShape(.circle) }
        else { self }
    }
}

/// macOS 13–14 cannot suppress SwiftUI Window scenes at launch. Host the same
/// views in explicitly opened AppKit windows there, keeping launch menu-bar-only.
@MainActor enum BridgeWindows {
    private static var controllers: [String: NSWindowController] = [:]

    static func open(_ id: String, using action: OpenWindowAction) {
        if #available(macOS 15.0, *) {
            action(id: id)
            return
        }
        guard let model = BridgeRuntime.model, let controller = legacyController(id, model: model) else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Construct lazily without presenting. Also lets UI QA exercise this path
    /// on newer macOS without changing the installed OS or production routing.
    static func legacyController(_ id: String, model: BridgeModel) -> NSWindowController? {
        if let controller = controllers[id] { return controller }
        let content: AnyView
        let title: String
        let size: NSSize
        switch id {
        case "setup":
            title = "Welcome to Bridge"; size = NSSize(width: 520, height: 680)
            content = AnyView(BridgeSetupWindow().environmentObject(model))
        case "settings":
            title = "General"; size = NSSize(width: 860, height: 610)
            content = AnyView(BridgePreferences().environmentObject(model))
        case "developer":
            title = "Developer tools"; size = NSSize(width: 900, height: 640)
            content = AnyView(BridgeLegacyDeveloperWindow(model: model))
        case "bridge":
            title = "Bridge"; size = NSSize(width: 920, height: 680)
            content = AnyView(BridgeWindow().environmentObject(model))
        default: return nil
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier("bridge.\(id)")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setContentSize(size)
        window.center()
        let controller = NSWindowController(window: window)
        controllers[id] = controller
        return controller
    }

    static func closeLegacySetup() {
        controllers["setup"]?.close()
    }
}

private struct BridgeLegacyDeveloperWindow: View {
    @ObservedObject var model: BridgeModel
    var body: some View { DeveloperToolsView(bridgeConnected: model.connected) }
}
