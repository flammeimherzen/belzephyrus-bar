//
//  SystemInfoService.swift
//  BLZPHRS
//
//  Created by belzephyrus on 1/26/26.
//

import Foundation
import Darwin

final class SystemInfoService: @unchecked Sendable {
    nonisolated init() {}

    nonisolated func diskStats() throws -> DiskStats {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])

        guard let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else {
            throw SystemInfoError.diskSpaceUnavailable
        }

        return DiskStats(total: Int64(total), free: Int64(free))
    }

    nonisolated func memoryStats() throws -> MemoryStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            throw SystemInfoError.memoryInfoUnavailable
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageSizeInt64 = Int64(pageSize)

        let totalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        let freeMemory = Int64(stats.free_count) * pageSizeInt64
        let wiredMemory = Int64(stats.wire_count) * pageSizeInt64
        let activeMemory = Int64(stats.active_count) * pageSizeInt64
        let inactiveMemory = Int64(stats.inactive_count) * pageSizeInt64
        let compressedMemory = Int64(stats.compressor_page_count) * pageSizeInt64

        let availableMemory = min(max(freeMemory + inactiveMemory, 0), totalMemory)
        let usedMemory = max(totalMemory - availableMemory, 0)

        return MemoryStats(
            total: totalMemory,
            used: usedMemory,
            free: availableMemory,
            active: activeMemory,
            inactive: inactiveMemory,
            wired: wiredMemory,
            compressed: compressedMemory
        )
    }

    nonisolated func topProcessGroupsByMemory(limit: Int = 10) throws -> [AppUsageGroup] {
        let bufferBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferBytes > 0 else {
            throw SystemInfoError.processListUnavailable
        }

        let maxPids = Int(bufferBytes) / MemoryLayout<pid_t>.size
        var pidBuffer = [pid_t](repeating: 0, count: maxPids)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pidBuffer, bufferBytes)
        guard written > 0 else {
            throw SystemInfoError.processListUnavailable
        }

        let pidCount = Int(written) / MemoryLayout<pid_t>.size
        var samples: [ProcessMemoryUsage] = []
        samples.reserveCapacity(pidCount)

        autoreleasepool {
            for i in 0..<pidCount {
                let pid = pidBuffer[i]
                guard pid > 0, pid != getpid(), let sample = Self.processMemoryUsage(pid: pid) else {
                    continue
                }
                samples.append(sample)
            }
        }

        let groups = Dictionary(grouping: samples) { process in
            process.bundleIdentifier ?? process.appPath ?? process.name
        }
        .map { key, processes in
            let sorted = processes.sorted { $0.displayBytes > $1.displayBytes }
            let primary = sorted[0]
            return AppUsageGroup(
                id: key,
                name: primary.name,
                bundleIdentifier: primary.bundleIdentifier,
                appPath: primary.appPath,
                processes: sorted
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }

        return Array(groups.prefix(limit))
    }

    private nonisolated static func processMemoryUsage(pid: pid_t) -> ProcessMemoryUsage? {
        var taskInfo = proc_taskinfo()
        let got = proc_pidinfo(
            Int32(pid),
            PROC_PIDTASKINFO,
            0,
            &taskInfo,
            Int32(MemoryLayout<proc_taskinfo>.size)
        )
        guard got == MemoryLayout<proc_taskinfo>.size else { return nil }

        let resident = taskInfo.pti_resident_size
        let footprint: UInt64 = 0
        guard resident > 0 || footprint > 0 else { return nil }

        let path = processPath(pid: pid)
        let name = processDisplayName(pid: pid, path: path)
        guard !name.isEmpty else { return nil }

        return ProcessMemoryUsage(
            pid: pid,
            name: name,
            bundleIdentifier: bundleIdentifier(for: path),
            appPath: appPath(for: path),
            residentBytes: resident,
            physicalFootprintBytes: footprint
        )
    }

    private nonisolated static func processPath(pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            return nil
        }
        return String(cString: pathBuffer)
    }

    private nonisolated static func processDisplayName(pid: pid_t, path: String?) -> String {
        if let path {
            return appName(from: path) ?? URL(fileURLWithPath: path).lastPathComponent
        }

        var nameBuffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
            return String(cString: nameBuffer)
        }

        return "pid \(pid)"
    }

    private nonisolated static func appPath(for path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let appIndex = parts.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return path
        }
        return "/" + parts[0...appIndex].joined(separator: "/")
    }

    private nonisolated static func appName(from path: String) -> String? {
        guard let appPath = appPath(for: path) else { return nil }
        return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    }

    private nonisolated static func bundleIdentifier(for path: String?) -> String? {
        guard let appPath = appPath(for: path) else { return nil }
        return Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
    }
}

enum SystemInfoError: LocalizedError {
    case diskSpaceUnavailable
    case memoryInfoUnavailable
    case processListUnavailable

    var errorDescription: String? {
        switch self {
        case .diskSpaceUnavailable:
            "Unable to read disk information"
        case .memoryInfoUnavailable:
            "Unable to read memory information"
        case .processListUnavailable:
            "Unable to read process list"
        }
    }
}
