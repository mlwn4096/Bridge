import SwiftUI
import AppKit

@main
struct RenderPreview {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/qa", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = BridgeModel(preview: true)
        model.paired = nil
        model.address = "192.168.1.20"; model.localPort = 51234
        model.pairingURL = "bridge://pair?host=192.168.1.20&port=51234&fingerprint=preview&token=preview-only&name=Mac"
        try render(BridgeOnboarding().environmentObject(model), name: "mac-onboarding", scheme: .light, output: output)
        model.paired = PairedDevice(id: "preview", name: "Pixel 9 Pro")
        model.connected = true; model.status = "Connected"; model.battery = 78
        model.notifications = [PhoneNotification(id: "preview", app: "Messages", title: "Alex", body: "See you in ten minutes", date: Date())]
        model.mediaAvailable = true; model.mediaTitle = "A quieter kind of day"; model.mediaArtist = "Phone media"; model.mediaPlaying = true
        model.mediaActions = ["pause", "next", "previous"]
        try render(BridgeWindow().environmentObject(model), name: "mac-dashboard-light", scheme: .light, output: output)
        try render(BridgeWindow().environmentObject(model), name: "mac-dashboard-dark", scheme: .dark, output: output)

        print("Rendered native SwiftUI previews to \(output.path)")
    }
    @MainActor static func render<V: View>(_ view: V, name: String, scheme: ColorScheme, output: URL) throws {
        let content = view.frame(width: 920, height: 760).environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.97, green: 0.97, blue: 0.98))
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
}
