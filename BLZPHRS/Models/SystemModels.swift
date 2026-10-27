import Foundation

nonisolated enum ResourceSeverity: String, Sendable, Equatable {
    case normal = "Normal"
    case moderate = "Moderate"
    case high = "High"
    case critical = "Critical"
}

nonisolated struct DiskStats: Sendable, Equatable {
    let total: Int64
    /// Bytes not allocated in the APFS container. Purgeable data is not included.
    let free: Int64
    /// Allocated bytes the system can delete to satisfy an important write.
    /// Nil when this sample did not measure purgeable space.
    let purgeable: Int64?

    nonisolated var used: Int64 { max(total - free, 0) }

    nonisolated var usedPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }

    nonisolated var freePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(free) / Double(total) * 100
    }

    nonisolated var severity: ResourceSeverity {
        switch freePercentage {
        case ..<10: .critical
        case ..<20: .high
        case ..<30: .moderate
        default: .normal
        }
    }
}

nonisolated struct MemoryStats: Sendable, Equatable {
    let total: Int64
    let used: Int64
    let free: Int64
    let active: Int64
    let inactive: Int64
    let wired: Int64
    let compressed: Int64
    let swapUsed: Int64
    let swapTotal: Int64
    var swapAvailable = true
    var swapInPerSecond: Double?
    var swapOutPerSecond: Double?

    nonisolated var remaining: Int64 {
        max(total - used, 0)
    }

    nonisolated var usedPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100
    }

    nonisolated var severity: ResourceSeverity {
        switch usedPercentage {
        case 90...: .critical
        case 80..<90: .high
        case 65..<80: .moderate
        default: .normal
        }
    }
}

nonisolated struct ProcessMemoryUsage: Identifiable, Sendable, Equatable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let appPath: String?
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64

    nonisolated var id: pid_t { pid }
    nonisolated var displayBytes: UInt64 { physicalFootprintBytes > 0 ? physicalFootprintBytes : residentBytes }
}

nonisolated struct AppUsageGroup: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let appPath: String?
    let processes: [ProcessMemoryUsage]

    nonisolated var totalBytes: UInt64 {
        processes.reduce(0) { $0 + $1.displayBytes }
    }

    nonisolated var primaryPID: pid_t? {
        processes.max { $0.displayBytes < $1.displayBytes }?.pid
    }

    nonisolated var canTerminate: Bool {
        guard let primaryPID else { return false }
        return primaryPID != getpid() && appPath?.hasSuffix(".app") == true && !isSystemApp
    }

    nonisolated var isSystemApp: Bool {
        guard let appPath else { return false }
        return appPath.hasPrefix("/System/")
    }
}

nonisolated struct RecommendedAction: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let subtitle: String
}

nonisolated struct SystemSample: Sendable {
    var memory: MemoryStats?
    var disk: DiskStats?
    var appGroups: [AppUsageGroup]?
    var errorMessage: String?
}
