import Darwin
import MonitoringKit

final class CPUSampler: @unchecked Sendable {
    private var previousTime: Double?
    func reset() { previous = []; previousTime = nil }

    private var previous: [UInt32] = []

    func sample() -> (usage: Double?, cores: [Double]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { reset(); return (nil, []) }
        defer {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), bytes)
        }

        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount)
        var next = [UInt32](repeating: 0, count: count * states)
        for cpu in 0..<count {
            let base = cpu * states
            next[base] = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            next[base + 1] = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            next[base + 2] = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            next[base + 3] = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
        }
        let now = SampleClock.now
        defer { previous = next; previousTime = now }
        guard let previousTime, now - previousTime >= 0.1, now - previousTime <= 10, previous.count == next.count else { return (nil, []) }

        var cores: [Double] = []
        cores.reserveCapacity(count)
        for cpu in 0..<count {
            let base = cpu * states
            let total = next[base] &+ next[base + 1] &+ next[base + 2] &+ next[base + 3]
            let busy = next[base] &+ next[base + 1] &+ next[base + 3]
            let oldTotal = previous[base] &+ previous[base + 1] &+ previous[base + 2] &+ previous[base + 3]
            let oldBusy = previous[base] &+ previous[base + 1] &+ previous[base + 3]
            let deltaTotal = total &- oldTotal
            let deltaBusy = busy &- oldBusy
            guard deltaBusy <= deltaTotal else { return (nil, []) }
            cores.append(deltaTotal > 0 ? Double(deltaBusy) / Double(deltaTotal) * 100 : 0)
        }
        let usage = cores.reduce(0, +) / Double(max(cores.count, 1))
        return (usage, cores)
    }
}
