import AppKit
import Combine
import Foundation
import MonitoringKit

@MainActor
final class CPUModel: ObservableObject {
    @Published var temperatureHealth = SampleHealth(source: "SMC temperature", lifetime: 10)
    @Published var health = SampleHealth(source: "Mach CPU ticks", lifetime: 10)
    @Published var state = CPUCardState(usage: nil, cores: [], celsius: nil, peakCelsius: nil, coreCount: MachineInfo.coreCount)
}

@MainActor
final class GPUModel: ObservableObject {
    @Published var temperatureHealth = SampleHealth(source: "SMC temperature", lifetime: 10)
    @Published var powerHealth = SampleHealth(source: "IOReport", lifetime: 10)
    @Published var health = SampleHealth(source: "IOAccelerator", lifetime: 10)
    @Published var state = GPUCardState(usage: nil, celsius: nil, watts: nil, history: [])
}

@MainActor
final class MemoryModel: ObservableObject {
    @Published var health = SampleHealth(source: "Mach VM statistics", lifetime: 10)
    @Published var state: MemoryCardState?
}

@MainActor
final class DiskModel: ObservableObject {
    @Published var health = SampleHealth(source: "Home volume capacity", lifetime: 90)
    @Published var state: DiskCardState?
}

@MainActor
final class NetworkModel: ObservableObject {
    @Published var health = SampleHealth(source: "Interface byte counters", lifetime: 10)
    @Published var state = NetworkCardState(downPerSecond: nil, upPerSecond: nil, kind: "Wi-Fi", history: [])
}

@MainActor
final class FanModel: ObservableObject {
    @Published var health = SampleHealth(source: "SMC", lifetime: 10)
    @Published var fans: [FanReading] = []
}

@MainActor
final class BatteryModel: ObservableObject {
    @Published var health = SampleHealth(source: "AppleSmartBattery", lifetime: 25)
    @Published var state: BatteryReading?
    @Published var accessories: [AccessoryBattery] = []
}

@MainActor
final class ProcessModel: ObservableObject {
    @Published var health = SampleHealth(source: "proc_pid_rusage", lifetime: 10)
    @Published var rows: [ProcessRowState] = []
    @Published var sort = ProcessSort.memory
    @Published var includeSystem = false

    var visible: [ProcessRowState] {
        let ordered = switch sort {
        case .memory: rows.sorted { $0.group.totalBytes > $1.group.totalBytes }
        case .cpu: rows.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
        }
        return Array(ordered.prefix(8))
    }
}

@MainActor
final class HeaderModel: ObservableObject {
    @Published var state = HeaderState(chip: MachineInfo.chip, memory: MachineInfo.memoryText, os: MachineInfo.osText, uptime: MachineInfo.uptimeText)
}

@MainActor
final class MetricsEngine {
    let cpu = CPUModel()
    let gpu = GPUModel()
    let memory = MemoryModel()
    let disk = DiskModel()
    let network = NetworkModel()
    let fan = FanModel()
    let battery = BatteryModel()
    let processes = ProcessModel()
    let header = HeaderModel()
    var onBattery: ((BatteryReading) -> Void)?
    var menuChanged: ((MenuBarSnapshot) -> Void)?

    private let service = SystemInfoService()
    private let cpuSampler = CPUSampler()
    private let gpuSampler = GPUSampler()
    private let thermal = ThermalSampler()
    private let networkSampler = NetworkSampler()
    private let diskActivity = DiskActivitySampler()
    private let batterySampler = BatterySampler()
    private let accessorySampler = AccessorySampler()
    private let processSampler = ProcessSampler()
    private let queue = DispatchQueue(label: "com.belzephyrus.blzphrs.sample", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var panelOpen = false
    private var busy = false
    private var refreshPending = false
    private var generation = 0
    private var wakeObserver: NSObjectProtocol?
    private var settings: SettingsStore?
    private var cpuHistory = MetricHistory()
    private var gpuHistory = MetricHistory()
    private var memoryHistory = MetricHistory()
    private var pressureHistory = MetricHistory()
    private var downHistory = MetricHistory()
    private var upHistory = MetricHistory()
    private var readHistory = MetricHistory()
    private var writeHistory = MetricHistory()
    private var batteryDue = SampleDeadline()
    private var diskDue = SampleDeadline()
    private var diskDetailDue = SampleDeadline()
    private var processDue = SampleDeadline()
    private var accessoryDue = SampleDeadline()
    private var thermalDue = SampleDeadline()
    private var powerDue = SampleDeadline()
    private var memoryStats: MemoryStats?
    private var diskStats: DiskStats?
    private var menuSnapshot = MenuBarSnapshot(items: [], help: "")

    func start(settings: SettingsStore) {
        self.settings = settings
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.pulse() }
        self.timer = timer
        reschedule()
        timer.resume()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.generation += 1
                self.queue.async { [self] in
                    self.cpuSampler.reset(); self.networkSampler.reset(); self.diskActivity.reset()
                    self.processSampler.reset(); self.thermal.reset(); self.batterySampler.reset(); PowerReset()
                }
                self.pulse(force: true)
            }
        }
        pulse(force: true)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        generation += 1
        refreshPending = false
    }

    private func reschedule() {
        timer?.schedule(deadline: .now() + (panelOpen ? 1 : 3), repeating: panelOpen ? 1 : 3, leeway: .milliseconds(panelOpen ? 150 : 500))
    }

    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        generation += 1
        cpu.state.celsius = nil
        gpu.state.celsius = nil
        gpu.state.watts = nil
        reschedule()
        // These interval sources are intentionally stopped while the panel is hidden.
        queue.async { [self] in diskActivity.reset(); processSampler.reset(); PowerReset() }
        if open { pulse(force: true) }
    }

    private func expireReadings() {
        let now = SampleClock.now
        func expired(_ health: SampleHealth) -> Bool {
            health.lastSuccess != nil && !health.failed && !health.isFresh(at: now)
        }
        if expired(cpu.health) { cpu.health.record(success: false, at: now); cpu.state.usage = nil; cpu.state.cores = [] }
        if expired(gpu.health) { gpu.health.record(success: false, at: now); gpu.state.usage = nil }
        if expired(cpu.temperatureHealth) { cpu.temperatureHealth.record(success: false, at: now); cpu.state.celsius = nil }
        if expired(gpu.temperatureHealth) { gpu.temperatureHealth.record(success: false, at: now); gpu.state.celsius = nil }
        if expired(gpu.powerHealth) { gpu.powerHealth.record(success: false, at: now); gpu.state.watts = nil }
        if expired(memory.health) { memory.health.record(success: false, at: now) }
        if expired(disk.health) { disk.health.record(success: false, at: now) }
        if expired(network.health) {
            network.health.record(success: false, at: now)
            network.state.downPerSecond = nil; network.state.upPerSecond = nil
        }
        if expired(battery.health) { battery.health.record(success: false, at: now) }
        if expired(fan.health) { fan.health.record(success: false, at: now); fan.fans = [] }
        if expired(processes.health) { processes.health.record(success: false, at: now) }
        publishMenu()
    }

    private func pulse(force: Bool = false) {
        guard timer != nil else { return }
        expireReadings()
        guard !busy else { refreshPending = refreshPending || force; return }
        guard let settings else { return }
        busy = true
        let now = SampleClock.now
        let open = panelOpen
        let slots = [settings.slot1, settings.slot2, settings.slot3]
        let includeCPU = open || slots.contains(.cpu)
        let includeGPU = open || slots.contains(.gpu)
        let includeMemory = open || slots.contains(.memory) || slots.contains(.swap)
        let includeNetwork = open || slots.contains(.network)
        let includeThermal = (open || slots.contains(.temperature) || slots.contains(.fan)) && thermalDue.due(at: now, interval: 3, force: force)
        let includePower = open && powerDue.due(at: now, interval: 3, force: force)
        let requestDiskDetails = open && force && diskDetailDue.due(at: now, interval: 60)
        let includeDisk = (open || slots.contains(.disk)) && diskDue.due(at: now, interval: 60, force: requestDiskDetails)
        // Battery also feeds charge/keep-awake controllers, independently of menu slots.
        let includeBattery = batteryDue.due(at: now, interval: open ? 5 : 15, force: force)
        let includeProcesses = open && processDue.due(at: now, interval: 3, force: force)
        let includeAccessories = open && accessoryDue.due(at: now, interval: 15)
        let allProcesses = processes.includeSystem
        let generation = generation
        queue.async { [self] in
            let cpuReading = includeCPU ? cpuSampler.sample() : nil
            let cpuAt = SampleClock.now
            let gpuUsage = includeGPU ? gpuSampler.utilization() : nil
            let gpuAt = SampleClock.now
            var power = PowerWatts(cpuWatts: -1, gpuWatts: -1)
            if includePower { PowerSample(&power) }
            let powerAt = SampleClock.now
            let gpuWatts: Double? = power.gpuWatts >= 0 && power.gpuWatts.isFinite ? power.gpuWatts : nil
            let net = includeNetwork ? networkSampler.sample() : nil
            let networkAt = SampleClock.now
            let mem = includeMemory ? try? service.memoryStats() : nil
            let memoryAt = SampleClock.now
            let pressure = includeMemory ? MachineInfo.pressureLevel() : nil
            let speed = open ? diskActivity.sample() : nil
            let diskAt = SampleClock.now
            let space = includeDisk ? try? service.diskStats(includePurgeable: open) : nil
            let spaceAt = SampleClock.now
            let temps = includeThermal ? thermal.temperatures() : nil
            let fans = includeThermal ? thermal.fansNow() : nil
            let thermalAt = SampleClock.now
            let batt = includeBattery ? batterySampler.sample() : nil
            let batteryAt = SampleClock.now
            let accessories = includeAccessories ? accessorySampler.sample() : nil
            let rows = includeProcesses ? processSampler.sample(includeSystem: allProcesses) : nil
            let processAt = SampleClock.now
            let thermalState = ProcessInfo.processInfo.thermalState
            let thermalText: String = switch thermalState {
            case .nominal: "Normal"
            case .fair: "Warm"
            case .serious: "Serious"
            case .critical: "Critical"
            @unknown default: "Unknown"
            }
            Task { @MainActor [self] in
                defer {
                    busy = false
                    if refreshPending { refreshPending = false; pulse(force: true) }
                }
                guard generation == self.generation else { refreshPending = true; return }
                if includeCPU {
                    cpuHistory.append(cpuReading?.usage, at: cpuAt)
                    cpu.health.record(success: cpuReading?.usage != nil, at: cpuAt)
                    cpu.state = CPUCardState(usage: cpuReading?.usage, cores: cpuReading?.cores ?? [], celsius: includeThermal ? temps?.cpu : cpu.state.celsius, peakCelsius: includeThermal ? temps?.peak : cpu.state.peakCelsius, coreCount: MachineInfo.coreCount, history: cpuHistory.points, hottestCelsius: includeThermal ? temps?.hottest : cpu.state.hottestCelsius, thermalState: thermalText)
                }
                if includeThermal {
                    cpu.temperatureHealth.record(success: temps?.cpu != nil, at: thermalAt)
                    gpu.temperatureHealth.record(success: temps?.gpu != nil, at: thermalAt)
                    cpu.state.celsius = temps?.cpu
                    cpu.state.peakCelsius = temps?.peak
                    cpu.state.hottestCelsius = temps?.hottest
                    gpu.state.celsius = temps?.gpu
                }
                if includePower {
                    gpu.powerHealth.record(success: gpuWatts != nil, at: powerAt)
                    gpu.state.watts = gpuWatts
                }
                if includeGPU {
                    gpuHistory.append(gpuUsage, at: gpuAt)
                    gpu.health.record(success: gpuUsage != nil, at: gpuAt)
                    gpu.state = GPUCardState(usage: gpuUsage, celsius: gpu.state.celsius, watts: gpu.state.watts, history: gpuHistory.points)
                }
                if includeMemory {
                    memory.health.record(success: mem != nil, at: memoryAt)
                    memoryHistory.append(mem?.usedPercentage, at: memoryAt)
                    pressureHistory.append(pressure.map(Double.init), at: memoryAt)
                    if let mem { memoryStats = mem }
                    if let mem = memoryStats {
                        let label: String = switch pressure {
                        case 1: "Normal"
                        case 2: "High"
                        case 4: "Critical"
                        default: "Unknown"
                        }
                        memory.state = MemoryCardState(used: mem.used, total: mem.total, usedPercent: mem.usedPercentage, pressure: label, history: memoryHistory.points, swapUsed: mem.swapUsed, wired: mem.wired, compressed: mem.compressed, appMemory: max(0, mem.used - mem.wired - mem.compressed), swapIn: mem.swapInPerSecond, swapOut: mem.swapOutPerSecond, pressureHistory: pressureHistory.points, swapAvailable: mem.swapAvailable)
                    }
                }
                if includeDisk {
                    disk.health.record(success: space != nil, at: spaceAt)
                    if let space { diskStats = space }
                }
                if open {
                    readHistory.append(speed?.read, at: diskAt)
                    writeHistory.append(speed?.write, at: diskAt)
                }
                if let space = diskStats {
                    disk.state = DiskCardState(free: space.free, total: space.total, usedPercent: space.usedPercentage, readPerSecond: speed?.read, writePerSecond: speed?.write, device: speed?.device ?? "Internal storage", purgeable: space.purgeable, readHistory: readHistory.points, writeHistory: writeHistory.points)
                }
                if includeNetwork, let net {
                    network.health.record(success: net.down != nil && net.up != nil, at: networkAt)
                    downHistory.append(net.down, at: networkAt)
                    upHistory.append(net.up, at: networkAt)
                    network.state = NetworkCardState(downPerSecond: net.down, upPerSecond: net.up, kind: net.kind, history: downHistory.points, upHistory: upHistory.points)
                }
                if includeThermal {
                    fan.health.record(success: !(fans ?? []).isEmpty, at: thermalAt)
                    if let fans, fans != fan.fans { fan.fans = fans }
                }
                if includeBattery {
                    battery.health.record(success: batt != nil, at: batteryAt)
                    if let batt { if battery.state != batt { battery.state = batt }; onBattery?(batt) }
                }
                if let accessories, accessories != battery.accessories { battery.accessories = accessories }
                if includeProcesses {
                    processes.health.record(success: rows != nil, at: processAt)
                    if allProcesses == processes.includeSystem { processes.rows = rows ?? [] }
                }
                if open {
                    let state = HeaderState(chip: MachineInfo.chip, memory: MachineInfo.memoryText, os: MachineInfo.osText, uptime: MachineInfo.uptimeText)
                    if state != header.state { header.state = state }
                }
                publishMenu()
            }
        }
    }

    private func publishMenu() {
        guard let settings else { return }
        let slots = [settings.slot1, settings.slot2, settings.slot3]
        let items = slots.map { (symbol: $0.symbol, text: menuText($0)) }
        let snapshot = MenuBarSnapshot(items: items, help: zip(slots, items).map { "\($0.0.title) \($0.1.text)" }.joined(separator: ", "))
        guard snapshot != menuSnapshot else { return }
        menuSnapshot = snapshot
        menuChanged?(snapshot)
    }

    private func menuText(_ metric: MenuMetric) -> String {
        let now = SampleClock.now
        switch metric {
        case .cpu: return cpu.health.isFresh(at: now) ? cpu.state.usage.map { String(format: "%.0f%%", $0) } ?? "—" : "—"
        case .gpu: return gpu.health.isFresh(at: now) ? gpu.state.usage.map { String(format: "%.0f%%", $0) } ?? "—" : "—"
        case .memory:
            guard memory.health.isFresh(at: now), let memoryStats else { return "—" }
            return MenuBarViewModel.compactAmount(memoryStats.used, base: 1024)
        case .swap:
            guard memory.health.isFresh(at: now), let memoryStats, memoryStats.swapAvailable else { return "—" }
            return MenuBarViewModel.compactAmount(memoryStats.swapUsed, base: 1024)
        case .disk:
            guard disk.health.isFresh(at: now), let diskStats else { return "—" }
            return MenuBarViewModel.compactAmount(diskStats.used, base: 1000)
        case .network:
            guard network.health.isFresh(at: now), let down = network.state.downPerSecond, let up = network.state.upPerSecond else { return "—" }
            return RateFormat.bytesPerSecond(down + up)
        case .battery:
            guard battery.health.isFresh(at: now), let percent = battery.state?.percent else { return "—" }
            return "\(percent)%"
        case .fan:
            guard fan.health.isFresh(at: now), let rpm = fan.fans.map(\.rpm).max() else { return "—" }
            return String(format: "%.0f", rpm)
        case .temperature:
            guard cpu.temperatureHealth.isFresh(at: now) else { return "—" }
            return cpu.state.celsius.map { String(format: "%.0f°", $0) } ?? "—"
        }
    }
}
