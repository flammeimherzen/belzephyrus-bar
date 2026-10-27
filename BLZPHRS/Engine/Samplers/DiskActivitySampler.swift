import Foundation
import IOKit
import MonitoringKit

final class DiskActivitySampler: @unchecked Sendable {
    private var service: io_registry_entry_t = 0
    private var device = "Internal storage unavailable"
    private var discovery = SampleDeadline()
    private var reads = CounterRate()
    private var writes = CounterRate()

    deinit { if service != 0 { IOObjectRelease(service) } }
    func reset() { reads.reset(); writes.reset() }

    func sample() -> (read: Double?, write: Double?, device: String) {
        let now = SampleClock.now
        if service == 0, discovery.due(at: now, interval: 30) { discover() }
        guard service != 0,
              let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let read = stats["Bytes (Read)"] as? NSNumber,
              let write = stats["Bytes (Write)"] as? NSNumber else {
            if service != 0 { IOObjectRelease(service); service = 0 }
            reset()
            return (nil, nil, "Internal storage unavailable")
        }
        return (reads.sample(read.uint64Value, at: now), writes.sample(write.uint64Value, at: now), device)
    }

    /// Select only a positively identified internal physical drive, never by traffic volume.
    /// Cache the registry handle; retry discovery only after a failure.
    private func discover() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var candidates: [(io_registry_entry_t, String)] = []
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            let protocolInfo = IORegistryEntrySearchCFProperty(candidate, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? [String: Any]
            guard protocolInfo?["Physical Interconnect Location"] as? String == "Internal",
                  let name = IORegistryEntrySearchCFProperty(candidate, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String else {
                IOObjectRelease(candidate)
                continue
            }
            candidates.append((candidate, name))
        }
        // Multiple internal drives require explicit selection; do not silently guess.
        if candidates.count == 1 {
            service = candidates[0].0
            device = "Internal · \(candidates[0].1)"
        } else {
            candidates.forEach { IOObjectRelease($0.0) }
        }
        reset()
    }
}
