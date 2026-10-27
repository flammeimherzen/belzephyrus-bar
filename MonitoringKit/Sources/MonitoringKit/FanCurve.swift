public enum FanMode: Int, Sendable, Equatable, CaseIterable {
    case auto = 0
    case cool = 1
    case max = 2

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .cool: "Cool"
        case .max: "Max"
        }
    }
}

public enum FanCurve {
    /// Cool mode holds `floor` percent until 55°C, then climbs to 100% at 85°C.
    public static func percent(celsius: Double, floor: Int) -> Double {
        let base = Double(min(max(floor, 0), 100))
        if celsius <= 55 { return base }
        if celsius >= 85 { return 100 }
        let span = (celsius - 55) / 30
        return base + (100 - base) * span
    }

    /// Speed-up is immediate. Slow-down is limited to `maxDrop` percent per tick.
    public static func smoothed(current: Double, target: Double, maxDrop: Double) -> Double {
        if target >= current { return target }
        return max(target, current - max(maxDrop, 0))
    }

    public static func rpm(percent: Double, minimum: Double, maximum: Double) -> Double {
        let span = max(maximum - minimum, 0)
        let fraction = min(max(percent, 0), 100) / 100
        return min(max(minimum + span * fraction, minimum), maximum)
    }

    public static func percent(rpm: Double, minimum: Double, maximum: Double) -> Double {
        let span = maximum - minimum
        guard span > 1 else { return 0 }
        return min(max((rpm - minimum) / span * 100, 0), 100)
    }
}
