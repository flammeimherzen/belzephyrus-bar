import Foundation
import MonitoringKit

enum MenuMetric: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case memory
    case swap
    case disk
    case network
    case battery
    case fan
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .swap: "Swap"
        case .disk: "Disk"
        case .network: "Network"
        case .battery: "Battery"
        case .fan: "Fan"
        case .temperature: "Temperature"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .memory: "memorychip"
        case .swap: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .network: "network"
        case .battery: "battery.100"
        case .fan: "fan"
        case .temperature: "thermometer.medium"
        }
    }
}

struct MenuBarSnapshot: Equatable {
    var items: [(symbol: String, text: String)]
    var help: String

    static func == (lhs: MenuBarSnapshot, rhs: MenuBarSnapshot) -> Bool {
        lhs.help == rhs.help && lhs.items.map(\.text) == rhs.items.map(\.text) && lhs.items.map(\.symbol) == rhs.items.map(\.symbol)
    }
}

struct CPUCardState: Equatable {
    var usage: Double?
    var cores: [Double]
    var celsius: Double?
    var peakCelsius: Double?
    var coreCount: Int
    var history: [HistoryPoint] = []
    var hottestCelsius: Double?
    var thermalState: String = "Unknown"
}

struct GPUCardState: Equatable {
    var usage: Double?
    var celsius: Double?
    var watts: Double?
    var history: [HistoryPoint]
}

struct MemoryCardState: Equatable {
    var used: Int64
    var total: Int64
    var usedPercent: Double
    var pressure: String
    var history: [HistoryPoint]
    var swapUsed: Int64
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var appMemory: Int64 = 0
    var swapIn: Double?
    var swapOut: Double?
    var pressureHistory: [HistoryPoint] = []
    var swapAvailable: Bool = true
}

struct DiskCardState: Equatable {
    var free: Int64
    var total: Int64
    var usedPercent: Double
    var readPerSecond: Double?
    var writePerSecond: Double?
    var device: String = "Internal storage"
    var purgeable: Int64?
    var readHistory: [HistoryPoint] = []
    var writeHistory: [HistoryPoint] = []
}

struct NetworkCardState: Equatable {
    var downPerSecond: Double?
    var upPerSecond: Double?
    var kind: String
    var history: [HistoryPoint]
    var upHistory: [HistoryPoint] = []
}

struct FanReading: Equatable {
    var index: Int
    var rpm: Double
    var minimum: Double
    var maximum: Double
    var manual: Bool
}

struct BatteryReading: Equatable {
    var percent: Int
    var healthPercent: Int?
    var isCharging: Bool
    var onAC: Bool
    var watts: Double?
    var minutesRemaining: Int?
    var fullChargeMah: Double
    var remainingMah: Double
    var amperageMa: Double
    var systemLimitPercent: Int?
}

struct AccessoryBattery: Identifiable, Equatable {
    var id: String
    var name: String
    var percent: Int
    var symbol: String
    var charging: Bool = false
}

struct ProcessRowState: Identifiable, Equatable {
    var id: String
    var group: AppUsageGroup
    var cpuPercent: Double?
}

enum ProcessSort: String, Equatable {
    case memory
    case cpu
}

struct HeaderState: Equatable {
    var chip: String
    var memory: String
    var os: String
    var uptime: String
}
