import Foundation
import Combine
import Darwin

struct DeveloperDevice: Identifiable, Sendable {
    let id: String
    let label: String
}
struct DeveloperCommandResult: Sendable {
    let status: Int32
    let output: String
}
enum DeveloperToolError: LocalizedError {
    case unavailable, unauthorized, unsafePath, failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Install Android platform-tools yourself to use ADB. Bridge does not install or enable debugging."
        case .unauthorized: return "Connect one USB phone and approve USB debugging on the phone first."
        case .unsafePath: return "Use a shared-storage path under /sdcard/ with letters, numbers, underscores, hyphens and periods only. Parent paths are not allowed."
        case .failed(let message): return message
        }
    }
}

// Deliberately USB-only. No wireless-debugging discovery, root, arbitrary shell,
// automatic dependency installation or server exposed by these tools.
enum DeveloperTools {
    static func executable(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent("Library/Android/sdk/platform-tools/\(name)").path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static func sharedPath(_ path: String) throws -> String {
        guard path.hasPrefix("/sdcard/"), path.utf8.count <= 1024,
              path.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.").contains($0) }),
              !path.split(separator: "/").contains("..") else { throw DeveloperToolError.unsafePath }
        return path
    }
    static func run(_ executable: URL, _ arguments: [String], timeout: Double = 15, binaryDestination: URL? = nil) throws -> DeveloperCommandResult {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("out"), err = scratch.appendingPathComponent("err")
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate(); Darwin.kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit(); deadline.cancel()
        let input = try FileHandle(forReadingFrom: out); defer { try? input.close() }
        let bytes = try input.read(upToCount: 1_048_576) ?? Data()
        let errorInput = try FileHandle(forReadingFrom: err); defer { try? errorInput.close() }
        let errors = try errorInput.read(upToCount: 65_536) ?? Data()
        let text = String(decoding: bytes, as: UTF8.self) + String(decoding: errors.prefix(65_536), as: UTF8.self)
        if let destination = binaryDestination, process.terminationStatus == 0 {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw DeveloperToolError.failed("Choose a new destination; an existing file will not be overwritten.") }
            try FileManager.default.copyItem(at: out, to: destination)
            return DeveloperCommandResult(status: 0, output: "Saved to " + destination.path + "\n" + String(decoding: errors.prefix(65_536), as: UTF8.self))
        }
        return DeveloperCommandResult(status: process.terminationStatus, output: text)
    }
    static func devices() throws -> [DeveloperDevice] {
        guard let adb = executable("adb") else { throw DeveloperToolError.unavailable }
        let result = try run(adb, ["devices", "-l"])
        guard result.status == 0 else { throw DeveloperToolError.failed(result.output) }
        return result.output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count > 2, fields[1] == "device", fields.contains(where: { $0.hasPrefix("usb:") }) else { return nil }
            let id = String(fields[0])
            guard !id.hasPrefix("-"), id.utf8.count <= 256 else { return nil }
            return DeveloperDevice(id: id, label: fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? id)
        }
    }
    static func command(device: String, arguments: [String], timeout: Double = 15, destination: URL? = nil) throws -> DeveloperCommandResult {
        guard try devices().contains(where: { $0.id == device }), let adb = executable("adb") else { throw DeveloperToolError.unauthorized }
        let result = try run(adb, ["-s", device] + arguments, timeout: timeout, binaryDestination: destination)
        guard result.status == 0 else { throw DeveloperToolError.failed(result.output.isEmpty ? "ADB command failed or timed out." : result.output) }
        return result
    }
}

@MainActor final class DeveloperConsole: ObservableObject {
    private let preview: Bool
    @Published var enabled = UserDefaults.standard.bool(forKey: "developerToolsEnabled") {
        didSet { if !preview { UserDefaults.standard.set(enabled, forKey: "developerToolsEnabled") }; if !enabled { devices = []; selected = ""; output = ""; hasCommandOutput = false } }
    }
    @Published var devices: [DeveloperDevice] = []
    @Published var selected = ""
    @Published var hasCommandOutput = false
    @Published var output = "Enable developer tools and connect an authorized USB device."
    @Published var busy = false
    @Published var path = "/sdcard/Download/"
    init(preview: Bool = false) {
        self.preview = preview
        if preview { enabled = true; output = "No authorized USB devices. Enable USB debugging in Android Developer options and approve this Mac on the phone." }
    }
    func refresh() {
        guard !preview, enabled, !busy else { return }; busy = true; hasCommandOutput = false
        Task {
            do {
                let found = try await Task.detached { try DeveloperTools.devices() }.value
                devices = found
                if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
                output = found.isEmpty ? "No authorized USB devices. Enable USB debugging in Android Developer options and approve this Mac on the phone." : "\(found.count) authorized USB device(s)."
            } catch { output = error.localizedDescription }
            busy = false
        }
    }
    func execute(_ arguments: [String], timeout: Double = 15, destination: URL? = nil) {
        guard enabled, !busy, !selected.isEmpty else { return }; busy = true; hasCommandOutput = true
        let device = selected
        Task {
            do {
                let result = try await Task.detached { try DeveloperTools.command(device: device, arguments: arguments, timeout: timeout, destination: destination) }.value
                output = result.output.isEmpty ? "Completed." : result.output
            } catch { output = error.localizedDescription }
            busy = false
        }
    }
    func browse() {
        do { execute(["shell", "ls", "-1", try DeveloperTools.sharedPath(path)]) }
        catch { output = error.localizedDescription }
    }
    func download(to destination: URL) {
        do { execute(["pull", try DeveloperTools.sharedPath(path), destination.path], timeout: 120) }
        catch { output = error.localizedDescription }
    }
}
