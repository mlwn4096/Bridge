import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BridgeSupportView: View {
    @StateObject private var ui = SupportPageState()
    var body: some View {
        BridgeContentColumn {
            VStack(alignment: .leading, spacing: 8) {
                Image(bridgeSymbol: "questionmark.circle.fill").font(.largeTitle).foregroundStyle(.tint)
                Text("How can we help?").font(.title.bold())
                Text("Help make Bridge better.").foregroundStyle(.secondary)
            }.padding(.vertical, 12)
            VStack(spacing: 0) {
                row("Report a bug", detail: "Tell us what went wrong", icon: "ladybug", color: .orange) { ui.form = "bug" }
                Divider()
                row("Suggest a feature", detail: "Share an idea for Bridge", icon: "lightbulb", color: .blue) { ui.form = "feature" }
            }.bridgeCard()
            VStack(spacing: 0) {
                Link(destination: URL(string: "https://buymeacoffee.com/mlwn")!) {
                    linkRow("Buy me a coffee", detail: "Support independent development", icon: "cup.and.saucer.fill")
                }
                Divider()
                Link(destination: URL(string: "https://mlwn.in")!) {
                    linkRow("About the creator", detail: "MLWN · Visit mlwn.in", icon: "person.crop.circle.fill")
                }
            }.buttonStyle(.plain).bridgeCard()
            Text("Bridge is made by MLWN to bring your Mac and Android closer together.").font(.callout).foregroundStyle(.secondary)
        }.sheet(item: Binding(get: { ui.form.map { SupportKind(id: $0) } }, set: { ui.form = $0?.id })) { kind in
            BridgeSupportForm(bug: kind.id == "bug", draft: kind.id == "bug" ? ui.bugDraft : ui.featureDraft)
        }
    }
    private func row(_ title: String, detail: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { linkRow(title, detail: detail, icon: icon).foregroundStyle(color) }.buttonStyle(.plain)
    }
    private func linkRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(bridgeSymbol: icon).font(.title2).foregroundStyle(.tint).frame(width: 36)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline).foregroundStyle(.primary); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(bridgeSymbol: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 12).contentShape(Rectangle())
    }
}
private struct SupportKind: Identifiable { let id: String }
struct BridgeSupportForm: View {
    @Environment(\.dismiss) private var dismiss
    let bug: Bool
    @StateObject private var ui: SupportFormState
    init(bug: Bool, draft: SupportFormState? = nil) {
        self.bug = bug
        _ui = StateObject(wrappedValue: draft ?? SupportFormState())
    }
    private var valid: Bool {
        !ui.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ui.email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil &&
        !ui.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(bridgeSymbol: bug ? "ladybug.fill" : "lightbulb.fill").foregroundStyle(bug ? .orange : .blue)
                Text(bug ? "Report a bug" : "Suggest a feature").font(.title2.bold())
                Spacer(); Button("Done") { dismiss() }
            }
            Text(bug ? "Describe what happened and how we can reproduce it. Name, email and description are required." : "Tell us what you’d like Bridge to do and why it would help. Name, email and description are required.").foregroundStyle(.secondary)
            Form {
                TextField("Full name", text: $ui.name)
                TextField("Email address", text: $ui.email)
                Section("Description") { TextEditor(text: $ui.description).frame(minHeight: 120) }
                TextField(bug ? "Steps to reproduce (optional)" : "How would you use it? (optional)", text: $ui.context)
                Section("Images (optional)") {
                    Button("Add images…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
                        if panel.runModal() == .OK { ui.images = Array(Set(ui.images + panel.urls)).prefix(5).map { $0 } }
                    }
                    ForEach(ui.images, id: \.self) { image in
                        HStack { Text(image.lastPathComponent).lineLimit(1); Spacer(); Button("Remove") { ui.images.removeAll { $0 == image } } }
                    }
                    Text("Up to 5 images. Review screenshots for personal information.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if !ui.feedback.isEmpty { Text(ui.feedback).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Save draft…", action: save).disabled(!valid); Button("Continue in Mail", action: compose).buttonStyle(.borderedProminent).disabled(!valid) }
            Text("Opens an email draft addressed to Bridge support. Review it and send from your mail app.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 440, idealWidth: 560, maxWidth: 680, minHeight: 480, idealHeight: 650)
    }
    private func compose() {
        guard let recipientData = Data(base64Encoded: "bWVsd2luc2FudGhvc2hAb3V0bG9vay5jb20="),
              let recipient = String(data: recipientData, encoding: .utf8),
              let service = NSSharingService(named: .composeEmail) else { ui.feedback = "Set up a mail app, or save a draft."; return }
        let body = "Full name: \(ui.name)\nEmail: \(ui.email)\nPlatform: macOS\n\nDescription:\n\(ui.description)\n\n\(bug ? "Steps to reproduce" : "Use case"):\n\(ui.context)"
        let items: [Any] = [body] + ui.images.map { $0 as Any }
        guard service.canPerform(withItems: items) else { ui.feedback = "Set up a mail app, or save a draft."; return }
        service.recipients = [recipient]
        service.subject = bug ? "Bridge bug report" : "Bridge feature suggestion"
        ui.mailService = service
        service.perform(withItems: items)
        ui.feedback = "Email draft opened. Send it from your mail app."
    }
    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = bug ? "Bridge Bug Report" : "Bridge Feature Suggestion"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: folder.path) else { ui.feedback = "Choose a new folder name."; return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let text = "\(bug ? "Bug report" : "Feature suggestion")\nFull name: \(ui.name)\nEmail: \(ui.email)\nPlatform: macOS\n\nDescription:\n\(ui.description)\n\n\(bug ? "Steps to reproduce" : "Use case"):\n\(ui.context)\n"
            try text.write(to: folder.appendingPathComponent("Request.txt"), atomically: true, encoding: .utf8)
            for (index, image) in ui.images.enumerated() { try FileManager.default.copyItem(at: image, to: folder.appendingPathComponent("\(index + 1)-\(image.lastPathComponent)")) }
            ui.feedback = "Draft saved."
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { ui.feedback = error.localizedDescription }
    }
}

@MainActor final class SupportPageState: ObservableObject {
    @Published var form: String?
    let bugDraft = SupportFormState()
    let featureDraft = SupportFormState()
}
@MainActor final class SupportFormState: ObservableObject {
    var mailService: NSSharingService?
    @Published var name = ""
    @Published var email = ""
    @Published var description = ""
    @Published var context = ""
    @Published var images: [URL] = []
    @Published var feedback = ""
}
