import Foundation

@main
struct FolderArchiveTests {
    static func main() throws {
        for name in ["", ".", "..", "a/b", "a\\b", "a:b", "a\n", String(repeating: "x", count: 256)] {
            precondition(!FolderArchive.validComponent(name), "Unsafe component accepted: \(name)")
        }
        for name in ["Photos", "holiday 2026", "🌉", "a..b", "-folder"] {
            precondition(FolderArchive.validComponent(name))
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Sample")
        try fm.createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try Data("hello bridge".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let archive = try FolderArchive.create(folder: folder)
        precondition(archive.lastPathComponent == "Sample.zip")
        let output = directory.appendingPathComponent("Extracted")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, output.path]
        try task.run(); task.waitUntilExit()
        precondition(task.terminationStatus == 0)
        let received = try Data(contentsOf: output.appendingPathComponent("Sample/notes.txt"))
        precondition(received == Data("hello bridge".utf8))
        precondition(fm.fileExists(atPath: output.appendingPathComponent("Sample/Empty").path))
        FolderArchive.remove(archive)
        precondition(!fm.fileExists(atPath: archive.path))
        do { _ = try FolderArchive.create(folder: folder, cancelled: { true }); preconditionFailure("Cancellation ignored") }
        catch FolderArchiveError.cancelled { }
        let huge = folder.appendingPathComponent("huge.bin")
        precondition(fm.createFile(atPath: huge.path, contents: nil))
        let hugeHandle = try FileHandle(forWritingTo: huge)
        try hugeHandle.truncate(atOffset: UInt64(FolderArchive.maximumBytes + 1)); try hugeHandle.close()
        do { _ = try FolderArchive.create(folder: folder); preconditionFailure("Oversized folder accepted") }
        catch FolderArchiveError.tooLarge { }
        try fm.removeItem(at: huge)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("unsafe-link"), withDestinationURL: directory)
        do { _ = try FolderArchive.create(folder: folder); preconditionFailure("Symlink accepted") }
        catch FolderArchiveError.unsafeEntry { }
        print("Passed folder archive path, round-trip, empty directory, cleanup, cancellation, and symlink checks")
    }
}
