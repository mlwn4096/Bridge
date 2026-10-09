import AppKit

@MainActor final class BridgeServices: NSObject {
    private weak var model: BridgeModel?
    init(model: BridgeModel) { self.model = model }

    @objc(sendToPixel:userData:error:)
    func sendToPixel(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let model, model.paired != nil else {
            error.pointee = "Pair your Pixel in Bridge before sending. Files can queue while disconnected."; return
        }
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            if !model.sendFiles(files) { error.pointee = model.notice as NSString }
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            if !model.sendSelectedText(text) { error.pointee = model.notice as NSString }
        } else {
            error.pointee = "Select local files or text to send to your Pixel."
        }
    }
}
