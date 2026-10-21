import AppKit
import Darwin
import Foundation

@MainActor
final class AppTerminationService {
    func quit(_ group: AppUsageGroup) throws {
        let appPath = try signal(group, force: false)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            for pid in self.liveProcessIDs(inAppPath: appPath) {
                kill(pid, SIGKILL)
            }
        }
    }

    func forceQuit(_ group: AppUsageGroup) throws {
        try signal(group, force: true)
    }

    /// Quit has to hit the real app processes. The busiest PID is often a helper that
    /// is not an `NSRunningApplication`, and `terminate()` can report success without
    /// the app exiting while a menu-bar panel is still tracking the click.
    private func signal(_ group: AppUsageGroup, force: Bool) throws -> String {
        guard let appPath = group.appPath, !appPath.isEmpty else {
            throw AppTerminationError.notFound
        }
        if Self.processIsInsideApp(processPath: Bundle.main.bundleURL.path, appPath: appPath) {
            throw AppTerminationError.currentApp
        }

        let apps = runningApplications(inAppPath: appPath, bundleIdentifier: group.bundleIdentifier)
        var pids = liveProcessIDs(inAppPath: appPath)
        if pids.isEmpty {
            pids = apps.map(\.processIdentifier).filter { $0 != getpid() }
        }
        guard !pids.isEmpty else {
            throw AppTerminationError.notFound
        }

        if !force {
            for app in apps {
                app.terminate()
            }
        }

        let signal: Int32 = force ? SIGKILL : SIGTERM
        let delivered = pids.contains { kill($0, signal) == 0 }
        if !delivered && (force || apps.isEmpty) {
            throw AppTerminationError.denied
        }
        return appPath
    }

    private func runningApplications(inAppPath appPath: String, bundleIdentifier: String?) -> [NSRunningApplication] {
        var matches: [NSRunningApplication] = []
        if let bundleIdentifier {
            matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        }
        if matches.isEmpty {
            let target = Self.canonicalPath(appPath)
            matches = NSWorkspace.shared.runningApplications.filter { app in
                guard let path = app.bundleURL?.path else { return false }
                return Self.canonicalPath(path) == target
            }
        }
        let selfPID = getpid()
        return matches.filter { $0.processIdentifier != selfPID }
    }

    private func liveProcessIDs(inAppPath appPath: String) -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var pidBuffer = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pidBuffer, byteCount)
        guard written > 0 else { return [] }

        let count = Int(written) / MemoryLayout<pid_t>.size
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let selfPID = getpid()
        var matches: [pid_t] = []
        matches.reserveCapacity(8)

        for index in 0..<count {
            let pid = pidBuffer[index]
            guard pid > 0, pid != selfPID else { continue }
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = pathBuffer.withUnsafeBufferPointer { pointer in
                let raw = UnsafeRawBufferPointer(pointer)
                let end = raw.firstIndex(of: 0) ?? raw.endIndex
                guard end > raw.startIndex else { return "" }
                return String(decoding: raw[..<end], as: UTF8.self)
            }
            if Self.processIsInsideApp(processPath: path, appPath: appPath) {
                matches.append(pid)
            }
        }
        return matches
    }

    nonisolated static func processIsInsideApp(processPath: String, appPath: String) -> Bool {
        let process = canonicalPath(processPath)
        let root = canonicalPath(appPath)
        guard !process.isEmpty, !root.isEmpty else { return false }
        return process == root || process.hasPrefix(root + "/")
    }

    private nonisolated static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum AppTerminationError: LocalizedError {
    case currentApp
    case notFound
    case denied

    var errorDescription: String? {
        switch self {
        case .currentApp:
            "Monitoring cannot quit itself from the process list"
        case .notFound:
            "The app is no longer running"
        case .denied:
            "macOS did not allow this app to be quit"
        }
    }
}
