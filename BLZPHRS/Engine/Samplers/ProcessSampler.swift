import Darwin
import Foundation
import MonitoringKit
import os

final class ProcessSampler: @unchecked Sendable {
    private struct Tick {
        var cpu: UInt64
        var wall: UInt64
        var start: UInt64
    }

    private var previous: [pid_t: Tick] = [:]
    private var lastSample: Double?
    func reset() { previous = [:]; lastSample = nil }
    private let metadata = OSAllocatedUnfairLock(initialState: [String: (name: String, bundle: String?)]())
    private let responsibility: (@convention(c) (pid_t, UnsafeMutablePointer<pid_t>) -> Int32)?

    init() {
        let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        responsibility = symbol.map { unsafeBitCast($0, to: (@convention(c) (pid_t, UnsafeMutablePointer<pid_t>) -> Int32).self) }
    }

    func sample(includeSystem: Bool = false) -> [ProcessRowState]? {
        let now = SampleClock.now
        if let lastSample, now - lastSample > 10 { reset() }
        lastSample = now
        let bufferBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferBytes > 0 else { reset(); return nil }
        let maxPids = Int(bufferBytes) / MemoryLayout<pid_t>.size
        var pidBuffer = [pid_t](repeating: 0, count: maxPids)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pidBuffer, bufferBytes)
        guard written > 0 else { reset(); return nil }

        let wall = mach_absolute_time()
        let selfPID = getpid()
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var rows: [String: (path: String, footprint: UInt64, cpu: Double?, pid: pid_t)] = [:]
        var nextTicks: [pid_t: Tick] = [:]
        let pidCount = Int(written) / MemoryLayout<pid_t>.size

        for index in 0..<pidCount {
            let pid = pidBuffer[index]
            guard pid > 0, includeSystem || pid != selfPID else { continue }
            guard let path = processPath(pid: pid, buffer: &pathBuffer) else { continue }
            let appPath = SystemInfoService.containingAppPath(path)
            if !includeSystem && (appPath == nil || !isUserFacing(appPath!)) { continue }
            guard let sizes = processSizes(pid: pid) else { continue }
            let cpuTicks = sizes.user &+ sizes.system
            let percent: Double?
            if let previous = previous[pid], previous.start == sizes.start, cpuTicks >= previous.cpu {
                percent = CPUTime.percent(deltaTicks: cpuTicks &- previous.cpu, deltaWallTicks: wall &- previous.wall)
            } else {
                percent = nil
            }
            nextTicks[pid] = Tick(cpu: cpuTicks, wall: wall, start: sizes.start)
            let owner = includeSystem ? pid : responsiblePID(pid)
            let ownerPath = includeSystem ? "\(path)#\(pid)" : (owner == pid ? appPath! : (processPath(pid: owner, buffer: &pathBuffer).flatMap(SystemInfoService.containingAppPath) ?? appPath!))
            guard includeSystem || (isUserFacing(ownerPath) && ownerPath != Bundle.main.bundleURL.path) else { continue }
            let footprint = sizes.footprint > 0 ? sizes.footprint : sizes.resident
            if var existing = rows[ownerPath] {
                existing.footprint += footprint
                if let existingCPU = existing.cpu, let percent { existing.cpu = existingCPU + percent } else { existing.cpu = nil }
                rows[ownerPath] = existing
            } else {
                rows[ownerPath] = (ownerPath, footprint, percent, owner)
            }
        }
        previous = nextTicks

        let groups: [ProcessRowState] = rows.map { _, value in
            let meta = includeSystem ? (name: URL(fileURLWithPath: String(value.path.split(separator: "#").first ?? "")).lastPathComponent + " · \(value.pid)", bundle: nil as String?) : metadata(for: value.path)
            let process = ProcessMemoryUsage(
                pid: value.pid,
                name: meta.name,
                bundleIdentifier: meta.bundle,
                appPath: includeSystem ? nil : value.path,
                residentBytes: value.footprint,
                physicalFootprintBytes: value.footprint
            )
            let group = AppUsageGroup(
                id: value.path,
                name: meta.name,
                bundleIdentifier: meta.bundle,
                appPath: includeSystem ? nil : value.path,
                processes: [process]
            )
            return ProcessRowState(id: group.id, group: group, cpuPercent: value.cpu)
        }
        return groups.sorted { $0.group.totalBytes > $1.group.totalBytes }
    }

    private func isUserFacing(_ path: String) -> Bool {
        if path.contains("/System/Library/Frameworks/") { return false }
        if path.contains("/System/Library/PrivateFrameworks/") { return false }
        if path.contains("/System/Library/ExtensionKit/") { return false }
        return path.hasSuffix(".app") || path.contains(".app/")
    }

    private func responsiblePID(_ pid: pid_t) -> pid_t {
        if let responsibility {
            var responsible = pid_t(0)
            if responsibility(pid, &responsible) == 0, responsible > 0 { return responsible }
        }
        var current = pid
        for _ in 0..<6 {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard size == MemoryLayout<proc_bsdinfo>.size else { break }
            let parent = pid_t(info.pbi_ppid)
            if parent <= 1 || parent == current { break }
            current = parent
        }
        return current
    }

    private func metadata(for appPath: String) -> (name: String, bundle: String?) {
        if let cached = metadata.withLock({ $0[appPath] }) { return cached }
        let name = Self.displayName(appPath: appPath)
        let bundle = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
        let value = (name, bundle)
        metadata.withLock { $0[appPath] = value }
        return value
    }

    private struct Sizes {
        var footprint: UInt64
        var resident: UInt64
        var user: UInt64
        var system: UInt64
        var start: UInt64
    }

    private func processSizes(pid: pid_t) -> Sizes? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        return Sizes(
            footprint: info.ri_phys_footprint,
            resident: info.ri_resident_size,
            user: info.ri_user_time,
            system: info.ri_system_time,
            start: info.ri_proc_start_abstime
        )
    }

    private static func displayName(appPath: String) -> String {
        let component: Substring
        if let slash = appPath.lastIndex(of: "/") {
            component = appPath[appPath.index(after: slash)...]
        } else {
            component = Substring(appPath)
        }
        return component.hasSuffix(".app") ? String(component.dropLast(4)) : String(component)
    }

    private func processPath(pid: pid_t, buffer: inout [CChar]) -> String? {
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            let raw = UnsafeRawBufferPointer(pointer)
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            guard end > raw.startIndex else { return nil }
            return String(decoding: raw[..<end], as: UTF8.self)
        }
    }
}
