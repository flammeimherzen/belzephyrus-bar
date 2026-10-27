import XCTest
import MonitoringKit
@testable import BLZPHRS

final class EnginePerformanceTests: XCTestCase {
    @MainActor
    func testEngineIdleAndOpenCPUCost() async throws {
        let suite = "MonitoringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let engine = MetricsEngine()
        defer { engine.stop() }
        engine.start(settings: settings)
        // Exclude initial discovery and fixture setup from steady-state measurements.
        try await Task.sleep(for: .seconds(2))
        let closedCPU = cpuSeconds()
        let closedStart = SampleClock.now
        try await Task.sleep(for: .seconds(9))
        print(String(format: "ENGINE closed/default slots: %.3f%% of one core over %.1f s", (cpuSeconds() - closedCPU) / (SampleClock.now - closedStart) * 100, SampleClock.now - closedStart))
        XCTAssertNotNil(engine.memory.state)
        XCTAssertNil(engine.cpu.state.usage) // unselected samplers remain off
        XCTAssertNil(engine.gpu.state.usage)
        XCTAssertTrue(engine.processes.rows.isEmpty)
        engine.setPanelOpen(true)
        try await Task.sleep(for: .seconds(2))
        let openCPU = cpuSeconds()
        let openStart = SampleClock.now
        try await Task.sleep(for: .seconds(9))
        print(String(format: "ENGINE open/all cards: %.3f%% of one core over %.1f s (no rendering)", (cpuSeconds() - openCPU) / (SampleClock.now - openStart) * 100, SampleClock.now - openStart))
        XCTAssertNotNil(engine.cpu.state.usage)
        XCTAssertTrue(engine.cpu.health.isFresh(at: SampleClock.now))
        XCTAssertLessThanOrEqual(engine.cpu.state.history.count, 601)
        engine.setPanelOpen(false)
        let count = engine.cpu.state.history.count
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(engine.cpu.state.history.count, count)
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
