import Foundation
import MonitoringKit
import SystemConfiguration

final class NetworkSampler: @unchecked Sendable {
    private var incoming = CounterRate()
    private var outgoing = CounterRate()
    private var previousName = ""
    private let store = SCDynamicStoreCreate(nil, "Monitoring" as CFString, nil, nil)
    private var knownKinds: [String: String] = [:]
    private var inventoryDue = SampleDeadline()

    func reset() { incoming.reset(); outgoing.reset() }

    func sample() -> (down: Double?, up: Double?, kind: String) {
        let primary = primaryInterface()
        if primary.name != previousName { reset(); previousName = primary.name }
        let match = interfaces().first { $0.name == primary.name }
        let now = SampleClock.now
        return (incoming.sample(match?.ibytes, at: now), outgoing.sample(match?.obytes, at: now), primary.kind)
    }

    private func interfaces() -> [(name: String, ibytes: UInt64, obytes: UInt64)] {
        let capacity = 64
        let buffer = UnsafeMutablePointer<IFCounter>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let count = Int(CopyInterfaceCounters(buffer, Int32(capacity)))
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let item = buffer[index]
            let name = withUnsafePointer(to: item.name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            return (name, item.ibytes, item.obytes)
        }
    }

    private func primaryInterface() -> (name: String, kind: String) {
        guard let store else { return ("", "Unavailable") }
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        guard let name = (ipv4?["PrimaryInterface"] ?? ipv6?["PrimaryInterface"]) as? String else {
            return ("", "Disconnected")
        }
        if inventoryDue.due(at: SampleClock.now, interval: 30) {
            knownKinds = [:]
            for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
                if type == kSCNetworkInterfaceTypeIEEE80211 as String { knownKinds[bsd] = "Wi-Fi" }
                else if type == kSCNetworkInterfaceTypeEthernet as String { knownKinds[bsd] = "Ethernet" }
            }
        }
        if let kind = knownKinds[name] { return (name, "\(kind) · \(name)") }
        if name.hasPrefix("bridge") { return (name, "Bridge") }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return (name, "VPN · \(name)") }
        return (name, name)
    }
}
