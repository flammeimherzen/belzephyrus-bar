import AppKit
import Darwin
import Foundation
import MonitoringKit

/// Opt-in measurement of the shipping UI, not an ImageRenderer or an engine-only test.
/// Inactive in ordinary launches; no monitoring timer or file writes unless requested.
@MainActor
final class PerformanceProbe {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--performance-probe") }

    struct Reading: Codable {
        let elapsed: Double
        let cpuSeconds: Double
        let childCPUSeconds: Double
        let footprintBytes: UInt64
        let residentBytes: UInt64
        let interruptWakeups: UInt64
        let idleWakeups: UInt64
        let panelVisible: Bool
    }

    struct Phase: Codable {
        let name: String
        let readings: [Reading]
    }

    struct Report: Codable {
        let executable: String
        let operatingSystem: String
        let slots: [String]
        let sampleInterval: Int
        let note: String
        let phases: [Phase]
    }

    private let status: StatusBarController
    private let slots: [String]
    private let output: URL
    private var phases: [Phase] = []
    private var readings: [Reading] = []
    private var phase = 0
    private var phaseStart = SampleClock.now
    private var timer: Timer?
    private let sequence: [(name: String, duration: Double, open: Bool)] = ProcessInfo.processInfo.arguments.contains("--layout-preview") ? [("layout", 60, true)] : [
        ("warmup_closed", 20, false), ("closed", 180, false),
        ("warmup_open", 30, true), ("open", 180, true),
        ("closed_again", 60, false)
    ]

    init(status: StatusBarController, settings: SettingsStore) {
        self.status = status
        slots = [settings.slot1.rawValue, settings.slot2.rawValue, settings.slot3.rawValue]
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--performance-output")
        let path = index.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "/tmp/monitoring-performance.json"
        output = URL(fileURLWithPath: path)
    }

    func start() {
        beginPhase()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func beginPhase() {
        let item = sequence[phase]
        if item.open { status.showForProfiling() } else { status.close() }
        phaseStart = SampleClock.now
        readings = [read()]
        print("PERF phase=\(item.name) duration=\(Int(item.duration))s pid=\(getpid())")
        fflush(stdout)
    }

    private func tick() {
        readings.append(read())
        let elapsed = SampleClock.now - phaseStart
        let item = sequence[phase]
        if readings.count % 6 == 1 {
            print("PERF phase=\(item.name) elapsed=\(Int(elapsed))s visible=\(status.panelIsVisible)")
            fflush(stdout)
            save(current: Phase(name: item.name + "_partial", readings: readings))
        }
        guard elapsed >= item.duration else { return }
        phases.append(Phase(name: item.name, readings: readings))
        save()
        phase += 1
        guard phase < sequence.count else {
            timer?.invalidate()
            timer = nil
            status.close()
            print("PERF complete \(output.path)")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        beginPhase()
    }

    private func read() -> Reading {
        var usage = rusage()
        var children = rusage()
        getrusage(RUSAGE_SELF, &usage)
        getrusage(RUSAGE_CHILDREN, &children)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        func seconds(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        return Reading(elapsed: SampleClock.now - phaseStart, cpuSeconds: seconds(usage), childCPUSeconds: seconds(children), footprintBytes: result == 0 ? info.ri_phys_footprint : 0, residentBytes: result == 0 ? info.ri_resident_size : 0, interruptWakeups: info.ri_interrupt_wkups, idleWakeups: info.ri_pkg_idle_wkups, panelVisible: status.panelIsVisible)
    }

    private func save(current: Phase? = nil) {
        let report = Report(executable: Bundle.main.executablePath ?? "", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, slots: slots, sampleInterval: 5, note: "Release app with live NSPanel and menu bar. CPU 100% = one core. Child CPU tracked separately. Shared WindowServer/GPU driver work is not attributable to this process. Hardware controls disabled during probe; samplers and UI unchanged. Visibility checked every sample.", phases: phases + (current.map { [$0] } ?? []))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .atomic)
        } catch {
            print("PERF report error: \(error)")
        }
    }
}
