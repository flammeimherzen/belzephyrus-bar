import Foundation
import Combine
import AppKit
import os

@MainActor
final class MenuBarViewModel: ObservableObject {
    private struct MenuSnapshot: Equatable {
        var diskStats: DiskStats?
        var memoryStats: MemoryStats?
        var appGroups: [AppUsageGroup] = []
        var recommendedActions: [RecommendedAction] = []
        var isLoading = false
        var errorMessage: String?
    }

    @Published private var snapshot = MenuSnapshot()

    var diskStats: DiskStats? { snapshot.diskStats }
    var memoryStats: MemoryStats? { snapshot.memoryStats }
    var appGroups: [AppUsageGroup] { snapshot.appGroups }
    var recommendedActions: [RecommendedAction] { snapshot.recommendedActions }
    var isLoading: Bool { snapshot.isLoading }
    var errorMessage: String? { snapshot.errorMessage }

    private let systemInfoService: SystemInfoService
    private let terminationService: AppTerminationService
    private let diskFormatter: ByteCountFormatter
    private let memoryFormatter: ByteCountFormatter
    private var pulseTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var isMenuOpen = false
    private var lastMetricRefresh = Date.distantPast
    private let refreshGeneration = OSAllocatedUnfairLock(initialState: 0)

    init(
        systemInfoService: SystemInfoService = SystemInfoService(),
        terminationService: AppTerminationService = AppTerminationService()
    ) {
        self.systemInfoService = systemInfoService
        self.terminationService = terminationService
        self.diskFormatter = ByteCountFormatter()
        self.memoryFormatter = ByteCountFormatter()
        diskFormatter.allowedUnits = [.useTB, .useGB, .useMB]
        diskFormatter.countStyle = .file
        diskFormatter.allowsNonnumericFormatting = false
        memoryFormatter.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        memoryFormatter.countStyle = .memory
        memoryFormatter.allowsNonnumericFormatting = false
    }

    func startUpdating() {
        guard pulseTimer == nil else { return }
        if snapshot.memoryStats == nil || snapshot.diskStats == nil {
            var next = snapshot
            next.isLoading = true
            snapshot = next
        }
        pulse()
        // The panel stays allocated after dismiss, and isVisible stays true while it is ordered out.
        // An on-screen window is the signal that the menu is actually open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pulse()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    func stopUpdating() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration.withLock { $0 += 1 }
    }

    func refreshAll() {
        // The button lives in the open panel, which may not have been polled yet.
        isMenuOpen = true
        refresh()
        lastMetricRefresh = Date()
    }

    func quit(_ group: AppUsageGroup) {
        guard let pid = group.primaryPID else { return }
        do {
            try terminationService.quit(pid: pid)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func forceQuit(_ group: AppUsageGroup) {
        guard let pid = group.primaryPID else { return }
        do {
            try terminationService.forceQuit(pid: pid)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func formatDiskCompact(_ bytes: Int64) -> String {
        Self.compactAmount(bytes, base: 1000)
    }

    func formatMemoryCompact(_ bytes: Int64) -> String {
        Self.compactAmount(bytes, base: 1024)
    }

    /// Menu-bar width is shared with every other status item, so values stay short:
    /// `15.5`, `344`, `1.2T`, `512M`.
    nonisolated static func compactAmount(_ bytes: Int64, base: Double) -> String {
        guard bytes > 0, base > 1 else { return "0" }
        let value = Double(bytes)
        let tb = value / pow(base, 4)
        if tb >= 10 { return String(format: "%.0fT", tb) }
        if tb >= 1 { return String(format: "%.1fT", tb) }
        let gb = value / pow(base, 3)
        if gb >= 100 { return String(format: "%.0f", gb) }
        if gb >= 1 { return String(format: "%.1f", gb) }
        let mb = value / pow(base, 2)
        if mb >= 10 { return String(format: "%.0fM", mb) }
        if mb >= 1 { return String(format: "%.1fM", mb) }
        let kb = value / base
        if kb >= 10 { return String(format: "%.0fK", kb) }
        return String(format: "%.1fK", kb)
    }

    nonisolated static func menuBarText(memory: MemoryStats?, disk: DiskStats?) -> (memory: String, swap: String?, disk: String) {
        let memoryText = memory.map { compactAmount($0.used, base: 1024) } ?? "…"
        let swapText: String?
        if let memory, memory.swapUsed > 0 {
            swapText = compactAmount(memory.swapUsed, base: 1024)
        } else {
            swapText = nil
        }
        let diskText = disk.map { compactAmount($0.used, base: 1000) } ?? "…"
        return (memoryText, swapText, diskText)
    }

    func formatDisk(_ bytes: Int64) -> String {
        diskFormatter.string(fromByteCount: bytes)
    }

    func formatMemory(_ bytes: Int64) -> String {
        memoryFormatter.string(fromByteCount: bytes)
    }

    func formatMemory(_ bytes: UInt64) -> String {
        formatMemory(Int64(min(bytes, UInt64(Int64.max))))
    }

    /// MenuBarExtra keeps its panel allocated and `isVisible` after dismiss.
    /// `optionOnScreenOnly` is empty for this process until the panel is actually on screen.
    private static func menuIsVisible() -> Bool {
        let pid = Int(getpid())
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { window in
            let owner = window[kCGWindowOwnerPID as String]
            let ownerPID = (owner as? Int) ?? (owner as? NSNumber)?.intValue
            return ownerPID == pid
        }
    }

    private func pulse() {
        let visible = Self.menuIsVisible()
        if visible != isMenuOpen {
            isMenuOpen = visible
            if visible {
                refresh()
                lastMetricRefresh = Date()
            } else {
                refreshGeneration.withLock { $0 += 1 }
            }
            return
        }
        guard Date().timeIntervalSince(lastMetricRefresh) >= 10 else { return }
        refresh()
        lastMetricRefresh = Date()
    }

    private func refresh() {
        let generation = refreshGeneration.withLock { value -> Int in
            value += 1
            return value
        }
        let includeDetails = isMenuOpen
        let service = systemInfoService
        let generationStore = refreshGeneration
        let isCancelled: @Sendable () -> Bool = {
            Task.isCancelled || generationStore.withLock { $0 != generation }
        }
        let deliver: @MainActor @Sendable (SystemSample) -> Void = { [weak self] sample in
            guard let self, generationStore.withLock({ $0 == generation }) else { return }
            self.apply(sample, publishingDetails: includeDetails)
        }

        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) {
            let sample = service.makeSnapshot(includeDetails: includeDetails, isCancelled: isCancelled)
            guard !isCancelled() else { return }
            await deliver(sample)
        }
    }

    private func apply(_ sample: SystemSample, publishingDetails: Bool) {
        if publishingDetails {
            var next = snapshot
            if let memory = sample.memory { next.memoryStats = memory }
            if let disk = sample.disk { next.diskStats = disk }
            if let groups = sample.appGroups { next.appGroups = groups }
            next.errorMessage = sample.errorMessage
            next.isLoading = false
            next.recommendedActions = recommendations(for: next)
            guard next != snapshot else { return }
            snapshot = next
            return
        }

        let currentText = Self.menuBarText(memory: snapshot.memoryStats, disk: snapshot.diskStats)
        let nextMemory = sample.memory ?? snapshot.memoryStats
        let nextDisk = sample.disk ?? snapshot.diskStats
        let nextText = Self.menuBarText(memory: nextMemory, disk: nextDisk)
        let showsErrorChange = sample.errorMessage != snapshot.errorMessage
        guard nextText != currentText || snapshot.isLoading || showsErrorChange else { return }

        var next = snapshot
        if nextText != currentText {
            if let memory = sample.memory { next.memoryStats = memory }
            if let disk = sample.disk { next.diskStats = disk }
        }
        next.errorMessage = sample.errorMessage
        next.isLoading = false
        guard next != snapshot else { return }
        snapshot = next
    }

    private func recommendations(for snapshot: MenuSnapshot) -> [RecommendedAction] {
        var actions: [RecommendedAction] = []

        if let memoryStats = snapshot.memoryStats,
           memoryStats.severity == .high || memoryStats.severity == .critical,
           let topApp = snapshot.appGroups.first(where: { $0.canTerminate }) {
            actions.append(
                RecommendedAction(
                    id: "quit-\(topApp.id)",
                    title: "Quit \(topApp.name)",
                    subtitle: "Uses \(formatMemory(topApp.totalBytes)) of memory"
                )
            )
        }

        if let diskStats = snapshot.diskStats,
           diskStats.severity == .high || diskStats.severity == .critical {
            actions.append(
                RecommendedAction(
                    id: "disk-space",
                    title: "Free disk space",
                    subtitle: "\(formatDisk(diskStats.free)) available"
                )
            )
        }

        return Array(actions.prefix(3))
    }

    private func setErrorMessage(_ message: String) {
        guard snapshot.errorMessage != message else { return }
        var next = snapshot
        next.errorMessage = message
        snapshot = next
    }
}
