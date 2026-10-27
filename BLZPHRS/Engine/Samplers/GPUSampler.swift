import Foundation
import IOKit
import MonitoringKit

final class GPUSampler: @unchecked Sendable {
    private var discovery = SampleDeadline()
    deinit { if service != 0 { IOObjectRelease(service) } }
    private var service: io_registry_entry_t = 0

    func utilization() -> Double? {
        if service == 0, discovery.due(at: SampleClock.now, interval: 30) { reopen() }
        guard service != 0 else { return nil }
        guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
            IOObjectRelease(service)
            service = 0
            return nil
        }
        let number = stats["Device Utilization %"] as? NSNumber
        guard let value = number?.doubleValue, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private func reopen() {
        if service != 0 { IOObjectRelease(service) }
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    }
}
