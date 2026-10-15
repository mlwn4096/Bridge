import AppKit
import SwiftUI

/// A nonactivating file/link destination. It never moves other apps' windows or reads the general clipboard.
@MainActor final class DragSendOverlay {
    private weak var model: BridgeModel?
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastDragChange = NSPasteboard(name: .drag).changeCount
    private var pressOrigin: NSPoint?
    private var showing = false
    private var screenFrame: NSRect?
    private var hideAfter = Date.distantPast
    init(model: BridgeModel) {
        self.model = model
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func poll() {
        guard let model else { timer?.invalidate(); return }
        let pasteboard = NSPasteboard(name: .drag)
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let point = NSEvent.mouseLocation
        if !model.dragSendEnabled || !model.connected { hide(); lastDragChange = pasteboard.changeCount; return }
        if !pressed {
            pressOrigin = nil; lastDragChange = pasteboard.changeCount
            if showing && Date() >= hideAfter { hide() }
            return
        }
        if pressOrigin == nil { pressOrigin = point }
        let origin = pressOrigin ?? point
        let moved = hypot(point.x - origin.x, point.y - origin.y) > 6
        if moved && pasteboard.changeCount != lastDragChange {
            let urls = DropFileView.urls(pasteboard)
            lastDragChange = pasteboard.changeCount
            if !urls.isEmpty || DropFileView.webLink(pasteboard) != nil { show(on: NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main) }
        }
        if showing {
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }), screen.frame != screenFrame { show(on: screen) }
            hideAfter = Date().addingTimeInterval(0.25)
        }
    }
    private func show(on screen: NSScreen?) {
        guard let screen, let model, model.connected else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            let view = DropFileView(model: model)
            view.onDrop = { [weak self] in self?.hideAfter = Date().addingTimeInterval(3) }
            panel.contentView = view
            self.panel = panel
        }
        let visible = screen.visibleFrame
        let width: CGFloat = 260, height: CGFloat = 116
        panel?.setFrame(NSRect(x: visible.maxX - width - 12, y: visible.maxY - height - 12, width: width, height: height), display: true)
        screenFrame = screen.frame
        if let view = panel?.contentView as? DropFileView { view.resetFeedback() }
        let alreadyVisible = showing
        if !alreadyVisible { panel?.alphaValue = 0 }
        panel?.orderFrontRegardless()
        if !alreadyVisible { NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel?.animator().alphaValue = 1
        } }
        showing = true
    }
    private func hide() { panel?.orderOut(nil); showing = false }
}

@MainActor final class DropFileView: NSView {
    private weak var model: BridgeModel?
    private var hosted: NSHostingView<DragSendCard>?
    var onDrop: (() -> Void)?
    private var feedback = ""
    private var targeted = false { didSet { refresh() } }
    init(model: BridgeModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .URL, .string])
        let hosted = NSHostingView(rootView: DragSendCard(model: model, targeted: false, feedback: ""))
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        NSLayoutConstraint.activate([hosted.leadingAnchor.constraint(equalTo: leadingAnchor), hosted.trailingAnchor.constraint(equalTo: trailingAnchor), hosted.topAnchor.constraint(equalTo: topAnchor), hosted.bottomAnchor.constraint(equalTo: bottomAnchor)])
        self.hosted = hosted
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Send files or links to Pixel")
        setAccessibilityHelp("Drop local files or web links here to send them to your paired phone. You can also use Send files in Bridge’s menu.")
    }
    required init?(coder: NSCoder) { nil }
    static func urls(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter { $0.isFileURL }
    }
    static func webLink(_ pasteboard: NSPasteboard) -> LinkHandoff? {
        guard urls(pasteboard).isEmpty else { return nil }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL] ?? []
        guard objects.count <= 1 else { return nil }
        let raw = pasteboard.string(forType: .URL) ?? objects.first?.absoluteString ?? pasteboard.string(forType: .string)
        guard let raw else { return nil }
        return LinkHandoff(raw.trimmingCharacters(in: .whitespacesAndNewlines),
                           title: pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? "")
    }
    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard model?.connected == true else { return [] }
        if !Self.urls(sender.draggingPasteboard).isEmpty {
            return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
        }
        guard Self.webLink(sender.draggingPasteboard) != nil else { return [] }
        if sender.draggingSourceOperationMask.contains(.copy) { return .copy }
        return sender.draggingSourceOperationMask.contains(.link) ? .link : []
    }
    func resetFeedback() { feedback = ""; targeted = false; refresh() }
    private func refresh() { if let model { hosted?.rootView = DragSendCard(model: model, targeted: targeted, feedback: feedback) } }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = operation(sender); targeted = !accepted.isEmpty; return accepted
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !operation(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard model?.connected == true else { return false }
        targeted = false
        let files = Self.urls(sender.draggingPasteboard)
        let accepted: Bool
        if !files.isEmpty { accepted = model?.sendFiles(files) ?? false }
        else if let link = Self.webLink(sender.draggingPasteboard) { accepted = model?.sendWebLink(link.url.absoluteString, title: link.title) ?? false }
        else { accepted = false }
        feedback = accepted ? (files.isEmpty ? "Link sent to your phone" : (model?.connected == true ? "Files added to the send queue" : "Queued for your phone")) : (model?.notice ?? "Unable to send")
        refresh()
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: feedback, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        onDrop?()
        return accepted
    }
}

struct DragSendCard: View {
    @ObservedObject var model: BridgeModel
    let targeted: Bool
    let feedback: String
    var body: some View {
        HStack(spacing: 14) {
            Image(bridgeSymbol: targeted ? "arrow.right.circle.fill" : "smartphone")
                .font(.system(size: 30)).foregroundStyle(model.connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Send to \(model.paired?.name ?? "Pixel")").font(.headline).lineLimit(2)
                Text(feedback.isEmpty ? (model.connected ? (targeted ? "Release to send" : "Drop files / links here") : "Drop files to queue for your phone") : feedback)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: targeted ? 2 : 1) }
            .accessibilityElement(children: .combine)
    }
}
