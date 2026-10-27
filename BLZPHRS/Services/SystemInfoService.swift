//
//  SystemInfoService.swift
//  BLZPHRS
//
//  Created by belzephyrus on 1/26/26.
//

import Foundation
import Darwin
import os
import MonitoringKit

final class SystemInfoService: @unchecked Sendable {
    private var swapInRate = CounterRate()
    private var swapOutRate = CounterRate()
    private struct AppMetadata: Sendable {
        let name: String
        let bundleIdentifier: String?
    }

    private nonisolated let appMetadataCache = OSAllocatedUnfairLock(initialState: [String: AppMetadata]())

    nonisolated init() {}

    /// `includePurgeable` reads the expensive important-usage key. Background refresh leaves it off,
    /// so a missing key cannot drop the disk sample.
    nonisolated func diskStats(includePurgeable: Bool = false) throws -> DiskStats {
        var keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        if includePurgeable {
            keys.insert(.volumeAvailableCapacityForImportantUsageKey)
        }

        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try url.resourceValues(forKeys: keys)
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else {
            throw SystemInfoError.diskSpaceUnavailable
        }

        let free = Int64(available)
        // Capacity In Use keeps purgeable snapshots and caches in "used".
        let purgeable: Int64?
        if includePurgeable, let important = values.volumeAvailableCapacityForImportantUsage {
            purgeable = max(important - free, 0)
        } else {
            purgeable = nil
        }
        return DiskStats(total: Int64(total), free: free, purgeable: purgeable)
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
        let wiredMemory = Int64(stats.wire_count) * pageSizeInt64
        let activeMemory = Int64(stats.active_count) * pageSizeInt64
        let inactiveMemory = Int64(stats.inactive_count) * pageSizeInt64
        let compressedMemory = Int64(stats.compressor_page_count) * pageSizeInt64
        let purgeableMemory = Int64(stats.purgeable_count) * pageSizeInt64
        let pageableInternal = Self.pageableInternalBytes(pageSize: pageSizeInt64)
            ?? (Int64(stats.internal_page_count) * pageSizeInt64)
        let usedMemory = Self.occupiedMemoryBytes(
            pageableInternal: pageableInternal,
            purgeable: purgeableMemory,
            wired: wiredMemory,
            compressed: compressedMemory,
            total: totalMemory
        )

        let swap = Self.swapUsage()
        let now = SampleClock.now
        return MemoryStats(
            total: totalMemory,
            used: usedMemory,
            free: max(totalMemory - usedMemory, 0),
            active: activeMemory,
            inactive: inactiveMemory,
            wired: wiredMemory,
            compressed: compressedMemory,
            swapUsed: swap?.used ?? 0,
            swapTotal: swap?.total ?? 0,
            swapAvailable: swap != nil,
            swapInPerSecond: swapInRate.sample(UInt64(stats.swapins) * UInt64(pageSize), at: now),
            swapOutPerSecond: swapOutRate.sample(UInt64(stats.swapouts) * UInt64(pageSize), at: now)
        )
    }

    /// Activity Monitor's Memory Used: pageable anonymous pages without purgeable data, plus wired and compressor pages.
    nonisolated static func occupiedMemoryBytes(
        pageableInternal: Int64,
        purgeable: Int64,
        wired: Int64,
        compressed: Int64,
        total: Int64
    ) -> Int64 {
        let appMemory = max(pageableInternal - purgeable, 0)
        let used = appMemory + wired + compressed
        return min(max(used, 0), max(total, 0))
    }

    private nonisolated static func pageableInternalBytes(pageSize: Int64) -> Int64? {
        var pages: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("vm.page_pageable_internal_count", &pages, &size, nil, 0) == 0 else {
            return nil
        }
        return Int64(pages) * pageSize
    }

    private nonisolated static func swapUsage() -> (used: Int64, total: Int64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return (
            used: Int64(clamping: usage.xsu_used),
            total: Int64(clamping: usage.xsu_total)
        )
    }

    nonisolated func makeSnapshot(
        includeDetails: Bool,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> SystemSample {
        if isCancelled() { return SystemSample() }

        var sample = SystemSample()
        do {
            sample.memory = try memoryStats()
        } catch {
            sample.errorMessage = error.localizedDescription
        }
        if isCancelled() { return SystemSample() }

        do {
            sample.disk = try diskStats(includePurgeable: includeDetails)
        } catch {
            sample.errorMessage = sample.errorMessage ?? error.localizedDescription
        }
        guard includeDetails, !isCancelled() else { return sample }

        do {
            sample.appGroups = try topProcessGroupsByMemory(limit: 10, isCancelled: isCancelled)
        } catch is CancellationError {
            return SystemSample()
        } catch {
            sample.errorMessage = sample.errorMessage ?? error.localizedDescription
        }
        return sample
    }

    nonisolated func topProcessGroupsByMemory(
        limit: Int = 10,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [AppUsageGroup] {
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
        samples.reserveCapacity(min(pidCount, 256))
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let selfPID = getpid()

        for index in 0..<pidCount {
            if isCancelled() { throw CancellationError() }
            let pid = pidBuffer[index]
            guard pid > 0, pid != selfPID else { continue }
            guard let path = Self.processPath(pid: pid, buffer: &pathBuffer),
                  let appPath = Self.containingAppPath(path),
                  !appPath.hasPrefix("/System/") else {
                continue
            }
            guard let sizes = Self.processSizes(pid: pid) else { continue }
            let metadata = appMetadata(forAppPath: appPath)
            guard !metadata.name.isEmpty else { continue }
            samples.append(
                ProcessMemoryUsage(
                    pid: pid,
                    name: metadata.name,
                    bundleIdentifier: metadata.bundleIdentifier,
                    appPath: appPath,
                    residentBytes: sizes.resident,
                    physicalFootprintBytes: sizes.footprint
                )
            )
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

    nonisolated static func containingAppPath(_ path: String) -> String? {
        let marker: Range<String.Index>
        if let nested = path.range(of: ".app/") {
            marker = nested
        } else if path.hasSuffix(".app"), let suffix = path.range(of: ".app", options: .backwards) {
            marker = suffix
        } else {
            return nil
        }
        let end = path.index(marker.lowerBound, offsetBy: 4)
        guard end <= path.endIndex else { return nil }
        return String(path[..<end])
    }

    private nonisolated func appMetadata(forAppPath appPath: String) -> AppMetadata {
        if let cached = appMetadataCache.withLock({ $0[appPath] }) {
            return cached
        }
        let metadata = AppMetadata(
            name: Self.appDisplayName(appPath: appPath),
            bundleIdentifier: Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
        )
        appMetadataCache.withLock { $0[appPath] = metadata }
        return metadata
    }

    private nonisolated static func appDisplayName(appPath: String) -> String {
        let component: Substring
        if let slash = appPath.lastIndex(of: "/") {
            component = appPath[appPath.index(after: slash)...]
        } else {
            component = Substring(appPath)
        }
        if component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return String(component)
    }

    private struct ProcessSizes {
        let footprint: UInt64
        let resident: UInt64
    }

    /// Activity Monitor's per-process Memory column is `ri_phys_footprint`.
    private nonisolated static func processSizes(pid: pid_t) -> ProcessSizes? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        if status == 0, info.ri_phys_footprint > 0 || info.ri_resident_size > 0 {
            return ProcessSizes(footprint: info.ri_phys_footprint, resident: info.ri_resident_size)
        }

        var taskInfo = proc_taskinfo()
        let got = proc_pidinfo(
            pid,
            PROC_PIDTASKINFO,
            0,
            &taskInfo,
            Int32(MemoryLayout<proc_taskinfo>.size)
        )
        guard got == MemoryLayout<proc_taskinfo>.size, taskInfo.pti_resident_size > 0 else {
            return nil
        }
        return ProcessSizes(footprint: 0, resident: taskInfo.pti_resident_size)
    }

    private nonisolated static func processPath(pid: pid_t, buffer: inout [CChar]) -> String? {
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
            let raw = UnsafeRawBufferPointer(pointer)
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            guard end > raw.startIndex else { return nil }
            return String(decoding: raw[..<end], as: UTF8.self)
        }
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
