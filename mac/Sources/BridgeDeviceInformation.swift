import SwiftUI

struct PhoneFileEntry: Identifiable {
    let id: String
    let name: String
    let directory: Bool
    let size: Int64
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let name = value["name"] as? String,
              !id.isEmpty, id.utf8.count <= 4096 else { return nil }
        self.id = id; self.name = String(name.prefix(240))
        directory = value["directory"] as? Bool ?? false
        size = max(0, (value["size"] as? NSNumber)?.int64Value ?? 0)
    }
}
struct BridgeDeviceInformation: View {
    @EnvironmentObject var model: BridgeModel
    @StateObject private var ui = DeviceInformationState()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Device information").font(.headline)
            LabeledContent("Model", value: model.phoneModel.isEmpty ? "Connect to update" : model.phoneModel)
            LabeledContent("Software", value: model.phoneOS.isEmpty ? "Connect to update" : "Android \(model.phoneOS)")
            if let level = model.battery {
                LabeledContent("Battery") {
                    HStack(spacing: 8) {
                        BridgeBatteryIcon(level: level, charging: model.charging, saver: model.batterySaver)
                        Text("\(level)% · " + (model.charging ? "Charging" : (model.batterySaver ? "Battery Saver" : "On battery")))
                    }
                }
            }
            if !model.phoneChip.isEmpty { LabeledContent("Chip", value: model.phoneChip) }
            if model.phoneCores > 0 { LabeledContent("Processor", value: "\(model.phoneCores) cores") }
            if !model.phoneSecurityPatch.isEmpty { LabeledContent("Security update", value: model.phoneSecurityPatch) }
            if let total = model.phoneMemoryTotal {
                LabeledContent("Memory", value: bytes(total))
                if let available = model.phoneMemoryAvailable {
                    ProgressView(value: Double(total - available), total: Double(total)).tint(.accentColor)
                    Text("\(bytes(total - available)) in use · \(bytes(available)) available").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let free = model.phoneStorageFree {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Storage")
                        Spacer()
                        Text("\(bytes(free)) available").foregroundStyle(.secondary)
                    }
                    if let total = model.phoneStorageTotal, total > 0 {
                        ProgressView(value: Double(max(0, total - free)), total: Double(total)).tint(.accentColor)
                        Text("\(bytes(max(0, total - free))) used of \(bytes(total))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let updated = model.phoneInfoUpdated {
                HStack {
                    Text(model.connected ? "Updates while connected" : "Offline · connect to refresh")
                    Spacer()
                    Text(updated, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Button { ui.showingFiles.toggle(); if ui.showingFiles { ui.folders = [("", "Shared folder")]; model.browsePhone() } } label: {
                HStack {
                    Label("Browse phone files", systemImage: "folder")
                    Spacer()
                    Image(bridgeSymbol: ui.showingFiles ? "chevron.down" : "chevron.right")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.tint).disabled(!model.connected)
            if ui.showingFiles {
                HStack {
                    Button("Shared folder", systemImage: "house") { ui.folders = [("", "Shared folder")]; model.browsePhone() }
                    if ui.folders.count > 1 {
                        Button("Back", systemImage: "chevron.left") { ui.folders.removeLast(); model.browsePhone(ui.folders.last?.0 ?? "") }
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.browsePhone(ui.folders.last?.0 ?? "", offset: model.phoneFilesOffset) }
                }.controlSize(.small).disabled(!model.connected || model.phoneFilesMessage == "Loading…")
                Text(ui.folders.map { $0.1 }.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                Text("Choose a folder in Android Settings → Phone files. Only that folder is shared with your paired Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.phoneFilesMessage.isEmpty { Text(model.phoneFilesMessage).foregroundStyle(.secondary) }
                if model.phoneFiles.isEmpty && model.phoneFilesMessage.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
                HStack {
                    if model.phoneFilesOffset > 0 { Button("Previous page") { model.browsePhone(model.phoneFolder, offset: max(0, model.phoneFilesOffset - 60)) } }
                    Spacer()
                    if model.phoneFilesNextOffset >= 0 { Button("Next page") { model.browsePhone(model.phoneFolder, offset: model.phoneFilesNextOffset) } }
                }.controlSize(.small).disabled(!model.connected || model.phoneFilesMessage == "Loading…")
                ForEach(model.phoneFiles) { entry in
                    HStack {
                        Image(bridgeSymbol: entry.directory ? "folder.fill" : "doc").foregroundStyle(.tint)
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if entry.directory {
                            Button("Open") { ui.folders.append((entry.id, entry.name)); model.browsePhone(entry.id) }
                        } else {
                            Text(bytes(entry.size)).font(.caption).foregroundStyle(.secondary)
                            Button("Download") { model.downloadPhoneFile(entry.id) }
                        }
                    }.disabled(!model.connected || model.phoneFilesMessage == "Loading…")
                    Divider()
                }
            }
        }.bridgeCard()
        .onChange(of: model.connected) { connected in
            if !connected { ui.showingFiles = false; ui.folders = [("", "Shared folder")] }
        }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

@MainActor final class DeviceInformationState: ObservableObject { @Published var showingFiles = false; @Published var folders: [(String, String)] = [("", "Shared folder")] }
