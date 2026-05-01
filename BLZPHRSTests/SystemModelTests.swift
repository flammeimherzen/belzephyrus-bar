import XCTest
@testable import BLZPHRS

final class SystemModelTests: XCTestCase {
    func testDiskSeverityLevels() {
        XCTAssertEqual(DiskStats(total: 100, free: 35).severity, .normal)
        XCTAssertEqual(DiskStats(total: 100, free: 25).severity, .moderate)
        XCTAssertEqual(DiskStats(total: 100, free: 15).severity, .high)
        XCTAssertEqual(DiskStats(total: 100, free: 5).severity, .critical)
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

    private func memoryStats(used: Int64) -> MemoryStats {
        MemoryStats(
            total: 100,
            used: used,
            free: 100 - used,
            active: used,
            inactive: 0,
            wired: 0,
            compressed: 0
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
