import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import MonitoringKit

private let work = DispatchQueue(label: "com.belzephyrus.blzphrs.helper")
nonisolated(unsafe) private var clientCount = 0
private let messageCanSleep: UInt32 = 0xE0000270
private let messageWillSleep: UInt32 = 0xE0000280
private let messagePoweredOn: UInt32 = 0xE0000300

private struct FanDevice {
    var index: Int
    var minimum: Double
    var maximum: Double
    var modeKey: String
}

private final class FanGovernor: @unchecked Sendable {
    static let shared = FanGovernor()
    private var mode = FanMode.auto
    private var resume = FanMode.auto
    private var floor = 40
    private var autoReturn = false
    private var smoothed = 40.0
    private var fans: [FanDevice] = []
    private var timer: DispatchSourceTimer?
    private var missingSince: Date?
    private var reapplied = false
    private var coolTicks = 0
    private var cpuKeys: [String]?
    private(set) var message: String?

    func configure(mode raw: Int, floor: Int, autoReturn: Bool) -> String? {
        work.sync {
            discover()
            self.floor = min(max(floor, 20), 100)
            self.autoReturn = autoReturn
            reapplied = false
            message = nil
            apply(FanMode(rawValue: raw) ?? .auto)
            return message
        }
    }

    func restore() -> Bool {
        work.sync {
            apply(.auto)
            return fans.allSatisfy { (SMCAccess.readUI8($0.modeKey) ?? 0) == 0 }
        }
    }

    func willSleep() {
        work.sync {
            resume = mode
            apply(.auto)
        }
    }

    func didWake() {
        work.sync {
            reapplied = false
            if resume != .auto { apply(resume) }
        }
    }

    private func discover() {
        guard fans.isEmpty else { return }
        let count = Int(SMCAccess.readUI8("FNum") ?? 0)
        for index in 0..<count {
            guard let minimum = SMCAccess.readFloat("F\(index)Mn"),
                  let maximum = SMCAccess.readFloat("F\(index)Mx"),
                  maximum > minimum else { continue }
            let lower = "F\(index)md"
            let modeKey = SMCAccess.readUI8(lower) != nil ? lower : "F\(index)Md"
            fans.append(FanDevice(index: index, minimum: minimum, maximum: maximum, modeKey: modeKey))
        }
    }

    private func apply(_ next: FanMode) {
        mode = next
        if next == .auto {
            for fan in fans {
                _ = SMCAccess.writeUI8(fan.modeKey, 0)
            }
            _ = SMCAccess.writeUI8("Ftst", 0)
            timer?.cancel()
            timer = nil
            return
        }
        _ = SMCAccess.writeUI8("Ftst", 1)
        startTimer()
        tick()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard mode != .auto else { return }
        guard let celsius = cpuCelsius() else {
            if missingSince == nil { missingSince = Date() }
            if let missingSince, Date().timeIntervalSince(missingSince) > 10 {
                message = "No temperature readings. Fans returned to Auto."
                apply(.auto)
            }
            return
        }
        missingSince = nil
        if autoReturn, celsius < 50 {
            coolTicks += 1
            if coolTicks >= 3 {
                apply(.auto)
                return
            }
        } else {
            coolTicks = 0
        }
        let target = mode == .max ? 100 : FanCurve.percent(celsius: celsius, floor: floor)
        smoothed = FanCurve.smoothed(current: smoothed, target: target, maxDrop: 8)
        for fan in fans {
            let rpm = FanCurve.rpm(percent: smoothed, minimum: fan.minimum, maximum: fan.maximum)
            _ = SMCAccess.writeUI8("Ftst", 1)
            _ = SMCAccess.writeUI8(fan.modeKey, 1)
            _ = SMCAccess.writeFloat("F\(fan.index)Tg", rpm)
            let actual = SMCAccess.readUI8(fan.modeKey) ?? 0
            if actual != 1 {
                if !reapplied {
                    reapplied = true
                    _ = SMCAccess.writeUI8(fan.modeKey, 1)
                    _ = SMCAccess.writeFloat("F\(fan.index)Tg", rpm)
                } else {
                    message = "macOS took control of the fans."
                    apply(.auto)
                    return
                }
            }
        }
    }

    private func cpuCelsius() -> Double? {
        if cpuKeys == nil {
            var model = [CChar](repeating: 0, count: 64)
            var size = model.count
            if sysctlbyname("hw.model", &model, &size, nil, 0) != 0 { return nil }
            let identifier = String(cString: model)
            cpuKeys = SensorMap.select(keys: SMCAccess.keys(), modelIdentifier: identifier).cpu
        }
        let values = (cpuKeys ?? []).compactMap { SMCAccess.readFloat($0) }
        return SensorMap.averageCelsius(values)
    }
}

private enum ChargeGate {
    static func setLimit(_ percent: Int) -> String? {
        work.sync {
            guard let current = SMCAccess.readUI8("CIPJ") else { return "No charge-limit key" }
            let value = UInt8(min(max(percent, 50), 100))
            guard SMCAccess.writeUI8("CIPJ", value), SMCAccess.readUI8("CIPJ") == value else {
                _ = SMCAccess.writeUI8("CIPJ", current)
                return "Charge limit was not accepted"
            }
            return nil
        }
    }

    static func setCharging(_ enabled: Bool) -> String? {
        work.sync {
            let value: UInt8 = enabled ? 0 : 1
            var wrote = false
            for key in ["CHIB", "CHIC", "CHIL", "CHIO"] {
                guard SMCAccess.readUI8(key) != nil else { continue }
                wrote = SMCAccess.writeUI8(key, value) || wrote
            }
            if !wrote && !enabled { return "Charging control was not accepted" }
            return nil
        }
    }

    static func restore() {
        _ = setLimit(100)
        _ = setCharging(true)
    }
}

private final class AWDLGate: @unchecked Sendable {
    static let shared = AWDLGate()
    private var wasUp = true
    private var enabled = false
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1

    func setEnabled(_ on: Bool) -> String? {
        work.sync {
            if on && !enabled {
                var up: Int32 = 1
                if InterfaceIsUp("awdl0", &up) == 0 { wasUp = up != 0 }
                enabled = true
                watch()
            }
            enabled = on
            if on {
                guard InterfaceSetUp("awdl0", 0) == 0 else { return "Could not disable AWDL" }
                return nil
            }
            if wasUp { _ = InterfaceSetUp("awdl0", 1) }
            return nil
        }
    }

    func restore() {
        _ = setEnabled(false)
    }

    private func watch() {
        guard source == nil else { return }
        let fd = socket(AF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return }
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: work)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            _ = read(fd, &buffer, buffer.count)
            guard let self, self.enabled else { return }
            _ = InterfaceSetUp("awdl0", 0)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}

private enum SleepGate {
    static func setDisabled(_ disabled: Bool) {
        let value = disabled ? "1" : "0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", value]
        try? process.run()
        process.waitUntilExit()
    }
}

private func restoreEverything() -> Bool {
    let fans = FanGovernor.shared.restore()
    ChargeGate.restore()
    AWDLGate.shared.restore()
    SleepGate.setDisabled(false)
    return fans
}

private final class HelperService: NSObject, MonitoringHelperXPC {
    func setFanMode(_ mode: Int, floorPercent floor: Int, autoReturnWhenCool autoReturn: Bool, reply: @escaping (String?) -> Void) {
        reply(FanGovernor.shared.configure(mode: mode, floor: floor, autoReturn: autoReturn))
    }

    func setChargingEnabled(_ enabled: Bool, reply: @escaping (String?) -> Void) {
        reply(ChargeGate.setCharging(enabled))
    }

    func setChargeLimitPercent(_ percent: Int, reply: @escaping (String?) -> Void) {
        reply(ChargeGate.setLimit(percent))
    }

    func setLowLagEnabled(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        if let error = AWDLGate.shared.setEnabled(enabled) {
            reply(false, error)
        } else {
            reply(enabled, nil)
        }
    }

    func setClamshellSleepDisabled(_ disabled: Bool, reply: @escaping (String?) -> Void) {
        SleepGate.setDisabled(disabled)
        reply(nil)
    }

    func restoreAll(reply: @escaping (Bool, String?) -> Void) {
        let auto = restoreEverything()
        reply(auto, auto ? nil : FanGovernor.shared.message)
    }

    func version(reply: @escaping (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2")
    }

    func relaunchIfVersionMismatches(_ expected: String, reply: @escaping (Bool) -> Void) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
        if current != expected {
            reply(true)
            exit(0)
        }
        reply(false)
    }
}

private final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MonitoringHelperXPC.self)
        connection.exportedObject = HelperService()
        connection.invalidationHandler = {
            let restore = work.sync { () -> Bool in
                clientCount = max(clientCount - 1, 0)
                return clientCount == 0
            }
            if restore { _ = restoreEverything() }
        }
        connection.resume()
        work.sync { clientCount += 1 }
        return true
    }
}

nonisolated(unsafe) private var powerRoot: io_connect_t = 0

private func watchPower() {
    var port: IONotificationPortRef?
    var notifier: io_object_t = 0
    powerRoot = IORegisterForSystemPower(nil, &port, { _, _, messageType, argument in
        if messageType == messageWillSleep || messageType == messageCanSleep {
            FanGovernor.shared.willSleep()
        }
        if messageType == messagePoweredOn {
            FanGovernor.shared.didWake()
        }
        if messageType == messageWillSleep || messageType == messageCanSleep, let argument {
            IOAllowPowerChange(powerRoot, Int(bitPattern: argument))
        }
    }, &notifier)
    if let port {
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

_ = restoreEverything()
watchPower()
let listener = NSXPCListener(machServiceName: "com.belzephyrus.blzphrs.helper")
private let delegate = HelperDelegate()
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement("identifier \"com.belzephyrus.blzphrs\" and anchor apple generic and certificate leaf[subject.OU] = \"TQA73XJF6K\"")
listener.resume()
RunLoop.main.run()
