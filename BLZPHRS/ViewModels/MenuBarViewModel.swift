import Foundation
import Combine
import AppKit

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var diskStats: DiskStats?
    @Published var memoryStats: MemoryStats?
    @Published var appGroups: [AppUsageGroup] = []
    @Published var recommendedActions: [RecommendedAction] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let systemInfoService: SystemInfoService
    private let terminationService: AppTerminationService
    private let byteFormatter: ByteCountFormatter
    private let shortByteFormatter: ByteCountFormatter
    private var memoryTimer: Timer?
    private var diskTimer: Timer?
    private var processTimer: Timer?
    private var processTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        systemInfoService: SystemInfoService = SystemInfoService(),
        terminationService: AppTerminationService = AppTerminationService()
    ) {
        self.systemInfoService = systemInfoService
        self.terminationService = terminationService
        self.byteFormatter = ByteCountFormatter()
        self.shortByteFormatter = ByteCountFormatter()
        byteFormatter.allowedUnits = [.useGB, .useMB]
        byteFormatter.countStyle = .file
        shortByteFormatter.allowedUnits = [.useGB, .useMB, .useTB]
        shortByteFormatter.countStyle = .file
        shortByteFormatter.allowsNonnumericFormatting = false
    }

    func startUpdating() {
        guard memoryTimer == nil, diskTimer == nil, processTimer == nil else { return }
        refreshAll()
        memoryTimer = scheduledTimer(interval: 10) { [weak self] in self?.updateMemory() }
        diskTimer = scheduledTimer(interval: 10) { [weak self] in self?.updateDisk() }
        processTimer = scheduledTimer(interval: 10) { [weak self] in self?.updateProcessGroups() }
    }

    func stopUpdating() {
        memoryTimer?.invalidate()
        diskTimer?.invalidate()
        processTimer?.invalidate()
        processTask?.cancel()
        memoryTimer = nil
        diskTimer = nil
        processTimer = nil
        processTask = nil
    }

    func refreshAll() {
        isLoading = true
        updateMemory()
        updateDisk()
        updateProcessGroups()
    }

    func quit(_ group: AppUsageGroup) {
        guard let pid = group.primaryPID else { return }
        do {
            try terminationService.quit(pid: pid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forceQuit(_ group: AppUsageGroup) {
        guard let pid = group.primaryPID else { return }
        do {
            try terminationService.forceQuit(pid: pid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func formatBytesShort(_ bytes: Int64) -> String {
        shortByteFormatter.string(fromByteCount: bytes)
    }

    func formatBytesShort(_ bytes: UInt64) -> String {
        formatBytesShort(Int64(min(bytes, UInt64(Int64.max))))
    }

    func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    func formatBytes(_ bytes: UInt64) -> String {
        formatBytes(Int64(min(bytes, UInt64(Int64.max))))
    }

    private func updateMemory() {
        errorMessage = nil
        let service = systemInfoService
        Task {
            do {
                let stats = try await Task.detached(priority: .utility) {
                    try service.memoryStats()
                }.value
                memoryStats = stats
                updateRecommendations()
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func updateDisk() {
        errorMessage = nil
        let service = systemInfoService
        Task {
            do {
                let stats = try await Task.detached(priority: .utility) {
                    try service.diskStats()
                }.value
                diskStats = stats
                updateRecommendations()
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func updateProcessGroups() {
        processTask?.cancel()
        let service = systemInfoService
        processTask = Task {
            do {
                let groups = try await Task.detached(priority: .utility) {
                    try service.topProcessGroupsByMemory(limit: 10)
                }.value
                guard !Task.isCancelled else { return }
                appGroups = groups
                updateRecommendations()
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func updateRecommendations() {
        var actions: [RecommendedAction] = []

        if let memoryStats, memoryStats.severity == .high || memoryStats.severity == .critical,
           let topApp = appGroups.first(where: { $0.canTerminate }) {
            actions.append(
                RecommendedAction(
                    id: "quit-\(topApp.id)",
                    title: "Quit \(topApp.name)",
                    subtitle: "Uses \(formatBytes(topApp.totalBytes)) of memory"
                )
            )
        }

        if let diskStats, diskStats.severity == .high || diskStats.severity == .critical {
            actions.append(
                RecommendedAction(
                    id: "disk-space",
                    title: "Free disk space",
                    subtitle: "\(formatBytes(diskStats.free)) available"
                )
            )
        }

        recommendedActions = Array(actions.prefix(3))
    }

    private func scheduledTimer(interval: TimeInterval, action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        return timer
    }
}
