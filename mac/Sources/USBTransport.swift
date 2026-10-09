import Foundation

// ADB's USB-only device listing excludes wireless-debugging transports. The
// tunnel carries the existing pinned TLS protocol, not shell/file commands.
final class USBTransport {
    private let queue = DispatchQueue(label: "Bridge.usb", qos: .utility)
    private var timer: DispatchSourceTimer?
    func start(port: UInt16) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 4)
        timer.setEventHandler { [weak self] in self?.refresh(port: port) }
        self.timer = timer; timer.resume()
    }
    private func refresh(port: UInt16) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path, "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        guard let adb = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let listing = run(adb, ["devices", "-l"]) else { return }
        let devices = listing.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count > 2, fields[1] == "device", fields.contains(where: { $0.hasPrefix("usb:") }) else { return nil }
            return String(fields[0])
        }
        // Avoid routing ambiguously when multiple phones are plugged in.
        guard devices.count == 1 else { return }
        let mapping = run(adb, ["-s", devices[0], "reverse", "--list"]) ?? ""
        let exists = mapping.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.count >= 2 && fields[fields.count - 2] == "tcp:38473" && fields.last == "tcp:\(port)"
        }
        if !exists { _ = run(adb, ["-s", devices[0], "reverse", "tcp:38473", "tcp:\(port)"]) }
    }
    private func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
    deinit { timer?.cancel() }
}
