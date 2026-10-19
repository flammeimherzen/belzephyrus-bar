import SwiftUI
import AppKit

struct MenuBarView: Scene {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(viewModel: viewModel)
        } label: {
            MenuBarLabelView(viewModel: viewModel)
                .onAppear {
                    viewModel.startUpdating()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @State private var forceQuitTarget: AppUsageGroup?
    @State private var showsForceQuitConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("System Information")
                .font(.headline)

            Divider()
            memorySection
            diskSection

            if !viewModel.recommendedActions.isEmpty {
                recommendationsSection
            }

            Divider()
            topAppsSection

            if let errorMessage = viewModel.errorMessage {
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    viewModel.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    viewModel.openActivityMonitor()
                } label: {
                    Label("Activity Monitor", systemImage: "waveform.path.ecg")
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
        }
        .padding(8)
        .frame(width: 370)
        .confirmationDialog(
            "Force quit \(forceQuitTarget?.name ?? "app")?",
            isPresented: $showsForceQuitConfirmation,
            titleVisibility: .visible,
            presenting: forceQuitTarget
        ) { group in
            Button("Force Quit", role: .destructive) {
                viewModel.forceQuit(group)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This may cause unsaved data to be lost.")
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            header("Memory", severity: viewModel.memoryStats?.severity)

            if viewModel.isLoading && viewModel.memoryStats == nil {
                ProgressView().scaleEffect(0.7)
            } else if let stats = viewModel.memoryStats {
                Text("\(viewModel.formatMemory(stats.used)) used of \(viewModel.formatMemory(stats.total))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("\(viewModel.formatMemory(stats.remaining)) available")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Text(swapText(stats))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                progressBar(percentage: stats.usedPercentage, color: color(for: stats.severity))
                Text("Used: \(String(format: "%.1f", stats.usedPercentage))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            header("SSD", severity: viewModel.diskStats?.severity)

            if viewModel.isLoading && viewModel.diskStats == nil {
                ProgressView().scaleEffect(0.7)
            } else if let stats = viewModel.diskStats {
                Text("\(viewModel.formatDisk(stats.used)) used of \(viewModel.formatDisk(stats.total))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("\(viewModel.formatDisk(stats.free)) free")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                if let purgeable = stats.purgeable, purgeable > 0 {
                    Text("\(viewModel.formatDisk(purgeable)) purgeable")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                progressBar(percentage: stats.usedPercentage, color: color(for: stats.severity))
                Text("Used: \(String(format: "%.1f", stats.usedPercentage))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top Memory Apps")
                .font(.subheadline)
                .foregroundColor(.secondary)

            let terminableGroups = viewModel.appGroups.filter(\.canTerminate)
            if terminableGroups.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(terminableGroups.prefix(5))) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Menu {
                            Button("Quit") {
                                viewModel.quit(group)
                            }
                            Button("Force Quit", role: .destructive) {
                                forceQuitTarget = group
                                showsForceQuitConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if group.processes.count > 1 {
                                Text("\(group.processes.count) processes")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(viewModel.formatMemory(group.totalBytes))
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .frame(width: 82, alignment: .trailing)
                            .layoutPriority(1)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recommendation")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let action = viewModel.recommendedActions.first {
                Text(action.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(action.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func header(_ title: String, severity: ResourceSeverity?) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            if let severity {
                Text(severity.rawValue)
                    .font(.caption)
                    .foregroundColor(color(for: severity))
            }
        }
    }

    private func progressBar(percentage: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 5)
                    .cornerRadius(3)
                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(max(percentage, 0), 100) / 100), height: 5)
                    .cornerRadius(3)
            }
        }
        .frame(height: 5)
    }

    private func swapText(_ stats: MemoryStats) -> String {
        let used = viewModel.formatMemory(stats.swapUsed)
        guard stats.swapTotal > 0 else { return "Swap \(used)" }
        return "Swap \(used) of \(viewModel.formatMemory(stats.swapTotal))"
    }

    private func color(for severity: ResourceSeverity) -> Color {
        switch severity {
        case .normal:
            .green
        case .moderate:
            .yellow
        case .high:
            .orange
        case .critical:
            .red
        }
    }
}

struct MenuBarLabelView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        HStack(spacing: 6) {
            metric("memorychip", memoryValue)
            if showsSwap {
                metric("arrow.up.arrow.down", swapValue)
            }
            metric("internaldrive", diskValue)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(viewModel.memoryStats == nil ? .secondary : .primary)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
        .help(helpText)
    }

    private var showsSwap: Bool {
        (viewModel.memoryStats?.swapUsed ?? 0) > 0
    }

    private var memoryValue: String {
        viewModel.memoryStats.map { viewModel.formatMemoryCompact($0.used) } ?? "…"
    }

    private var swapValue: String {
        viewModel.memoryStats.map { viewModel.formatMemoryCompact($0.swapUsed) } ?? "…"
    }

    private var diskValue: String {
        viewModel.diskStats.map { viewModel.formatDiskCompact($0.used) } ?? "…"
    }

    private var helpText: String {
        let ram = viewModel.memoryStats.map {
            "RAM \(viewModel.formatMemory($0.used))"
        } ?? "RAM …"
        let swap = viewModel.memoryStats.map {
            "Swap \(viewModel.formatMemory($0.swapUsed))"
        } ?? "Swap …"
        let disk = viewModel.diskStats.map {
            "SSD \(viewModel.formatDisk($0.used))"
        } ?? "SSD …"
        return "\(ram), \(swap), \(disk)"
    }

    private func metric(_ systemImage: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .symbolRenderingMode(.monochrome)
            Text(value)
                .monospacedDigit()
        }
    }
}
