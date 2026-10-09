import Foundation
import IOKit.ps

/// A snapshot shared only with the authenticated phone. No serial numbers,
/// account names, installed apps or other hardware identifiers are included.
enum BridgeLocalDeviceInfo {
    static func hardwareString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
    static func snapshot() -> [String: Any] {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        var result: [String: Any] = [
            "model": hardwareString("hw.model"), "os": "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "chip": hardwareString("machdep.cpu.brand_string"), "cores": process.processorCount,
            "memoryTotal": process.physicalMemory, "batteryPresent": false
        ]
        if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            if let total = values.volumeTotalCapacity { result["storageTotal"] = total }
            if let free = values.volumeAvailableCapacityForImportantUsage { result["storageFree"] = free }
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let value = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      value["Type"] as? String == "InternalBattery",
                      let current = value["Current Capacity"] as? Int,
                      let maximum = value["Max Capacity"] as? Int, maximum > 0 else { continue }
                result["batteryPresent"] = true
                result["battery"] = min(100, max(0, current * 100 / maximum))
                result["charging"] = value["Is Charging"] as? Bool ?? false
                result["onAC"] = value["Power Source State"] as? String == "AC Power"
                break
            }
        }
        return result
    }
}
