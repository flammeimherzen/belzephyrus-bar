import Combine
import CoreGraphics
import Darwin
import Foundation
import IOKit

@MainActor
final class BrightnessController: ObservableObject {
    @Published private(set) var mac = 0.5
    @Published private(set) var macAvailable = false
    @Published private(set) var external = 0.7
    @Published private(set) var externalConnected = false
    @Published private(set) var externalKnown = false
    private var editingMac = false
    private var editingExternal = false
    private var externalWriteGeneration = 0

    /// Reads the built-in display immediately and starts one external read. Call before the panel is measured.
    func prepareForDisplay() {
        if !editingMac, let value = BuiltinBrightness.read() {
            mac = value
            macAvailable = true
        } else {
            macAvailable = BuiltinBrightness.available
        }
        externalConnected = ExternalBrightness.connected()
        guard externalConnected else { return }
        let generation = externalWriteGeneration
        ExternalBrightness.shared.read { [weak self] percent in
            Task { @MainActor in
                guard let self, !self.editingExternal, generation == self.externalWriteGeneration, let percent else { return }
                self.external = Double(percent) / 100
                self.externalKnown = true
            }
        }
    }

    func setEditingMac(_ editing: Bool) {
        editingMac = editing
        if !editing { setMac(mac) }
    }

    func setEditingExternal(_ editing: Bool) {
        editingExternal = editing
        if !editing { setExternal(external) }
    }

    func setMac(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        mac = clamped
        BuiltinBrightness.write(clamped)
    }

    func setExternal(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        external = clamped
        externalKnown = true
        externalWriteGeneration += 1
        ExternalBrightness.shared.write(Int((clamped * 100).rounded()))
    }
}

private enum BuiltinBrightness {
    private static let get: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    private static let set: (@convention(c) (UInt32, Float) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (UInt32, Float) -> Int32).self)
    }()

    static var available: Bool {
        displayID() != nil && get != nil
    }

    static func read() -> Double? {
        guard let id = displayID(), let get else { return nil }
        var value: Float = 0
        guard get(id, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    static func write(_ value: Double) {
        guard let id = displayID(), let set else { return }
        _ = set(id, Float(value))
    }

    private static func displayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

private final class ExternalBrightness: @unchecked Sendable {
    static let shared = ExternalBrightness()
    private let queue = DispatchQueue(label: "com.belzephyrus.blzphrs.brightness")
    private var pending: Int?
    private var writing = false

    static func connected() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == 0 }
    }

    func read(completion: @escaping @Sendable (Int?) -> Void) {
        queue.async {
            completion(Self.current())
        }
    }

    func write(_ percent: Int) {
        let clamped = min(max(percent, 0), 100)
        queue.async {
            self.pending = clamped
            guard !self.writing else { return }
            self.writing = true
            while let next = self.pending {
                self.pending = nil
                _ = Self.apply(next)
            }
            self.writing = false
        }
    }

    private static func current() -> Int? {
        withService { service in
            guard let reply = communicate(service: service, send: [0x10], expectReply: true), reply.count >= 11 else { return nil }
            return Int(UInt16(reply[8]) << 8 | UInt16(reply[9]))
        }
    }

    private static func apply(_ percent: Int) -> Bool {
        let value = UInt16(percent)
        return withService { service in
            communicate(service: service, send: [0x10, UInt8(value >> 8), UInt8(value & 0xFF)], expectReply: false) != nil
        } ?? false
    }

    private static func withService<T>(_ body: (CFTypeRef) -> T?) -> T? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External",
                  let service = DDC.create?(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            if let value = body(service) { return value }
        }
        return nil
    }

    /// Packet layout matches the DDC/CI exchange used for Apple Silicon external displays.
    private static func communicate(service: CFTypeRef, send: [UInt8], expectReply: Bool) -> [UInt8]? {
        guard let write = DDC.write, (!expectReply || DDC.read != nil) else { return nil }
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let seed: UInt8 = send.count == 1 ? (0x37 << 1) : ((0x37 << 1) ^ 0x51)
        packet[packet.count - 1] = checksum(seed, packet, 0, packet.count - 2)
        var reply = [UInt8](repeating: 0, count: 11)
        for _ in 0..<4 {
            var wrote = false
            for _ in 0..<2 {
                usleep(10_000)
                let count = UInt32(packet.count)
                let rc = packet.withUnsafeMutableBytes { raw in
                    write(service, 0x37, 0x51, raw.baseAddress, count)
                }
                wrote = rc == 0
            }
            if !expectReply {
                if wrote { return [] }
                continue
            }
            usleep(50_000)
            let count = UInt32(reply.count)
            let rc = reply.withUnsafeMutableBytes { raw in
                DDC.read?(service, 0x37, 0, raw.baseAddress, count) ?? 1
            }
            if rc == 0, checksum(0x50, reply, 0, reply.count - 2) == reply[reply.count - 1] {
                return reply
            }
            usleep(20_000)
        }
        return nil
    }

    private static func checksum(_ seed: UInt8, _ data: [UInt8], _ start: Int, _ end: Int) -> UInt8 {
        var value = seed
        if start <= end {
            for index in start...end { value ^= data[index] }
        }
        return value
    }
}

private enum DDC {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

    static let create: Create? = load("IOAVServiceCreateWithService")
    static let write: Transfer? = load("IOAVServiceWriteI2C")
    static let read: Transfer? = load("IOAVServiceReadI2C")

    private static func load<T>(_ name: String) -> T? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
