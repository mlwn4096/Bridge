import SwiftUI
import AppKit

/// Classic macOS preferences: icon tabs above a quiet, native form.
struct BridgePreferences: View {
    @EnvironmentObject var model: BridgeModel
    @StateObject private var ui: PreferencesPaneState
    var search = ""
    init(search: String = "", initialCategory: String = "General") {
        self.search = search
        _ui = StateObject(wrappedValue: PreferencesPaneState(selection: initialCategory))
    }
    private let panes: [(String, String)] = [
        ("General", "gearshape"), ("Clipboard", "doc.on.clipboard"),
        ("Notifications", "bell"), ("Files", "folder"),
        ("Battery", "battery.100"), ("Automations", "bolt"),
        ("Advanced", "gearshape.2"), ("Support", "questionmark.circle")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(panes, id: \.0) { title, icon in
                    Button { ui.selection = title } label: {
                        VStack(spacing: 5) {
                            Image(systemName: icon).font(.system(size: 27, weight: .regular)).frame(height: 32)
                            Text(title).font(.system(size: 12))
                        }
                        .foregroundStyle(ui.selection == title ? Color.accentColor : Color.secondary)
                        .frame(width: 88, height: 64)
                        .background(ui.selection == title ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(ui.selection == title ? .isSelected : [])
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
            Divider()
            BridgeSettings(search: search, category: ui.selection).environmentObject(model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(search.isEmpty ? ui.selection : "Settings results")
        .frame(minWidth: 820, minHeight: 560)
    }
}

/// Capture only the menu's own hosting window, so navigation can dismiss it
/// before activating a preferences or activity window.
struct BridgeMenuPanelCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuPanelCaptureView { MenuPanelCaptureView() }
    func updateNSView(_ view: MenuPanelCaptureView, context: Context) { }
}
final class MenuPanelCaptureView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { BridgeApplicationDelegate.menuPanel = window }
    }
}

@MainActor final class PreferencesPaneState: ObservableObject { @Published var selection: String; init(selection: String) { self.selection = selection } }
