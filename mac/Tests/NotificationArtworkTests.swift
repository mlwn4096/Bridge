import Foundation
import CoreGraphics
import ImageIO
import UserNotifications

@main struct NotificationArtworkTests {
    static func png(size: Int) -> Data {
        let pixels = Data(repeating: 255, count: size * size * 4)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let result = NSMutableData()
        let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return result as Data
    }
    static func main() throws {
        precondition(NotificationReplyPolicy.validText("Hello 👋\nSecond line"))
        precondition(NotificationReplyPolicy.validText(String(repeating: "a", count: 4096)))
        precondition(NotificationReplyPolicy.validText(String(repeating: "👋", count: 1024)))
        for invalid in ["", " \n\t", "hi\0", String(repeating: "a", count: 4097), String(repeating: "👋", count: 1025)] {
            precondition(!NotificationReplyPolicy.validText(invalid))
        }
        let reply = WireMessage("notificationReply", ["key": "notification-key", "actionID": UUID().uuidString, "text": "Hello 👋\nSecond line"])
        let decodedReply = try WireMessage(data: Data(reply.data().dropLast()))
        precondition(decodedReply.string("text") == "Hello 👋\nSecond line")
        let icon = png(size: 96)
        precondition(BridgeNotificationArtwork.decodeAppIcon(icon.base64EncodedString()) == icon)
        for invalid in ["", "not base64", Data("not a png".utf8).base64EncodedString(), String(repeating: "A", count: 64_001), png(size: 257).base64EncodedString(), Data(icon.prefix(24)).base64EncodedString()] {
            precondition(BridgeNotificationArtwork.decodeAppIcon(invalid) == nil)
        }
        // Every banner needs its own attachment: UserNotifications owns/moves
        // the source file, so repeated notifications cannot reuse one URL.
        let message = WireMessage("notification", ["appIconPNG": icon.base64EncodedString(), "app": "Test app"])
        let roundTrip = try WireMessage(data: Data(message.data().dropLast()))
        precondition(BridgeNotificationArtwork.decodeAppIcon(roundTrip.string("appIconPNG")) == icon)
        let local = BridgeLocalDeviceInfo.snapshot()
        precondition((local["memoryTotal"] as? UInt64 ?? 0) > 0)
        precondition((local["os"] as? String ?? "").hasPrefix("macOS "))
        precondition(local["batteryPresent"] is Bool)
        if !CommandLine.arguments.contains("--system-attachments") {
            print("Passed valid/missing/malformed/oversized app icon, wire round-trip and local Mac snapshot checks")
            return
        }
        let first = UNMutableNotificationContent()
        let second = UNMutableNotificationContent()
        BridgeNotificationArtwork.attach(to: first, appIconPNG: icon)
        BridgeNotificationArtwork.attach(to: second, appIconPNG: icon)
        precondition(first.attachments.count == 1 && second.attachments.count == 1)
        let one = first.attachments[0].url, two = second.attachments[0].url
        precondition(one != two)
        let firstBytes = try Data(contentsOf: one), secondBytes = try Data(contentsOf: two)
        precondition(firstBytes == icon && secondBytes == icon)
        try? FileManager.default.removeItem(at: one)
        try? FileManager.default.removeItem(at: two)
        print("Passed valid/missing/malformed/oversized app icon and repeated banner attachment checks")
    }
}
