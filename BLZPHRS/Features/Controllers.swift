import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Foundation
import IOKit.pwr_mgt
import MonitoringKit

@MainActor
final class FanController: ObservableObject {
    @Published var mode: FanMode = .auto
    @Published var message: String?
    private let helper: HelperClient
    private let settings: SettingsStore

    init(helper: HelperClient, settings: SettingsStore) {
        self.helper = helper
        self.settings = settings
    }

    var floorPercent: Int { settings.coolFloor }

    func select(_ mode: FanMode) {
        self.mode = mode
        message = nil
        helper.setFan(mode: mode, floor: settings.coolFloor, autoReturn: settings.autoReturnWhenCool) { [weak self] error in
            Task { @MainActor in
                self?.message = error
                if error != nil { self?.mode = .auto }
            }
        }
    }

    func resend() {
        guard mode != .auto else { return }
        select(mode)
    }

    func prepareToQuit(completion: @escaping @Sendable (Bool) -> Void) {
        mode = .auto
        helper.restoreAll { confirmed in
            completion(confirmed)
        }
    }
}

@MainActor
final class ChargeLimitController: ObservableObject {
    @Published var enabled: Bool
    @Published var holding = false
    @Published var message: String?
    @Published private(set) var usesSystemLimit = false
    @Published private(set) var systemLimitPercent: Int?
    private let helper: HelperClient
    private var appEnabled: Bool
    private var usesInhibit = false
    private var source: CFRunLoopSource?

    init(helper: HelperClient, settings: SettingsStore) {
        self.helper = helper
        appEnabled = settings.chargeLimit
        enabled = settings.chargeLimit
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<ChargeLimitController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.apply(percent: nil) }
        }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
        if enabled { setEnabled(true) }
        Task.detached { [weak self] in
            let limit = BatterySampler.systemChargeLimit(refresh: true)
            await MainActor.run { self?.applySystemLimit(limit) }
        }
    }

    func setEnabled(_ on: Bool) {
        if usesSystemLimit {
            enabled = false
            enabled = true
            message = "Set in System Settings → Battery"
            return
        }
        appEnabled = on
        enabled = on
        message = nil
        if !on {
            holding = false
            helper.setChargeLimit(100) { _ in }
            helper.setCharging(true) { _ in }
            return
        }
        helper.setChargeLimit(80) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.usesInhibit = true
                    self.apply(percent: nil)
                } else {
                    self.usesInhibit = false
                }
            }
        }
    }

    func note(_ reading: BatteryReading) {
        applySystemLimit(reading.systemLimitPercent)
        guard !usesSystemLimit else { return }
        apply(percent: reading.percent)
    }

    private func applySystemLimit(_ limit: Int?) {
        if let limit {
            usesSystemLimit = true
            systemLimitPercent = limit
            enabled = true
            return
        }
        guard usesSystemLimit else { return }
        usesSystemLimit = false
        systemLimitPercent = nil
        enabled = appEnabled
        message = nil
    }

    private func apply(percent: Int?) {
        guard enabled, usesInhibit, !usesSystemLimit else { return }
        guard let percent else { return }
        if percent >= 80 {
            holding = true
            helper.setCharging(false) { [weak self] error in
                Task { @MainActor in self?.message = error }
            }
        } else if percent <= 75 {
            holding = false
            helper.setCharging(true) { [weak self] error in
                Task { @MainActor in self?.message = error }
            }
        }
    }

    func chargeToFull() {
        if usesSystemLimit {
            message = "The \(systemLimitPercent ?? 80)% limit is set in System Settings"
            return
        }
        holding = false
        usesInhibit = false
        appEnabled = false
        enabled = false
        helper.setChargeLimit(100) { _ in }
        helper.setCharging(true) { _ in }
    }
}

@MainActor
final class LowLagController: ObservableObject {
    @Published var enabled = false
    @Published var message: String?
    private let helper: HelperClient

    init(helper: HelperClient) { self.helper = helper }

    func toggle() {
        let next = !enabled
        helper.setLowLag(next) { [weak self] active, error in
            Task { @MainActor in
                self?.enabled = active
                self?.message = error
            }
        }
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        helper.setLowLag(false) { _, _ in }
    }
}

@MainActor
final class KeepAwakeController: ObservableObject {
    @Published var active = false
    @Published var paused = false
    @Published var remainingText: String?
    private let helper: HelperClient
    private let settings: SettingsStore
    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var deadline: Date?
    private var timer: Timer?
    private var chosen: TimeInterval?

    init(helper: HelperClient, settings: SettingsStore) {
        self.helper = helper
        self.settings = settings
    }

    func start(minutes: Int?) {
        stop()
        guard takeAssertions() else { return }
        active = true
        paused = false
        if let minutes {
            chosen = TimeInterval(minutes * 60)
            deadline = Date().addingTimeInterval(chosen!)
        } else {
            chosen = nil
            deadline = nil
            remainingText = "On"
        }
        if settings.allowClosedLid { helper.setClamshell(true) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        releaseAssertions()
        if settings.allowClosedLid { helper.setClamshell(false) }
        active = false
        paused = false
        remainingText = nil
        deadline = nil
    }

    func note(percent: Int, onAC: Bool) {
        guard active else { return }
        if !onAC && percent <= 20 {
            if !paused {
                paused = true
                releaseAssertions()
                helper.setClamshell(false)
            }
        } else if paused {
            paused = false
            _ = takeAssertions()
            if settings.allowClosedLid && onAC { helper.setClamshell(true) }
        }
    }

    private func tick() {
        guard let deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            stop()
            return
        }
        let minutes = Int(left) / 60
        let seconds = Int(left) % 60
        remainingText = String(format: "%d:%02d", minutes, seconds)
    }

    private func takeAssertions() -> Bool {
        displayAssertion = create(kIOPMAssertionTypePreventUserIdleDisplaySleep)
        systemAssertion = create(kIOPMAssertionTypePreventUserIdleSystemSleep)
        return displayAssertion != 0
    }

    private func create(_ type: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Monitoring" as CFString, &id)
        return result == kIOReturnSuccess ? id : 0
    }

    private func releaseAssertions() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
    }
}

@MainActor
final class CleanScreenController: ObservableObject {
    @Published var active = false
    private var windows: [NSWindow] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var escDown: Date?
    private var timer: Timer?

    func toggle() {
        if active { stop() } else { start() }
    }

    func start() {
        stop()
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false
            let label = NSTextField(labelWithString: trusted ? "Hold Esc for 3 seconds" : "Allow Accessibility, then click to exit")
            label.textColor = .white
            label.font = .systemFont(ofSize: 18, weight: .medium)
            label.sizeToFit()
            label.frame.origin = NSPoint(x: (screen.frame.width - label.frame.width) / 2, y: screen.frame.height / 2)
            window.contentView?.addSubview(label)
            window.orderFrontRegardless()
            windows.append(window)
        }
        if trusted { installTap() }
        active = true
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchEsc() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        }
        tap = nil
        runLoopSource = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        escDown = nil
        active = false
    }

    private func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, user in
            guard let user else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<CleanScreenController>.fromOpaque(user).takeUnretainedValue()
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                Task { @MainActor in if controller.escDown == nil { controller.escDown = Date() } }
            } else if type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                Task { @MainActor in controller.escDown = nil }
            }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func watchEsc() {
        if let escDown, Date().timeIntervalSince(escDown) >= 3 { stop() }
    }
}

@MainActor
final class PrivacyMonitor: ObservableObject {
    @Published var camera = false
    @Published var microphone = false
    private var listening = false
    private var microphoneBlock: AudioObjectPropertyListenerBlock?
    private var cameraBlock: CMIOObjectPropertyListenerBlock?

    var text: String {
        switch (camera, microphone) {
        case (true, true): "Camera and mic"
        case (true, false): "Camera"
        case (false, true): "Mic"
        case (false, false): "Not in use"
        }
    }

    func start() {
        guard !listening else { return }
        listening = true
        listenForMicrophone()
        listenForCamera()
        refresh()
    }

    func stop() {
        guard listening else { return }
        listening = false
        if let microphoneBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, microphoneBlock)
        }
        if let cameraBlock {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, DispatchQueue.main, cameraBlock)
        }
        microphoneBlock = nil
        cameraBlock = nil
        camera = false
        microphone = false
    }

    private func refresh() {
        microphone = microphoneRunning()
        camera = cameraRunning()
    }

    private func listenForMicrophone() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        microphoneBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func microphoneRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return false }
        for device in devices {
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private func listenForCamera() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        cameraBlock = block
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, DispatchQueue.main, block)
    }

    private func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var dataSize = size
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, dataSize, &dataSize, &devices) == noErr else { return false }
        for device in devices {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, runningSize, &runningSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}
