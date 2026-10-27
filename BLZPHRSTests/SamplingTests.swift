import XCTest
import MonitoringKit
@testable import BLZPHRS

final class SamplingTests: XCTestCase {
    func testRateWarmupZeroResetMissingAndSleep() {
        var rate = CounterRate()
        XCTAssertNil(rate.sample(100, at: 0))
        XCTAssertEqual(rate.sample(400, at: 3), 100)
        XCTAssertEqual(rate.sample(400, at: 4), 0)
        XCTAssertNil(rate.sample(10, at: 5)) // counter reset / device replaced
        XCTAssertEqual(rate.sample(110, at: 6), 100)
        XCTAssertNil(rate.sample(nil, at: 7))
        XCTAssertNil(rate.sample(300, at: 8))
        XCTAssertNil(rate.sample(9_000, at: 80)) // sleep or hidden panel
        XCTAssertEqual(rate.sample(9_100, at: 81), 100)
        rate.reset()
        XCTAssertNil(rate.sample(9_200, at: 82))
    }

    func testRateRejectsInvalidOrTinyIntervals() {
        var rate = CounterRate()
        XCTAssertNil(rate.sample(100, at: 1))
        XCTAssertNil(rate.sample(200, at: 1))
        XCTAssertNil(rate.sample(300, at: 1.01))
        XCTAssertNil(rate.sample(400, at: .nan))
        XCTAssertNil(rate.sample(500, at: 3))
    }

    func testTimeHistoryWindowAndRollingPeak() {
        var history = MetricHistory(duration: 300)
        history.append(90, at: 0)
        history.append(70, at: 299)
        XCTAssertEqual(history.maximum(at: 300), 90)
        history.append(60, at: 301)
        XCTAssertEqual(history.maximum(at: 301), 70)
        history.append(nil, at: 302)
        XCTAssertNil(history.points.last?.value)
        XCTAssertEqual(history.points.map(\.time), [299, 301, 302])
        XCTAssertNil(history.maximum(at: 700))
    }

    func testHistoryBoundsAndInvalidValues() {
        var history = MetricHistory()
        for index in 0..<10_000 { history.append(Double(index), at: Double(index) / 100) }
        XCTAssertEqual(history.points.count, 601)
        history.append(.infinity, at: 200)
        XCTAssertNil(history.points.last?.value)
        let count = history.points.count
        history.append(99, at: 199)
        XCTAssertEqual(history.points.count, count)
    }

    func testHealthNeverEquatesFailureWithZero() {
        var health = SampleHealth(source: "test", lifetime: 10)
        XCTAssertFalse(health.isFresh(at: 0))
        XCTAssertEqual(health.label(at: 0), "Unavailable")
        health.record(success: true, at: 1)
        XCTAssertTrue(health.isFresh(at: 5))
        XCTAssertFalse(health.isFresh(at: 12))
        health.record(success: false, at: 6)
        XCTAssertEqual(health.lastSuccess, 1)
        XCTAssertEqual(health.label(at: 6), "Stale · 5s ago")
        health.record(success: true, at: 7)
        XCTAssertTrue(health.isFresh(at: 7))
    }

    func testBackgroundDeadlinesDoNotAlias() {
        var deadline = SampleDeadline()
        let times = stride(from: 0.0, through: 60.0, by: 3).filter { deadline.due(at: $0, interval: 15) }
        XCTAssertEqual(times, [0, 15, 30, 45, 60])
        XCTAssertTrue(deadline.due(at: 61, interval: 15, force: true))
        XCTAssertFalse(deadline.due(at: 62, interval: 15))
    }

    func testChargeTargetAndInvalidInputs() {
        XCTAssertEqual(ChargeEstimate.seconds(toLimit: 0.9, fullChargeMah: 6000, remainingMah: 4800, amperageMa: 1200), 1800)
        XCTAssertEqual(ChargeEstimate.seconds(toLimit: 0.8, fullChargeMah: 6000, remainingMah: 4800, amperageMa: 1200), 0)
        XCTAssertNil(ChargeEstimate.seconds(toLimit: 0.8, fullChargeMah: 6000, remainingMah: 4800, amperageMa: 0))
        XCTAssertNil(ChargeEstimate.seconds(toLimit: 1.1, fullChargeMah: 6000, remainingMah: 4800, amperageMa: 1200))
    }

    func testLiveSamplerWarmupAndCost() throws {
        let cpu = CPUSampler()
        let disk = DiskActivitySampler()
        let network = NetworkSampler()
        let gpu = GPUSampler()
        let thermal = ThermalSampler()
        let service = SystemInfoService()
        XCTAssertNil(cpu.sample().usage)
        XCTAssertNil(disk.sample().read)
        XCTAssertNil(network.sample().down)
        _ = gpu.utilization()
        _ = thermal.temperatures()
        var power = PowerWatts()
        PowerReset()
        PowerSample(&power)
        XCTAssertLessThan(power.gpuWatts, 0)
        Thread.sleep(forTimeInterval: 0.15)
        let cpuValue = try XCTUnwrap(cpu.sample().usage)
        XCTAssertTrue((0...100).contains(cpuValue))
        let drive = disk.sample()
        print("SAMPLER internal drive: \(drive.device); read: \(String(describing: drive.read))")
        if drive.read != nil { XCTAssertTrue(drive.device.contains("disk")) }
        let start = SampleClock.now
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        for _ in 0..<10 {
            _ = cpu.sample(); _ = gpu.utilization(); _ = network.sample()
            _ = disk.sample(); _ = try service.memoryStats()
            _ = thermal.temperatures(); _ = thermal.fansNow()
            PowerSample(&power)
        }
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let cpuSeconds = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
        print(String(format: "SAMPLER fast cycle mean: %.3f ms wall, %.3f ms CPU (10 warm cycles)", (SampleClock.now - start) * 100, cpuSeconds * 100))
        let tasks: [(String, () -> Void)] = [
            ("CPU", { _ = cpu.sample() }), ("GPU", { _ = gpu.utilization() }),
            ("network", { _ = network.sample() }), ("disk", { _ = disk.sample() }),
            ("memory", { _ = try? service.memoryStats() }), ("temperature", { _ = thermal.temperatures() }),
            ("fans", { _ = thermal.fansNow() }), ("power", { PowerSample(&power) })
        ]
        for (name, task) in tasks {
            var before = rusage(); getrusage(RUSAGE_SELF, &before)
            let start = SampleClock.now
            for _ in 0..<5 { task() }
            var after = rusage(); getrusage(RUSAGE_SELF, &after)
            let used = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
            print(String(format: "SAMPLER %@: %.3f ms wall, %.3f ms CPU", name, (SampleClock.now - start) * 200, used * 200))
        }
        let processStart = SampleClock.now
        let processes = ProcessSampler()
        _ = processes.sample()
        print(String(format: "SAMPLER application scan: %.3f ms", (SampleClock.now - processStart) * 1000))
        cpu.reset(); disk.reset(); network.reset(); PowerReset()
        XCTAssertNil(cpu.sample().usage)
        XCTAssertNil(disk.sample().read)
        XCTAssertNil(network.sample().down)
    }

    private func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }
}
