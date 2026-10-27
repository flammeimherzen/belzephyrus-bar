import Darwin
import Foundation

enum MachineInfo {
    static let chip: String = {
        if let brand = string("machdep.cpu.brand_string"), brand.contains("Apple") { return brand }
        return "Apple Silicon"
    }()

    static let modelIdentifier: String = string("hw.model") ?? ""

    static let memoryText: String = {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / 1024 / 1024 / 1024
        return String(format: "%.0f GiB", gb.rounded())
    }()

    static let coreCount: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.ncpu", &value, &size, nil, 0) == 0, value > 0 { return Int(value) }
        return ProcessInfo.processInfo.processorCount
    }()

    static let coreSummary: String = {
        var groups: [String] = []
        for level in 0..<4 {
            let prefix = "hw.perflevel\(level)"
            guard let name = string("\(prefix).name") else { continue }
            var count: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("\(prefix).logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
                groups.append("\(count) \(name)")
            }
        }
        return groups.isEmpty ? "\(coreCount) cores" : groups.joined(separator: " · ")
    }()

    static var osText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var uptimeText: String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return "up" }
        let seconds = max(Date().timeIntervalSince1970 - Double(boot.tv_sec), 0)
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return "up \(days) d, \(hours) hr" }
        if hours > 0 { return "up \(hours) hr, \(minutes) min" }
        return "up \(minutes) min"
    }

    static func pressureLevel() -> Int? {
        var value: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) != 0 { return nil }
        return Int(value)
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
