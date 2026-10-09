import SwiftUI
import AppKit

struct DeveloperToolsView: View {
    @StateObject private var console: DeveloperConsole
    var bridgeConnected: Bool
    init(bridgeConnected: Bool = false, console: DeveloperConsole? = nil) {
        self.bridgeConnected = bridgeConnected
        _console = StateObject(wrappedValue: console ?? DeveloperConsole())
    }
    var body: some View {
        BridgeContentColumn {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer tools").font(.largeTitle.bold())
                    Text("Optional tools for an authorized USB phone.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("Enable", isOn: $console.enabled).toggleStyle(.switch).disabled(console.busy)
            }
            if console.enabled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Picker("USB device", selection: $console.selected) {
                            Text("Choose device").tag("")
                            ForEach(console.devices) { Text("\($0.label) · \($0.id)").tag($0.id) }
                        }.disabled(console.busy)
                        Button("Refresh", action: console.refresh).disabled(console.busy)
                    }
                    if console.devices.isEmpty {
                        Label("USB authorization required", systemImage: "cable.connector").font(.headline)
                        Text("1. Connect your Pixel by USB.\n2. Enable USB debugging in Android Developer options.\n3. Unlock the phone and approve this Mac.").font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("Device actions stay disabled until an authorized USB phone appears.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(bridgeConnected ? "Bridge is connected over the local network. USB authorization is separate." : "Bridge’s local-network pairing does not authorize USB developer tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }.bridgeCard()
                BridgeFlowLayout {
                    Button("Device info") { console.execute(["shell", "getprop"]) }
                    Button("Packages") { console.execute(["shell", "pm", "list", "packages"]) }
                    Button("Recent logs") { console.execute(["logcat", "-d", "-t", "500"]) }
                    Button("Screenshot", action: screenshot)
                    Button("Install APK…", action: installAPK)
                }.disabled(console.selected.isEmpty || console.busy)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shared-storage files").font(.headline)
                    TextField("Path", text: $console.path).textFieldStyle(.roundedBorder)
                    BridgeFlowLayout {
                        Button("List folder", action: console.browse)
                        Button("Download path…", action: download)
                        Text("/sdcard/ only · no root").font(.caption).foregroundStyle(.secondary)
                    }.disabled(console.selected.isEmpty || console.busy)
                }.bridgeCard()
                if console.busy { ProgressView("Working…").controlSize(.small) }
                if console.hasCommandOutput {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Output").font(.headline)
                        ScrollView {
                            Text(console.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: min(240, max(80, CGFloat(console.output.filter { $0 == "\n" }.count + 1) * 15)))
                    }.bridgeCard()
                } else if !console.output.isEmpty && !console.output.hasPrefix("No authorized USB") { Text(console.output).font(.caption).foregroundStyle(.secondary) }
            } else {
                BridgeEmptyState(title: "Developer tools are off", detail: "Normal Bridge pairing and sharing work without USB debugging.", icon: "hammer")
            }
            DisclosureGroup("Requirements & privacy") {
                Text("ADB platform-tools must be installed. Enable USB debugging and approve this Mac on the phone. A local-network Bridge connection is independent of that authorization. These developer tools intentionally accept USB devices only.")
                Text("Logs may contain private information. Output stays local and command logs are bounded. Arbitrary shell commands, root and automatic wireless-debugging setup are unavailable in this developer console.")
            }.font(.caption).foregroundStyle(.secondary)
        }.frame(minWidth: 540, minHeight: 520).onAppear { console.refresh() }
    }
    private func installAPK() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "apk") ?? .data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Install \(file.lastPathComponent)?"
        alert.informativeText = "This installs or updates an Android app on the selected USB device. Only install APKs you trust."
        alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { console.execute(["install", "-r", file.path], timeout: 120) }
    }
    private func screenshot() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Android-screenshot.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        console.execute(["exec-out", "screencap", "-p"], destination: destination)
    }
    private func download() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: console.path).lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { console.output = "Choose a new destination. Existing files or folders are never overwritten."; return }
        console.download(to: destination)
    }
}
