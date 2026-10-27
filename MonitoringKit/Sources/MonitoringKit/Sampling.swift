import Foundation
import Darwin

/// Continuous monotonic seconds, including sleep. A long sleep invalidates rate baselines.
public enum SampleClock {
    private static let secondsPerTick: Double = {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        return Double(scale.numer) / Double(scale.denom) / 1e9
    }()
    public static var now: Double { Double(mach_continuous_time()) * secondsPerTick }
}

public struct CounterRate: Sendable {
    private var previous: (value: UInt64, time: Double)?
    public init() {}
    public mutating func reset() { previous = nil }
    public mutating func sample(_ value: UInt64?, at time: Double, maximumGap: Double = 10) -> Double? {
        guard let value, time.isFinite else { reset(); return nil }
        defer { previous = (value, time) }
        guard let previous else { return nil }
        let elapsed = time - previous.time
        guard elapsed >= 0.1, elapsed <= maximumGap, value >= previous.value else { return nil }
        return Double(value - previous.value) / elapsed
    }
}

public struct HistoryPoint: Equatable, Sendable {
    public var time: Double
    public var value: Double?
    public init(time: Double, value: Double?) { self.time = time; self.value = value }
}

/// Bounded by both time and count; missing samples remain explicit gaps.
public struct MetricHistory: Equatable, Sendable {
    public private(set) var points: [HistoryPoint] = []
    public let duration: Double
    public init(duration: Double = 300) { self.duration = duration }
    public mutating func append(_ value: Double?, at time: Double) {
        guard time.isFinite else { return }
        if let last = points.last, time <= last.time { return }
        points.removeAll { $0.time < time - duration }
        points.append(HistoryPoint(time: time, value: value.flatMap { $0.isFinite ? $0 : nil }))
        if points.count > 601 { points.removeFirst(points.count - 601) }
    }
    public func maximum(at time: Double) -> Double? {
        points.lazy.filter { $0.time >= time - duration && $0.time <= time }.compactMap(\.value).max()
    }
}

public struct SampleHealth: Equatable, Sendable {
    public private(set) var lastSuccess: Double?
    public private(set) var failed = false
    public var source: String
    public var lifetime: Double
    public init(source: String, lifetime: Double = 10) { self.source = source; self.lifetime = lifetime }
    public mutating func record(success: Bool, at time: Double) {
        failed = !success
        if success { lastSuccess = time }
    }
    public func isFresh(at time: Double) -> Bool {
        guard !failed, let lastSuccess else { return false }
        return time >= lastSuccess && time - lastSuccess <= lifetime
    }
    public func label(at time: Double) -> String {
        guard let lastSuccess else { return "Unavailable" }
        if isFresh(at: time) { return "Live" }
        return "Stale · \(Int(max(0, time - lastSuccess)))s ago"
    }
}

/// Independent deadlines avoid tick-modulo aliasing and extra background wakeups.
public struct SampleDeadline: Sendable {
    private var last: Double?
    public init() {}
    public mutating func due(at time: Double, interval: Double, force: Bool = false) -> Bool {
        guard force || last == nil || time - last! >= interval else { return false }
        last = time
        return true
    }
}
