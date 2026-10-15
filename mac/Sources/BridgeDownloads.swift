import SwiftUI
import AppKit

enum BridgeDownloads {
    // The release page also works for prereleases; /releases/latest skips them.
    static let releases = URL(string: "https://github.com/mlwn4096/Bridge/releases")!
    static let completedKey = "companionInstallStepCompleted"
}

struct BridgeCompanionDownload: View {
    var compact = false
    @AppStorage(BridgeDownloads.completedKey) private var completed = false
    var body: some View {
        VStack(spacing: compact ? 14 : 22) {
            VStack(spacing: 8) {
                Text("Get Bridge on your phone")
                    .font(compact ? .title3.bold() : .system(size: 28, weight: .bold))
                Text("Install the Android companion, then connect it to this Mac.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let qr = downloadQR {
                Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(width: compact ? 176 : 212, height: compact ? 176 : 212)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Scan to open Bridge’s Android downloads on GitHub")
            }
            Text("Scan with your phone’s camera.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Download Android APK", systemImage: "arrow.down.app") {
                NSWorkspace.shared.open(BridgeDownloads.releases)
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("On GitHub, open a release’s Assets and choose the .apk. Android 10 or later.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Divider()
            Button("Already installed? Connect your phone →") { completed = true }
                .buttonStyle(.link).font(.callout)
        }.padding(compact ? 0 : 32).frame(maxWidth: compact ? .infinity : 480)
    }
    private var downloadQR: NSImage? {
        guard let url = Bundle.main.url(forResource: "AndroidDownloadQR", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct BridgeSetupWindow: View {
    @EnvironmentObject var model: BridgeModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BridgeDownloads.completedKey) private var completed = false
    var body: some View {
        Group {
            if completed || model.pairingRequest != nil { BridgeOnboarding() }
            else { ScrollView { BridgeCompanionDownload().frame(maxWidth: .infinity) } }
        }.frame(minWidth: 480, minHeight: 580)
            .onAppear { NSApp.activate(ignoringOtherApps: true) }
            .onChange(of: model.paired?.id) { value in if value != nil { BridgeWindows.closeLegacySetup(); dismiss() } }
    }
}
