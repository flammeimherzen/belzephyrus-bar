public enum SystemHealth {
    public static func score(pressureLevel: Int, thermalState: Int, cpuCelsius: Double?) -> (value: Int, title: String) {
        var score = 100
        switch pressureLevel {
        case 4...: score -= 30
        case 2, 3: score -= 15
        default: break
        }
        switch thermalState {
        case 3...: score -= 25
        case 2: score -= 15
        case 1: score -= 8
        default: break
        }
        if let cpuCelsius {
            if cpuCelsius >= 95 { score -= 20 }
            else if cpuCelsius >= 80 { score -= 10 }
        }
        score = min(100, max(0, score))
        let title: String
        switch score {
        case 90...: title = "Excellent"
        case 75..<90: title = "Good"
        case 50..<75: title = "Fair"
        default: title = "Poor"
        }
        return (score, title)
    }
}

public enum CPUTime {
    /// `ri_user_time` is Mach absolute time. A tight loop on this Mac measured 100%
    /// after converting with `mach_timebase_info`, and 2.4% if the ticks were treated as nanoseconds.
    public static func percent(deltaTicks: UInt64, deltaWallTicks: UInt64) -> Double {
        guard deltaWallTicks > 0 else { return 0 }
        return Double(deltaTicks) / Double(deltaWallTicks) * 100
    }
}

public enum CounterDelta {
    public static func perSecond(previous: UInt64, current: UInt64, elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0, current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }
}

public enum ChargeEstimate {
    /// Capacities are mAh and amperage is mA. Returns seconds until `limit` (0...1), or nil when not charging toward it.
    public static func seconds(toLimit limit: Double, fullChargeMah: Double, remainingMah: Double, amperageMa: Double) -> Double? {
        guard amperageMa.isFinite, fullChargeMah.isFinite, remainingMah.isFinite, limit.isFinite, remainingMah >= 0, amperageMa > 1, fullChargeMah > 0, limit > 0, limit <= 1 else { return nil }
        let delta = fullChargeMah * limit - remainingMah
        if delta <= 0 { return 0 }
        return delta / amperageMa * 3600
    }
}

public enum RateFormat {
    public static func bytesPerSecond(_ bytes: Double) -> String {
        let value = max(bytes, 0)
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 10_000_000 { return String(format: "%.0f MB/s", value / 1_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }
}

public enum SMCAccess {
    public static func readFloat(_ key: String) -> Double? {
        var value = 0.0
        let code = key.withCString { SMCReadFloat($0, &value) }
        return code == 0 ? value : nil
    }

    public static func readUI8(_ key: String) -> UInt8? {
        var value: UInt8 = 0
        let code = key.withCString { SMCReadUI8($0, &value) }
        return code == 0 ? value : nil
    }

    public static func writeFloat(_ key: String, _ value: Double) -> Bool {
        key.withCString { SMCWriteFloat($0, value) } == 0
    }

    public static func writeUI8(_ key: String, _ value: UInt8) -> Bool {
        key.withCString { SMCWriteUI8($0, value) } == 0
    }

    public static func keys() -> [(key: String, type: String)] {
        let capacity = 5000
        let buffer = UnsafeMutablePointer<SMCKeyRecord>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let count = Int(SMCCopyKeys(buffer, Int32(capacity)))
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let record = buffer[index]
            return (key: string(record.key), type: string(record.type))
        }
    }

    private static func string(_ bytes: (CChar, CChar, CChar, CChar, CChar)) -> String {
        withUnsafePointer(to: bytes) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 5) { rebound in
                String(cString: rebound)
            }
        }
    }
}
