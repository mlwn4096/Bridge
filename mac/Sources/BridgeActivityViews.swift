import SwiftUI
import AppKit
import AppKit

struct BridgeTransferRow: View {
    @EnvironmentObject var model: BridgeModel
    let item: TransferItem
    private var queued: QueuedFile? { model.queuedFiles.first { $0.id == item.id } }
    private var savedFile: URL? {
        guard item.state == "Complete", let url = item.destination, url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey])).map({ $0.isRegularFile == true }) == true else { return nil }
        return url
    }
    private var hasActions: Bool { item.state == "Accept to receive" || queued != nil || !["Complete", "Cancelled", "Failed"].contains(item.state) || savedFile != nil }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.incoming ? "arrow.down.doc" : "arrow.up.doc").font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle).help(item.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BridgeFlowLayout(spacing: 8) {
                    Text(item.incoming ? "From phone" : "To phone")
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    Text(item.state).fontWeight(.medium)
                }.font(.caption).foregroundStyle(.secondary)
                if let queued, !queued.lastError.isEmpty { Text(queued.lastError).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if ["Sending", "Receiving", "Finishing", "Verifying"].contains(item.state) { ProgressView(value: item.progress) }
                if ["Sending", "Receiving", "Finishing"].contains(item.state) { TransferMetricsCaption(item: item) }
                if hasActions {
                    BridgeFlowLayout {
                        if item.state == "Accept to receive" { Button("Save…") { model.acceptTransfer(item.id) }.buttonStyle(.borderedProminent) }
                        if queued != nil {
                            if item.state == "Paused" { Button("Retry") { model.resumeTransfer(item.id) } }
                            else { Button("Pause") { model.pauseTransfer(item.id) } }
                        }
                        if !["Complete", "Cancelled", "Failed"].contains(item.state) { Button("Cancel") { model.cancelTransfer(item.id) } }
                        if let destination = savedFile { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) } }
                    }.controlSize(.small)
                }
            }
        }.bridgeCard()
    }
}
struct BridgeTransfersView: View {
    @EnvironmentObject var model: BridgeModel
    var body: some View {
        BridgeContentColumn {
            if model.transfers.isEmpty { BridgeEmptyState(title: "No transfers yet", detail: "Drop files from Finder or send them from Bridge on either device.", icon: "arrow.up.arrow.down") }
            else { ForEach(model.transfers) { BridgeTransferRow(item: $0) } }
        }
    }
}
struct BridgeNotificationsView: View {
    @EnvironmentObject var model: BridgeModel
    private var apps: [String] { Array(Set(model.notifications.map(\.displayApp))).sorted() }
    var body: some View {
        BridgeContentColumn {
            HStack {
                Text("Phone notifications").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshPhoneNotifications() }
                    .disabled(!model.connected || !model.mirrorNotifications)
            }
            if model.notifications.isEmpty { BridgeEmptyState(title: "No phone notifications", detail: "Allow notification access in Bridge on Android.", icon: "bell") }
            else {
                ForEach(apps, id: \.self) { app in
                    VStack(alignment: .leading, spacing: BridgeUI.spacing) {
                        HStack(spacing: 8) {
                            BridgePhoneAppIcon(data: model.notifications.first { $0.displayApp == app }?.appIconPNG)
                            Text(app).font(.headline).help(app)
                        }.padding(.top, 8)
                        ForEach(model.notifications.filter { $0.displayApp == app }) { BridgeNotificationRow(notification: $0, showApp: false) }
                    }
                }
            }
        }
    }
}
struct BridgeEmptyState: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 28).frame(maxWidth: .infinity).bridgeCard()
    }
}
struct BridgeClipboardRow: View {
    @EnvironmentObject var model: BridgeModel
    let entry: ClipboardHistoryEntry
    @StateObject private var ui: ClipboardRowUIState
    init(entry: ClipboardHistoryEntry, initiallyExpanded: Bool = false) {
        self.entry = entry
        _ui = StateObject(wrappedValue: ClipboardRowUIState(expanded: initiallyExpanded))
    }
    private var long: Bool { entry.text.count > 180 || entry.text.filter { $0 == "\n" }.count > 2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ui.expanded {
                ScrollView { BridgeSelectableText(text: entry.text).padding(.trailing, 6) }.frame(height: 220)
            } else { BridgeSelectableText(text: entry.text, lineLimit: 3) }
            BridgeFlowLayout {
                Text(entry.sourceName).lineLimit(1)
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute()).help(entry.date.formatted(date: .complete, time: .standard))
                if entry.pinned { Label("Pinned", systemImage: "pin.fill").foregroundStyle(.tint) }
            }.font(.caption).foregroundStyle(.secondary)
            BridgeFlowLayout {
                Button("Copy", systemImage: "doc.on.doc") { model.copyHistoryEntry(entry) }.help("Copy full text to the Mac clipboard")
                if long { Button(ui.expanded ? "Show less" : "Show more") { ui.expanded.toggle() } }
                Button { model.clipboardHistory.togglePin(entry.id) } label: { Image(systemName: entry.pinned ? "pin.slash" : "pin") }
                    .help(entry.pinned ? "Unpin entry" : "Pin entry").accessibilityLabel(entry.pinned ? "Unpin entry" : "Pin entry")
                Button(role: .destructive) { model.clipboardHistory.delete(entry.id) } label: { Image(systemName: "trash") }
                    .help("Delete entry").accessibilityLabel("Delete entry")
            }.controlSize(.small)
        }.bridgeCard()
    }
}
@MainActor private final class ClipboardRowUIState: ObservableObject { @Published var expanded: Bool; init(expanded: Bool = false) { self.expanded = expanded } }

struct BridgePhoneAppIcon: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: 24, height: 24).accessibilityHidden(true)
    }
}
