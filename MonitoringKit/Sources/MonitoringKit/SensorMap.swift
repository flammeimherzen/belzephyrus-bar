public enum ChipSensor: Sendable, Equatable {
    case cpu
    case gpu
}

public enum SensorMap {
    /// Keys measured on this Mac17,7 (M5 Max). Under an all-core CPU load, `Tm*`
    /// rose about 7°C, `Tp*` about 5°C, and `Tg*` about 2°C, so `Tm` is the CPU
    /// die and `Tg` is the GPU die. Other models use the same families when present.
    public static func classify(key: String, modelIdentifier: String) -> ChipSensor? {
        if modelIdentifier == "Mac17,7" {
            if key.hasPrefix("Tm") { return .cpu }
            if key.hasPrefix("Tg") { return .gpu }
            return nil
        }
        if key.hasPrefix("Tm") || key.hasPrefix("Tp") { return .cpu }
        if key.hasPrefix("Tg") { return .gpu }
        return nil
    }

    public static func select(keys: [(key: String, type: String)], modelIdentifier: String) -> (cpu: [String], gpu: [String]) {
        let floats = keys.filter { $0.type == "flt " || $0.type == "flt" }.map(\.key)
        if modelIdentifier == "Mac17,7" {
            return (floats.filter { $0.hasPrefix("Tm") }, floats.filter { $0.hasPrefix("Tg") })
        }
        let tm = floats.filter { $0.hasPrefix("Tm") }
        let tp = floats.filter { $0.hasPrefix("Tp") }
        let cpu = tm.count >= 4 ? tm : (tp.count >= 4 ? tp : tm + tp)
        return (cpu, floats.filter { $0.hasPrefix("Tg") })
    }

    public static func averageCelsius(_ values: [Double]) -> Double? {
        let sane = values.filter { $0 > 5 && $0 < 130 }
        guard !sane.isEmpty else { return nil }
        return sane.reduce(0, +) / Double(sane.count)
    }
}
