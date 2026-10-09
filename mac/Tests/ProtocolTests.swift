import Foundation
import Security
import Network

@main struct ProtocolTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError("FAILED: " + description) }; count += 1
        }
        func rejects(_ description: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAILED: expected rejection: " + description) }
            catch { count += 1 }
        }
        for value in ["123456", "password=example", "-----BEGIN PRIVATE KEY-----", "ghp_abcdefghijklmnopqrstuvwxyz", "4111 1111 1111 1111", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"] {
            check(ClipboardProtection.reason(value) != nil, "likely secret detected")
        }
        for value in ["Hello Pixel 👋", "https://example.com/article", "Meeting at 4 PM", "4111 1111 1111 1112", "0000000000000000"] {
            check(ClipboardProtection.reason(value) == nil, "ordinary text or invalid card allowed")
        }
        let handoffTime = Date(timeIntervalSince1970: 1000)
        let page = LinkHandoff("https://example.com/article#section", title: "A shared article", now: handoffTime)
        check(page?.title == "A shared article", "handoff preserves shared page title")
        check(page?.host == "example.com", "handoff displays destination host")
        check(page?.url.fragment == "section", "handoff preserves fragment context")
        check(page?.expired(at: handoffTime.addingTimeInterval(599)) == false, "handoff available before expiry")
        check(page?.expired(at: handoffTime.addingTimeInterval(600)) == true, "handoff expires at ten minutes")
        check(LinkHandoff("https://example.com", title: "password=example")?.title == "example.com", "sensitive title suppressed")
        check(LinkHandoff("https://example.com", title: "Hello\nworld")?.title == "Helloworld", "control characters removed from title")
        for invalid in ["javascript:alert(1)", "file:///tmp/example", "https://user:password@example.com", "https://example.com/\npage", "https://", "https://example.com/" + String(repeating: "a", count: 8200)] {
            check(LinkHandoff(invalid) == nil, "unsafe or malformed handoff rejected")
        }
        let shareTime = Date(timeIntervalSince1970: 100_000)
        func share(_ files: [String] = [], text: String = "", created: Double = 100_000, version: Int = 1) -> ShareManifest {
            ShareManifest(version: version, created: created, files: files, text: text)
        }
        try share(["Photo 🖼.jpg", "report.pdf"], text: "Some selected text").validate(now: shareTime)
        check(true, "share accepts supported mixed file and text payload")
        try share(text: "Text only").validate(now: shareTime)
        check(true, "share accepts text-only payload")
        rejects("empty share rejected") { try share().validate(now: shareTime) }
        rejects("unknown share version") { try share(text: "x", version: 2).validate(now: shareTime) }
        rejects("expired share") { try share(text: "x", created: 13_599).validate(now: shareTime) }
        rejects("future share") { try share(text: "x", created: 100_061).validate(now: shareTime) }
        rejects("nonfinite share date") { try share(text: "x", created: .nan).validate(now: shareTime) }
        rejects("share exceeds file limit") { try share(["a", "b", "c", "d"]).validate(now: shareTime) }
        rejects("duplicate share names") { try share(["a", "a"]).validate(now: shareTime) }
        for unsafe in ["../outside", ".hidden", "manifest.json", "consumed.json", "a/b", "a\\b"] {
            rejects("share rejects unsafe or reserved file name") { try share([unsafe]).validate(now: shareTime) }
        }
        rejects("share enforces UTF8 byte text limit") { try share(text: String(repeating: "🖼", count: 8193)).validate(now: shareTime) }
        try share(text: String(repeating: "a", count: WireMessage.maxClipboard)).validate(now: shareTime)
        check(true, "share accepts exact text byte limit")
        var history = ClipboardHistoryStore()
        let now = Date()
        history.record("password=secret", sourceID: "mac", sourceName: "Mac", now: now)
        check(history.entries.isEmpty, "sensitive history excluded")
        history.record("Meeting tomorrow", sourceID: "mac", sourceName: "Mac", now: now)
        history.record("Meeting tomorrow", sourceID: "mac", sourceName: "Mac", now: now)
        check(history.entries.count == 1, "same device duplicates coalesce")
        history.record("Meeting tomorrow", sourceID: "pixel", sourceName: "Pixel", now: now)
        check(history.entries.count == 2, "device provenance preserved")
        history.togglePin(history.entries[0].id)
        history.prune(now: now.addingTimeInterval(86400))
        check(history.entries.count == 1 && history.entries[0].pinned, "retention preserves pins")
        history.delete(history.entries[0].id)
        check(history.entries.isEmpty, "individual delete")
        for i in 0..<110 { history.record("Entry number \(i)", sourceID: "mac", sourceName: "Mac", now: now) }
        check(history.entries.count == 100, "history bounded")
        history.clear()
        check(history.entries.isEmpty, "clear removes all history")
        check(TransferRules.maxBytes == 17_179_869_184, "large-file transport cap")
        var rate = TransferRateEstimator(total: 1000, started: 0)
        check(rate.record(100, now: 1) && rate.rate == 100, "receiver rate initial sample")
        check(!rate.record(99, now: 2) && !rate.record(1001, now: 2), "reject receiver progress regression and overflow")
        check(!rate.record(200, now: 1), "reject backwards clock")
        check(rate.record(300, now: 2) && rate.rate == 125, "smoothed recent receiver rate")
        check(TransferTelemetry.remaining(size: 1000, progress: 0.5, speed: 100) == "~5s left", "ETA from remaining bytes")
        check(TransferTelemetry.remaining(size: 1000, progress: 1, speed: 100) == nil, "no ETA when awaiting verification")
        check(TransferTelemetry.remaining(size: 1000, progress: 0, speed: 0) == nil, "no invented ETA before speed")
        let binaryID = "00112233-4455-6677-8899-aabbccddeeff"
        let binaryChunk = BinaryFileChunk(transferID: binaryID, sequence: 2, data: Data([0, 10, 255]))
        let binaryFrame = try binaryChunk.encoded()
        check(binaryFrame.count == 52 && binaryFrame.prefix(5) == Data([0, 0, 0, 0, 47]), "binary frame header and length")
        var transportDecoder = TransportFrameDecoder()
        var transportFrames: [TransportFrame] = []
        let mixed = try WireMessage("ping").data() + binaryFrame + WireMessage("pong").data()
        for byte in mixed { transportFrames += try transportDecoder.append(Data([byte])) }
        check(transportFrames.count == 3, "fragmented mixed binary/control stream")
        if case .file(let decodedChunk) = transportFrames[1] {
            check(decodedChunk.transferID == binaryID && decodedChunk.sequence == 2 && decodedChunk.data == Data([0, 10, 255]), "binary preserves newline/NUL/ff bytes")
        } else { fatalError("Expected binary frame") }
        var oversizedBinaryDecoder = TransportFrameDecoder()
        rejects("oversized binary length before allocation") { _ = try oversizedBinaryDecoder.append(Data([0, 127, 255, 255, 255])) }
        var emptyBinaryDecoder = TransportFrameDecoder()
        rejects("empty binary chunk rejected") { _ = try emptyBinaryDecoder.append(Data([0, 0, 0, 0, 44])) }
        rejects("negative binary sequence") { _ = try BinaryFileChunk(transferID: binaryID, sequence: -1, data: Data([1])).encoded() }
        let fullChunk = BinaryFileChunk(transferID: binaryID, sequence: 0, data: Data(repeating: 10, count: BinaryFileChunk.maxData))
        var fullDecoder = TransportFrameDecoder()
        let fullFrame = try fullChunk.encoded()
        let fullFrames = try fullDecoder.append(fullFrame)
        check(fullFrames.count == 1, "maximum binary chunk round trip")
        let clipboard = WireMessage("clipboard", ["text": "Hello Pixel 👋\nMac → Android"])
        func batteryDecision(_ level: Int, charging: Bool = false, enabled: Bool = true, latched: Bool = false) -> BatteryAlertDecision {
            BatteryAlertDecision.evaluate(level: level, charging: charging, enabled: enabled, threshold: 20, latched: latched)
        }
        check(batteryDecision(20).notify, "threshold crossing alerts")
        check(!batteryDecision(19, latched: true).notify, "repeated low readings do not alert")
        check(!batteryDecision(15, charging: true).notify, "charging suppresses low alert")
        check(!batteryDecision(15, enabled: false).notify, "disabled alerts remain silent")
        check(batteryDecision(25, latched: true).latched, "small battery fluctuations do not rearm")
        check(!batteryDecision(26, latched: true).latched, "recovery rearms next low episode")
        check(!batteryDecision(-1).notify && !batteryDecision(101).notify, "invalid readings do not alert")
        let encoded = try clipboard.data()
        let decoded = try WireMessage(data: encoded.dropLast())
        check(decoded.string("text") == clipboard.string("text"), "Unicode round trip")
        check(decoded.id == clipboard.id, "message identity preserved")
        for boundary in 1..<encoded.count {
            var decoder = FrameDecoder()
            let first = try decoder.append(encoded.prefix(boundary))
            let last = try decoder.append(encoded.dropFirst(boundary))
            check(first.isEmpty && last.count == 1 && last[0].type == "clipboard", "split at byte \(boundary)")
        }
        var decoder = FrameDecoder()
        let messages = try decoder.append(try WireMessage("ping").data() + WireMessage("pong").data())
        check(messages.map(\.type) == ["ping", "pong"], "multiple frames")
        rejects("oversized frame") { var decoder = FrameDecoder(); _ = try decoder.append(Data(repeating: 65, count: WireMessage.maxFrame + 1)) }
        rejects("incompatible protocol") { _ = try WireMessage(data: Data("{\"v\":2,\"type\":\"ping\",\"id\":\"a\",\"payload\":{}}".utf8)) }
        rejects("wrong payload type") { _ = try WireMessage(data: Data("{\"v\":1,\"type\":\"ping\",\"id\":\"a\",\"payload\":[]}".utf8)) }
        rejects("empty frame") { var decoder = FrameDecoder(); _ = try decoder.append(Data([10])) }
        rejects("oversized outbound payload") { _ = try WireMessage("clipboard", ["text": String(repeating: "a", count: WireMessage.maxFrame)]).data() }
        for name in ["../secret", "..", ".", "a/b", "a\\b", "a\0b", String(repeating: "a", count: 241)] {
            check(!TransferRules.validName(name), "unsafe name rejected")
        }
        check(TransferRules.validName("My photo 🖼.png"), "normal filename accepted")
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let receiveFolder = folder.appendingPathComponent("receive-collision-tests")
        try FileManager.default.createDirectory(at: receiveFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: receiveFolder) }
        let first = try TransferRules.availableDestination(in: receiveFolder, name: "photo.jpg")
        check(first.lastPathComponent == "photo.jpg", "original receive name used")
        try Data("preserve".utf8).write(to: first)
        let second = try TransferRules.availableDestination(in: receiveFolder, name: "photo.jpg")
        check(second.lastPathComponent == "photo (1).jpg", "existing file collision avoided")
        let third = try TransferRules.availableDestination(in: receiveFolder, name: "photo.jpg", reserved: [second])
        check(third.lastPathComponent == "photo (2).jpg", "concurrent receive collision avoided")
        let preserved = try String(contentsOf: first, encoding: .utf8)
        check(preserved == "preserve", "existing receive untouched")
        rejects("receive path traversal") { _ = try TransferRules.availableDestination(in: receiveFolder, name: "../secret") }
        let vector = folder.appendingPathComponent("hash-vector.txt"); try Data("abc".utf8).write(to: vector)
        let digest = try TransferRules.hashFile(vector)
        check(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "known SHA256 vector")
        check(TransferRules.validHash(digest), "hash validation")
        check(!TransferRules.validHash("../../file"), "invalid hash")
        let secret = randomSecret(); check(Data(base64Encoded: secret)?.count == 32, "secure random size")
        check(constantTimeEqual(secret, secret), "credential equality")
        check(!constantTimeEqual(secret, randomSecret()), "different credential rejected")
        let trustDirectory = folder.appendingPathComponent("trust-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: trustDirectory) }
        let deviceID = UUID().uuidString
        let store = PairingTrustStore(directory: trustDirectory)
        let initialTrust = try store.read(deviceID)
        check(initialTrust == nil, "unenrolled phone has no trust")
        try store.write(deviceID, credential: secret)
        let trust = try PairingTrustStore(directory: trustDirectory).read(deviceID)!
        check(trust.matches(deviceID: deviceID, credential: secret), "credential survives store restart")
        check(!trust.matches(deviceID: deviceID, credential: randomSecret()), "wrong phone credential rejected")
        check(!trust.matches(deviceID: UUID().uuidString, credential: secret), "trust bound to device")
        check(!trust.matches(deviceID: deviceID, credential: "malformed"), "malformed credential rejected")
        let anotherTrust = try PairingTrustRecord(deviceID: deviceID, credential: secret)
        check(trust.salt != anotherTrust.salt && trust.digest != anotherTrust.digest, "independent enrollment salts")
        let trustFile = trustDirectory.appendingPathComponent(deviceID + ".json")
        let serialized = try String(contentsOf: trustFile, encoding: .utf8)
        check(!serialized.contains(secret), "raw credential never persisted")
        let trustPermissions = try FileManager.default.attributesOfItem(atPath: trustFile.path)[.posixPermissions] as? NSNumber
        check(trustPermissions?.intValue == 0o600, "trust owner-only permissions")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: trustFile.path)
        rejects("unsafe trust permissions") { _ = try store.read(deviceID) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trustFile.path)
        try Data("corrupt".utf8).write(to: trustFile)
        rejects("corrupt trust fails closed") { _ = try store.read(deviceID) }
        try store.delete(deviceID)
        let revokedTrust = try store.read(deviceID)
        check(revokedTrust == nil, "unpair revokes trust")
        rejects("invalid trust identifier") { try store.write("../peer", credential: secret) }
        rejects("invalid enrollment credential") { try store.write(deviceID, credential: "short") }
        let queueDirectory = folder.appendingPathComponent("queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: queueDirectory) }
        let source = folder.appendingPathComponent("queued-" + UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("queued content".utf8).write(to: source)
        let queue = try OutgoingQueueStore(directory: queueDirectory)
        var entry = try queue.enqueue([source], deviceID: deviceID)[0]
        let reopenedQueue = try OutgoingQueueStore(directory: queueDirectory)
        check(reopenedQueue.entries.count == 1 && reopenedQueue.entries[0].id == entry.id, "queue survives restart")
        let validSource = try queue.validateSource(entry)
        check(validSource == source, "original queued source is verified")
        entry.paused = true; entry.attempts = 2; try queue.replace(entry)
        let pausedQueue = try OutgoingQueueStore(directory: queueDirectory)
        check(pausedQueue.entries[0].paused && pausedQueue.entries[0].attempts == 2, "queue pause and retry state survive restart")
        let rejection = try queue.pauseAfterRejection(entry.id, reason: "Receiver busy")
        check(rejection?.paused == true && rejection?.lastError == "Receiver busy", "receiver rejection pauses instead of deleting")
        let rejectedQueue = try OutgoingQueueStore(directory: queueDirectory)
        check(rejectedQueue.entries.count == 1 && FileManager.default.fileExists(atPath: source.path), "receiver rejection retains queue and source across restart")
        let missingRejection = try queue.pauseAfterRejection(UUID().uuidString, reason: "Unknown")
        check(missingRejection == nil && queue.entries.count == 1, "unknown rejection does not affect another transfer")
        entry.paused = false; entry.attempts = 0; try queue.replace(entry)
        let failureTime = Date(timeIntervalSince1970: 1000)
        for attempt in 1...3 {
            let failed = try queue.recordFailure(entry.id, reason: "Receiver disk full", now: failureTime)!
            check(failed.attempts == attempt && failed.paused == (attempt == 3), "receiver failures use bounded retries")
            check(failed.retryAfter == failureTime.addingTimeInterval(Double(attempt * 15)), "receiver failure backoff")
            let restored = try OutgoingQueueStore(directory: queueDirectory)
            check(restored.entries[0].attempts == attempt && FileManager.default.fileExists(atPath: source.path), "receiver failure retains queue and source after restart")
        }
        let lateFailure = try queue.recordFailure(UUID().uuidString, reason: "Late failure")
        check(lateFailure == nil && queue.entries.count == 1, "inactive failure leaves queue unchanged")
        try Data("changed queued content".utf8).write(to: source)
        rejects("changed queue source") { _ = try queue.validateSource(entry) }
        try queue.remove(entry.id)
        check(queue.entries.isEmpty, "cancel removes durable queue entry")
        rejects("queue path traversal device") { _ = try queue.enqueue([source], deviceID: "../phone") }
        _ = try queue.enqueue(Array(repeating: source, count: 100), deviceID: deviceID)
        rejects("bounded queue") { _ = try queue.enqueue([source], deviceID: deviceID) }
        try queue.clear(deviceID: deviceID)
        check(queue.entries.isEmpty, "unpair clears only target queue")
        _ = try queue.enqueue([source], deviceID: deviceID, epoch: "new-pair")
        queue.quarantine()
        rejects("quarantined queue cannot restart") { _ = try OutgoingQueueStore(directory: queueDirectory) }
        let resetQueue = try OutgoingQueueStore(directory: queueDirectory, resetBlocked: true)
        check(resetQueue.entries.isEmpty && FileManager.default.fileExists(atPath: source.path), "reset blocked queue retains original files")
        let snapshots = try resetQueue.snapshotImports([source], cancelled: { false })
        let owned = try resetQueue.enqueue(snapshots, deviceID: deviceID, ownedCopy: true, epoch: "new-pair")[0]
        let copiedData = try Data(contentsOf: snapshots[0]), originalData = try Data(contentsOf: source)
        check(copiedData == originalData, "import snapshot preserves contents")
        resetQueue.removeOwnedCopy(owned)
        check(!FileManager.default.fileExists(atPath: snapshots[0].path) && FileManager.default.fileExists(atPath: source.path), "owned cleanup leaves original intact")
        rejects("cancelled import snapshot") { _ = try resetQueue.snapshotImports([source], cancelled: { true }) }
        let receiptsDomain = "BridgeReceiptTests." + UUID().uuidString
        let receiptDefaults = UserDefaults(suiteName: receiptsDomain)!
        defer { receiptDefaults.removePersistentDomain(forName: receiptsDomain) }
        let receipts = TransferReceiptStore(defaults: receiptDefaults)
        receipts.record(peer: deviceID, id: entry.id, name: entry.name, size: entry.size, hash: digest)
        check(TransferReceiptStore(defaults: receiptDefaults).matches(peer: deviceID, id: entry.id, name: entry.name, size: entry.size, hash: digest), "completion receipt survives restart")
        check(!receipts.matches(peer: UUID().uuidString, id: entry.id, name: entry.name, size: entry.size, hash: digest), "receipt isolated by paired device")
        check(!receipts.matches(peer: deviceID, id: entry.id, name: entry.name, size: entry.size + 1, hash: digest), "receipt bound to file metadata")
        receipts.revoke(peer: deviceID)
        check(!receipts.matches(peer: deviceID, id: entry.id, name: entry.name, size: entry.size, hash: digest), "unpair revokes completion receipt")
        let identityDirectory = folder.appendingPathComponent("test-identity")
        let identity = try DeviceIdentity.load(in: identityDirectory)
        let reloaded = try DeviceIdentity.load(in: identityDirectory)
        check(identity.fingerprint == reloaded.fingerprint, "identity survives reload")
        check(TransferRules.validHash(identity.fingerprint), "certificate fingerprint format")
        check(sec_identity_create(identity.identity) != nil, "Network TLS identity usable")
        check(!FileManager.default.fileExists(atPath: identityDirectory.appendingPathComponent("identity-key.pem").path), "temporary private key removed")
        let permissions = try FileManager.default.attributesOfItem(atPath: identityDirectory.appendingPathComponent("tls-identity-v1.p12").path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "private identity file permissions")
        try FileManager.default.removeItem(at: identityDirectory)
        let cancelFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("test".utf8).write(to: cancelFile)
        rejects("cancelled file hashing") { _ = try TransferRules.hashFile(cancelFile, shouldCancel: { true }) }
        try FileManager.default.removeItem(at: cancelFile)
        print("Passed \(count) framing, validation, hashing, and TLS identity checks")
    }
}
