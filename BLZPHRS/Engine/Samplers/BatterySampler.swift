import Foundation
import IOKit
import MonitoringKit

final class BatterySampler: @unchecked Sendable {
    private var chargeHistory = MetricHistory(duration: 60)
    func reset() { chargeHistory = MetricHistory(duration: 60) }
    private final class LimitCache: @unchecked Sendable {
        static let shared = LimitCache()
        private let lock = NSLock()
        private var value: Int?
        private var date: Double = -Double.infinity

        func value(refresh: Bool, fetch: () -> Int?) -> Int? {
            lock.lock()
            if !refresh, SampleClock.now - date < 60 {
                let current = value
                lock.unlock()
                return current
            }
            lock.unlock()
            let fetched = fetch()
            lock.lock()
            value = fetched
            date = SampleClock.now
            lock.unlock()
            return fetched
        }
    }

    func sample(refreshLimit: Bool = false) -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }

        guard let percent = (dictionary["CurrentCapacity"] as? NSNumber)?.intValue, (0...100).contains(percent) else { return nil }
        let design = (dictionary["DesignCapacity"] as? NSNumber)?.doubleValue ?? 0
        let rawFull = (dictionary["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue ?? 0
        let health = design > 0 && rawFull > 0 && rawFull <= design * 1.2 ? Int(min(100, rawFull / design * 100).rounded()) : nil
        let charging = (dictionary["IsCharging"] as? NSNumber)?.boolValue ?? false
        let onAC = (dictionary["ExternalConnected"] as? NSNumber)?.boolValue ?? false
        let voltageMV = (dictionary["Voltage"] as? NSNumber)?.doubleValue ?? 0
        let amperageMA = (dictionary["InstantAmperage"] as? NSNumber)?.doubleValue ?? 0
        let battery = dictionary["BatteryData"] as? [String: Any]
        let full = (battery?["FullChargeCapacity"] as? NSNumber)?.doubleValue ?? 0
        let remaining = (battery?["RemainingCapacity"] as? NSNumber)?.doubleValue ?? 0
        let minutes = (dictionary["AvgTimeToFull"] as? NSNumber)?.intValue
        let timeRemaining = (dictionary["TimeRemaining"] as? NSNumber)?.intValue
        let validElectrical = voltageMV > 0 && voltageMV < 30_000 && abs(amperageMA) < 30_000
        let watts = validElectrical ? voltageMV * amperageMA / 1_000_000 : nil
        let now = SampleClock.now
        if !charging || !validElectrical || amperageMA <= 1 || chargeHistory.points.last.map({ now - $0.time > 20 }) == true { reset() }
        chargeHistory.append(charging && validElectrical && amperageMA > 0 ? amperageMA : nil, at: now)
        let currents = chargeHistory.points.compactMap(\.value)
        let stableCurrent = currents.count >= 3 ? currents.reduce(0, +) / Double(currents.count) : 0
        let shownMinutes: Int?
        if charging {
            shownMinutes = (minutes ?? 0) > 0 && (minutes ?? 0) < 2000 ? minutes : nil
        } else if let timeRemaining, timeRemaining > 0, timeRemaining < 2000 {
            shownMinutes = timeRemaining
        } else {
            shownMinutes = nil
        }
        return BatteryReading(
            percent: percent,
            healthPercent: (health ?? 0) > 0 && (health ?? 0) <= 100 ? health : nil,
            isCharging: charging,
            onAC: onAC,
            watts: watts,
            minutesRemaining: shownMinutes,
            fullChargeMah: full,
            remainingMah: remaining,
            amperageMa: stableCurrent,
            systemLimitPercent: systemLimit(in: dictionary) ?? Self.systemChargeLimit(refresh: refreshLimit)
        )
    }

    /// The charge limit from System Settings. `pmset -g battlimit` is the readable source; the SMC key the app writes is a different control.
    static func systemChargeLimit(refresh: Bool = false) -> Int? {
        LimitCache.shared.value(refresh: refresh, fetch: readSystemChargeLimit)
    }

    private static func readSystemChargeLimit() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = SampleClock.now + 1
        while process.isRunning && SampleClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { process.terminate(); return nil }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        var limit: Int?
        for block in text.components(separatedBy: "{").dropFirst() {
            guard block.contains("Terminated = 0"), block.contains("manualChargeLimit") else { continue }
            guard let range = block.range(of: #"chargeSocLimitSoc\s*=\s*(\d+)"#, options: .regularExpression) else { continue }
            let digits = block[range].filter(\.isNumber)
            guard let value = Int(digits), (50...99).contains(value) else { continue }
            limit = min(limit ?? value, value)
        }
        return limit
    }

    private func systemLimit(in dictionary: [String: Any]) -> Int? {
        for key in ["ChargeLimit", "AppleChargeLimit", "ChargerLimit"] {
            if let value = (dictionary[key] as? NSNumber)?.intValue, (50...99).contains(value) {
                return value
            }
        }
        return nil
    }
}
