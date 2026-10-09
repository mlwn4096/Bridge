import Foundation
import Darwin

enum FolderArchiveError: LocalizedError {
    case unsafeEntry, tooLarge, tooManyFiles, cancelled, failed
    var errorDescription: String? {
        switch self {
        case .unsafeEntry: return "The folder contains a symbolic link or an unsafe file name."
        case .tooLarge: return "Folder archives must be smaller than 16 GiB."
        case .tooManyFiles: return "Folders may contain at most 10,000 files and directories."
        case .cancelled: return "Folder preparation was cancelled."
        case .failed: return "The folder could not be prepared for sending."
        }
    }
}

/// Creates a temporary ZIP snapshot. Caller removes the returned URL after transfer.
enum FolderArchive {
    static let maximumBytes: Int64 = 17_179_869_184
    static let maximumEntries = 10_000
    static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 &&
        !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func create(folder: URL, cancelled: () -> Bool = { false }) throws -> URL {
        let fm = FileManager.default
        guard let rootPath = canonicalPath(folder.path) else { throw FolderArchiveError.unsafeEntry }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              validComponent(root.lastPathComponent) else {
            throw FolderArchiveError.unsafeEntry
        }
        let work = fm.temporaryDirectory.appendingPathComponent("Bridge-Folder-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let snapshot = work.appendingPathComponent(root.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: false)
        var enumerationError: Error?
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw FolderArchiveError.failed }
        var total: Int64 = 0
        var count = 1
        for case let source as URL in entries {
            if cancelled() { throw FolderArchiveError.cancelled }
            count += 1
            guard count <= maximumEntries else { throw FolderArchiveError.tooManyFiles }
            let relative = String(source.path.dropFirst(root.path.count + 1))
            guard relative.utf8.count <= 4096, relative.split(separator: "/").count <= 128,
                  relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ validComponent(String($0)) }),
                  source.path == canonicalPath(source.path) else { throw FolderArchiveError.unsafeEntry }
            let info = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw FolderArchiveError.unsafeEntry }
            let destination = snapshot.appendingPathComponent(relative)
            if info.isDirectory == true {
                try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            } else if info.isRegularFile == true {
                let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw FolderArchiveError.unsafeEntry }
                let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var statInfo = stat()
                guard fstat(fd, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFREG else {
                    try? input.close(); throw FolderArchiveError.unsafeEntry
                }
                guard statInfo.st_size >= 0, statInfo.st_size <= maximumBytes - total else {
                    try? input.close(); throw FolderArchiveError.tooLarge
                }
                guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw FolderArchiveError.failed }
                let output = try FileHandle(forWritingTo: destination)
                do {
                    while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                        if cancelled() { throw FolderArchiveError.cancelled }
                        total += Int64(data.count)
                        guard total <= maximumBytes else { throw FolderArchiveError.tooLarge }
                        try output.write(contentsOf: data)
                    }
                    try output.close(); try input.close()
                } catch { try? output.close(); try? input.close(); throw error }
            } else { throw FolderArchiveError.unsafeEntry }
        }
        if let enumerationError { throw enumerationError }
        if cancelled() { throw FolderArchiveError.cancelled }
        let resultDirectory = fm.temporaryDirectory.appendingPathComponent("Bridge-Archive-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: resultDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let archive = resultDirectory.appendingPathComponent(root.lastPathComponent + ".zip")
        var success = false
        defer { if !success { try? fm.removeItem(at: resultDirectory) } }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", snapshot.path, archive.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
        while task.isRunning {
            if cancelled() { task.terminate(); task.waitUntilExit(); throw FolderArchiveError.cancelled }
            Thread.sleep(forTimeInterval: 0.05)
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw FolderArchiveError.failed }
        let size = (try fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= maximumBytes else { throw FolderArchiveError.tooLarge }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        success = true
        return archive
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func remove(_ archive: URL) {
        guard archive.deletingLastPathComponent().lastPathComponent.hasPrefix("Bridge-Archive-") else { return }
        try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
    }
}
