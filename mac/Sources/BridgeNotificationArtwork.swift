import Foundation
import UserNotifications
import ImageIO

/// Public notification attachments ensure phone artwork is present in banners,
/// independently of the system's cached leading application icon.
enum BridgeNotificationArtwork {
    static func decodeAppIcon(_ base64: String) -> Data? {
        guard !base64.isEmpty, base64.utf8.count <= 64_000,
              let data = Data(base64Encoded: base64), data.count <= 48_000,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...256).contains(width), (1...256).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return data
    }
    @discardableResult static func attach(to content: UNMutableNotificationContent, appIconPNG: Data? = nil) -> Bool {
        let artwork = appIconPNG ?? Bundle.main.url(forResource: "BridgeNotification", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
        guard let artwork else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeNotificationArtwork", isDirectory: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Bounded cleanup of abandoned staging images. Delivered attachments
            // are owned by UserNotifications, not this staging directory.
            for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                if let date = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate, date < Date().addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: old) }
            }
            try artwork.write(to: file, options: .atomic)
            let attachment = try UNNotificationAttachment(identifier: "bridge.phone.artwork", url: file, options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false, UNNotificationAttachmentOptionsTypeHintKey: "public.png"])
            content.attachments = [attachment]
            return true
        } catch {
            try? FileManager.default.removeItem(at: file)
            NSLog("Bridge notification artwork could not be attached: %@", error.localizedDescription)
            return false
        }
    }
}
