import Foundation
import Network
import Darwin

// Discovery only: no HTTPS probes, file offers, BLE identity collection or uploads.
func report(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line) }
}

var interfaces: UnsafeMutablePointer<ifaddrs>?
var hasAWDL = false
if getifaddrs(&interfaces) == 0 {
    var cursor = interfaces
    while let entry = cursor {
        if String(cString: entry.pointee.ifa_name) == "awdl0", entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET6) {
            hasAWDL = true
        }
        cursor = entry.pointee.ifa_next
    }
    freeifaddrs(interfaces)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args == ["--inventory-only"] || args.isEmpty ||
      (args.count == 2 && args[0] == "--seconds" && Double(args[1]).map { $0.isFinite && $0 >= 1 && $0 <= 60 } == true) else {
    fputs("Usage: probe-airdrop.sh [--inventory-only | --seconds 1…60]\n", stderr)
    exit(2)
}
report(["event": "inventory", "os": ProcessInfo.processInfo.operatingSystemVersionString, "awdlIPv6Present": hasAWDL])
if args == ["--inventory-only"] { exit(0) }

let seconds = args.isEmpty ? 10 : Double(args[1])!
let parameters = NWParameters()
parameters.includePeerToPeer = true
let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airdrop._tcp", domain: "local."), using: parameters)
var failed = false
var sawReady = false
var count = 0
browser.stateUpdateHandler = { state in
    switch state {
    case .ready: sawReady = true; report(["event": "browserReady"])
    case .failed(let error):
        failed = true
        report(["event": "browserFailed", "error": String(describing: error)])
        browser.cancel()
        exit(1)
    case .waiting(let error): report(["event": "browserWaiting", "error": String(describing: error)])
    default: break
    }
}
browser.browseResultsChangedHandler = { results, _ in
    count = results.count
    report(["event": "receivers", "count": count])
    for result in results {
        // Service instance names and addresses are intentionally omitted.
        var details: [String: Any] = ["event": "receiverCapabilities", "interfaces": result.interfaces.map(\.name).sorted()]
        if case .bonjour(let record) = result.metadata {
            details["txtKeys"] = record.dictionary.keys.sorted()
            if let flags = record.dictionary["flags"] { details["flags"] = flags }
        }
        report(details)
    }
}
browser.start(queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    browser.cancel()
    report(["event": "finished", "receiverCount": count, "browserWasReady": sawReady,
            "note": "Zero results do not prove AirDrop is unsupported; open the receiving device's AirDrop screen."])
    exit(failed || !sawReady ? 1 : 0)
}
dispatchMain()
