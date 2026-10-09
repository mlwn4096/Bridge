import SwiftUI
import AppKit

/// The activity/settings window is a normal resizable fullscreen window even
/// though the app lives in the menu bar. The drag panel stays auxiliary.
struct BridgeWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowConfigurationView { WindowConfigurationView() }
    func updateNSView(_ nsView: WindowConfigurationView, context: Context) { nsView.configure() }
}
final class WindowConfigurationView: NSView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
    func configure() {
        guard let window, !(window is NSPanel) else { return }
        window.styleMask.insert(.resizable)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarAppearsTransparent = true
    }
}
