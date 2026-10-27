import Foundation

enum MenuBarViewModel {
    static func compactAmount(_ bytes: Int64, base: Double) -> String {
        guard bytes > 0, base > 1 else { return "0" }
        let value = Double(bytes)
        let tb = value / pow(base, 4)
        if tb >= 10 { return String(format: "%.0fT", tb) }
        if tb >= 1 { return String(format: "%.1fT", tb) }
        let gb = value / pow(base, 3)
        if gb >= 100 { return String(format: "%.0f", gb) }
        if gb >= 1 { return String(format: "%.1f", gb) }
        let mb = value / pow(base, 2)
        if mb >= 10 { return String(format: "%.0fM", mb) }
        if mb >= 1 { return String(format: "%.1fM", mb) }
        let kb = value / base
        if kb >= 10 { return String(format: "%.0fK", kb) }
        return String(format: "%.1fK", kb)
    }

    static func menuBarText(memory: MemoryStats?, disk: DiskStats?) -> (memory: String, swap: String?, disk: String) {
        let memoryText = memory.map { compactAmount($0.used, base: 1024) } ?? "…"
        let swapText: String?
        if let memory, memory.swapUsed > 0 {
            swapText = compactAmount(memory.swapUsed, base: 1024)
        } else {
            swapText = nil
        }
        let diskText = disk.map { compactAmount($0.used, base: 1000) } ?? "…"
        return (memoryText, swapText, diskText)
    }
}
