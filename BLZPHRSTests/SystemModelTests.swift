import XCTest
@testable import BLZPHRS

final class SystemModelTests: XCTestCase {
    func testDiskSeverityLevels() {
        XCTAssertEqual(DiskStats(total: 100, free: 35, purgeable: 0).severity, .normal)
        XCTAssertEqual(DiskStats(total: 100, free: 25, purgeable: 0).severity, .moderate)
        XCTAssertEqual(DiskStats(total: 100, free: 15, purgeable: 0).severity, .high)
        XCTAssertEqual(DiskStats(total: 100, free: 5, purgeable: 0).severity, .critical)
    }

    func testDiskUsedCountsPurgeableAsOccupied() {
        let stats = DiskStats(total: 1_000, free: 200, purgeable: 50)
        XCTAssertEqual(stats.used, 800)
        XCTAssertEqual(stats.usedPercentage, 80, accuracy: 0.001)
    }

    func testDiskUsedWhenPurgeableWasNotMeasured() {
        let stats = DiskStats(total: 1_000, free: 200, purgeable: nil)
        XCTAssertEqual(stats.used, 800)
        XCTAssertNil(stats.purgeable)
    }

    func testContainingAppPathUsesOuterBundle() {
        XCTAssertEqual(
            SystemInfoService.containingAppPath("/Applications/Cursor.app/Contents/MacOS/Cursor"),
            "/Applications/Cursor.app"
        )
        XCTAssertEqual(
            SystemInfoService.containingAppPath("/Applications/Outer.app/Contents/Inner.app/Contents/MacOS/Inner"),
            "/Applications/Outer.app"
        )
        XCTAssertEqual(
            SystemInfoService.containingAppPath("/Applications/Яндекс Музыка.app/Contents/MacOS/Яндекс Музыка"),
            "/Applications/Яндекс Музыка.app"
        )
        XCTAssertNil(SystemInfoService.containingAppPath("/usr/sbin/cfprefsd"))
    }

    func testMenuBarTextChangesOnlyWithVisibleDigits() {
        let low = memoryStats(used: 1_610_612_736)
        let high = memoryStats(used: 1_620_000_000)
        XCTAssertEqual(
            MenuBarViewModel.menuBarText(memory: low, disk: nil).memory,
            MenuBarViewModel.menuBarText(memory: high, disk: nil).memory
        )
        XCTAssertNil(MenuBarViewModel.menuBarText(memory: low, disk: nil).swap)
        let withSwap = memoryStats(used: 1_610_612_736, swapUsed: 50_000_000)
        XCTAssertNotNil(MenuBarViewModel.menuBarText(memory: withSwap, disk: nil).swap)
    }

    func testLiveSampleReadsMemorySwapDiskAndAppFootprint() throws {
        let service = SystemInfoService()
        let background = try service.diskStats()
        XCTAssertNil(background.purgeable)
        XCTAssertGreaterThan(background.total, background.free)
        XCTAssertEqual(background.used, background.total - background.free)

        let detailed = try service.diskStats(includePurgeable: true)
        XCTAssertNotNil(detailed.purgeable)
        XCTAssertGreaterThanOrEqual(detailed.purgeable ?? -1, 0)

        let memory = try service.memoryStats()
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertGreaterThanOrEqual(memory.swapTotal, memory.swapUsed)

        let sample = service.makeSnapshot(includeDetails: true)
        XCTAssertNotNil(sample.memory)
        XCTAssertNotNil(sample.disk?.purgeable)
        XCTAssertNil(sample.errorMessage)
        let groups = try XCTUnwrap(sample.appGroups)
        XCTAssertLessThanOrEqual(groups.count, 10)
        XCTAssertFalse(groups.contains { $0.appPath?.hasPrefix("/System/") == true })
        XCTAssertTrue(groups.allSatisfy { $0.appPath?.hasSuffix(".app") == true })
        if !groups.isEmpty {
            XCTAssertGreaterThanOrEqual(groups[0].totalBytes, groups[groups.count - 1].totalBytes)
            XCTAssertTrue(groups.contains { group in
                group.processes.contains { $0.physicalFootprintBytes > 0 }
            })
        }

        let cached = service.makeSnapshot(includeDetails: true)
        XCTAssertNotNil(cached.appGroups)
    }

    func testOccupiedMemoryMatchesActivityMonitorParts() {
        XCTAssertEqual(
            SystemInfoService.occupiedMemoryBytes(
                pageableInternal: 10,
                purgeable: 3,
                wired: 4,
                compressed: 2,
                total: 20
            ),
            13
        )
        XCTAssertEqual(
            SystemInfoService.occupiedMemoryBytes(
                pageableInternal: 3,
                purgeable: 10,
                wired: 1,
                compressed: 0,
                total: 20
            ),
            1
        )
        XCTAssertEqual(
            SystemInfoService.occupiedMemoryBytes(
                pageableInternal: 30,
                purgeable: 0,
                wired: 5,
                compressed: 5,
                total: 20
            ),
            20
        )
    }

    func testCompactMenuBarAmounts() {
        let gib = 1024.0 * 1024 * 1024
        XCTAssertEqual(MenuBarViewModel.compactAmount(0, base: 1024), "0")
        XCTAssertEqual(MenuBarViewModel.compactAmount(Int64(15.5 * gib), base: 1024), "15.5")
        XCTAssertEqual(MenuBarViewModel.compactAmount(Int64(5 * gib), base: 1024), "5.0")
        XCTAssertEqual(MenuBarViewModel.compactAmount(344 * 1_000_000_000, base: 1000), "344")
        XCTAssertEqual(MenuBarViewModel.compactAmount(Int64(1.2 * 1_000_000_000_000), base: 1000), "1.2T")
        XCTAssertEqual(MenuBarViewModel.compactAmount(512 * 1024 * 1024, base: 1024), "512M")
    }

    func testMemorySeverityLevels() {
        XCTAssertEqual(memoryStats(used: 60).severity, .normal)
        XCTAssertEqual(memoryStats(used: 70).severity, .moderate)
        XCTAssertEqual(memoryStats(used: 85).severity, .high)
        XCTAssertEqual(memoryStats(used: 95).severity, .critical)
    }

    func testAppUsageGroupSortsByDisplayBytes() {
        let low = process(pid: 1, name: "Low", footprint: 100)
        let high = process(pid: 2, name: "High", footprint: 300)
        let group = AppUsageGroup(
            id: "test",
            name: "Test",
            bundleIdentifier: nil,
            appPath: "/Applications/Test.app",
            processes: [low, high]
        )

        XCTAssertEqual(group.totalBytes, 400)
        XCTAssertEqual(group.primaryPID, 2)
        XCTAssertTrue(group.canTerminate)
    }

    func testSystemAppsCannotTerminate() {
        let group = AppUsageGroup(
            id: "system",
            name: "System",
            bundleIdentifier: nil,
            appPath: "/System/Applications/System.app",
            processes: [process(pid: 3, name: "System", footprint: 100)]
        )

        XCTAssertFalse(group.canTerminate)
    }

    private func memoryStats(used: Int64, total: Int64 = 100, swapUsed: Int64 = 0) -> MemoryStats {
        MemoryStats(
            total: total,
            used: used,
            free: total - used,
            active: used,
            inactive: 0,
            wired: 0,
            compressed: 0,
            swapUsed: swapUsed,
            swapTotal: swapUsed
        )
    }

    private func process(pid: pid_t, name: String, footprint: UInt64) -> ProcessMemoryUsage {
        ProcessMemoryUsage(
            pid: pid,
            name: name,
            bundleIdentifier: nil,
            appPath: "/Applications/\(name).app",
            residentBytes: 0,
            physicalFootprintBytes: footprint
        )
    }
}
