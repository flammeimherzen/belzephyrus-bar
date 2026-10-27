import AppKit
import SwiftUI
import XCTest
import MonitoringKit
@testable import BLZPHRS

final class DashboardRenderingTests: XCTestCase {
    @MainActor
    func testMetricCardPreview() throws {
        let cpu = CPUModel()
        let gpu = GPUModel()
        let memory = MemoryModel()
        let disk = DiskModel()
        let network = NetworkModel()
        let fan = FanModel()
        let helper = HelperClient()
        let settings = SettingsStore()
        let now = SampleClock.now
        var points: [HistoryPoint] = []
        for index in 0..<100 {
            let time: Double = now - 300.0 + Double(index) * 3.0
            let value: Double? = index == 50 ? nil : Double(20 + index % 15)
            points.append(HistoryPoint(time: time, value: value))
        }
        cpu.state = CPUCardState(usage: 28, cores: [18, 25, 49, 8], celsius: 52, peakCelsius: 64, coreCount: 18, history: points, hottestCelsius: 58, thermalState: "Normal")
        gpu.state = GPUCardState(usage: 5, celsius: 46, watts: 0.2, history: points)
        memory.state = MemoryCardState(used: 40_000_000_000, total: 64_000_000_000, usedPercent: 62.5, pressure: "Normal", history: points, swapUsed: 100_000_000, pressureHistory: points.map { HistoryPoint(time: $0.time, value: 1) })
        disk.state = DiskCardState(free: 500_000_000_000, total: 2_000_000_000_000, usedPercent: 75, readPerSecond: 12_000_000, writePerSecond: 200_000, device: "Internal · disk0")
        let download = points.map { point in HistoryPoint(time: point.time, value: point.value.map { $0 * 100_000 }) }
        let upload = points.map { point in HistoryPoint(time: point.time, value: point.value.map { $0 * 10_000 }) }
        network.state = NetworkCardState(downPerSecond: 2_400_000, upPerSecond: 180_000, kind: "Wi-Fi · en0", history: download, upHistory: upload)
        fan.fans = [FanReading(index: 0, rpm: 2300, minimum: 1800, maximum: 6000, manual: false)]
        cpu.health.record(success: true, at: now)
        gpu.health.record(success: true, at: now)
        memory.health.record(success: true, at: now)
        disk.health.record(success: true, at: now - 30)
        network.health.record(success: true, at: now)
        fan.health.record(success: true, at: now)
        let content = LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            CPUCard(model: cpu)
            GPUCard(model: gpu)
            MemoryCard(model: memory)
            DiskCard(model: disk)
            NetworkCard(model: network, lowLag: LowLagController(helper: helper))
            FanCard(model: fan, control: FanController(helper: helper, settings: settings), helper: helper)
        }.padding(14).frame(width: 372).background(Color(white: 0.08)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 744)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/monitoring-metrics-preview.png"))
    }
}
