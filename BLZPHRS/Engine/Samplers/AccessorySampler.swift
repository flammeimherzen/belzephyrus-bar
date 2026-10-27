import Foundation
import IOKit
import MonitoringKit

final class AccessorySampler: @unchecked Sendable {
    func sample() -> [AccessoryBattery] {
        var found = powerSources()
        let seenKinds = Set(found.map { kind(of: $0.name) })
        for item in hidDevices() where !seenKinds.contains(kind(of: item.name)) || kind(of: item.name) == "other" {
            found.append(item)
        }
        found.append(contentsOf: wiredDevices(excluding: Set(found.map { kind(of: $0.name) })))
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bluetooth accessories macOS already names: Magic Trackpad, AirPods, and so on.
    private func powerSources() -> [AccessoryBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = SampleClock.now + 1
        while process.isRunning && SampleClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { process.terminate(); return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let expression = try? NSRegularExpression(pattern: #"^ -(.+?) \(id=(-?\d+)\)\s+(\d+)%;\s+(.+?)\s+present:"#, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return expression.matches(in: output, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: output),
                  let idRange = Range(match.range(at: 2), in: output),
                  let percentRange = Range(match.range(at: 3), in: output),
                  let stateRange = Range(match.range(at: 4), in: output) else { return nil }
            let name = String(output[nameRange]).trimmingCharacters(in: .whitespaces)
            guard !name.localizedCaseInsensitiveContains("InternalBattery"),
                  let percent = Int(output[percentRange]), (0...100).contains(percent) else { return nil }
            let state = String(output[stateRange]).lowercased()
            let charging = state.contains("charging") && !state.contains("discharging") && !state.contains("not charging")
            return AccessoryBattery(id: "ps-\(output[idRange])", name: name, percent: percent, symbol: symbol(for: name), charging: charging)
        }
    }

    /// A phone or tablet on the USB-C port reports charge through the Mac battery controller, not as a HID battery.
    private func wiredDevices(excluding kinds: Set<String>) -> [AccessoryBattery] {
        let names = productNames()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [AccessoryBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let details = dictionary["FedDetails"] as? [Any] else { continue }
            for item in details {
                guard let entry = item as? [String: Any] else { continue }
                let productID = (entry["FedProductID"] as? NSNumber)?.intValue ?? 0
                let design = (entry["FedDesignCapacity"] as? NSNumber)?.intValue ?? 0
                let percent = (entry["FedStateOfCharge"] as? NSNumber)?.intValue ?? -1
                guard productID != 0, design > 0, (0...100).contains(percent) else { continue }
                let name = names[productID] ?? "USB device"
                guard !kinds.contains(kind(of: name)) else { continue }
                found.append(AccessoryBattery(id: "wired-\(productID)", name: name, percent: percent, symbol: symbol(for: name)))
            }
        }
        return found
    }

    private func hidDevices() -> [AccessoryBattery] {
        var found: [AccessoryBattery] = []
        for name in ["AppleDeviceManagementHIDEventService", "AppleMultitouchTrackpadHIDEventDriver", "IOHIDEventService"] {
            collectHID(matching: name, into: &found)
        }
        return found
    }

    private func collectHID(matching name: String, into found: inout [AccessoryBattery]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any] else { continue }
            if (dictionary["Built-In"] as? Bool) == true || (dictionary["Built-In"] as? NSNumber)?.boolValue == true { continue }
            let title = text(dictionary["Product"])
                ?? text(dictionary["DeviceName"])
                ?? text(dictionary["ProductName"])
                ?? text(dictionary["Accessory Category"])
            guard let title, !title.hasPrefix("PMU"), !title.contains("gas gauge") else { continue }
            let pairs: [(String, String)] = [
                ("BatteryPercent", "percent"),
                ("BatteryPercentLeft", "left"),
                ("BatteryPercentRight", "right"),
                ("BatteryPercentCase", "case")
            ]
            for pair in pairs {
                guard let percent = (dictionary[pair.0] as? NSNumber)?.intValue, (0...100).contains(percent) else { continue }
                let label = pair.1 == "percent" ? title : "\(title) \(pair.1)"
                found.append(AccessoryBattery(id: "hid-\(label)", name: label, percent: percent, symbol: symbol(for: label)))
            }
        }
    }

    private func productNames() -> [Int: String] {
        var map: [Int: String] = [:]
        for className in ["IOPortTransportProtocolAppleUVDM", "IOUSBHostDevice", "IOUSBDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dictionary = properties?.takeRetainedValue() as? [String: Any] else { continue }
                let id = (dictionary["Product ID"] as? NSNumber)?.intValue ?? (dictionary["idProduct"] as? NSNumber)?.intValue
                let name = text(dictionary["Product"]) ?? text(dictionary["USB Product Name"])
                if let id, let name { map[id] = name }
            }
        }
        return map
    }

    private func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func kind(of name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpod") || lower.contains("buds") {
            if lower.contains("case") { return "airpods-case" }
            return "airpods"
        }
        if lower.contains("track") { return "trackpad" }
        if lower.contains("keyboard") || lower.contains("key") { return "keyboard" }
        if lower.contains("mouse") { return "mouse" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("watch") { return "watch" }
        if lower.contains("pencil") { return "pencil" }
        return "other"
    }

    private func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpod") || lower.contains("head") || lower.contains("buds") {
            return lower.contains("case") ? "airpods.chargingcase" : "airpodspro"
        }
        if lower.contains("mouse") { return "computermouse" }
        if lower.contains("key") { return "keyboard" }
        if lower.contains("track") { return "rectangle.and.hand.point.up.left.fill" }
        if lower.contains("watch") { return "applewatch" }
        if lower.contains("pencil") { return "applepencil" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        return "battery.100"
    }
}
