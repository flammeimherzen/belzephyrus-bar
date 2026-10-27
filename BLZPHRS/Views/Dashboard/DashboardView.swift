import AppKit
import Combine
import MonitoringKit
import ServiceManagement
import SwiftUI

struct DashboardView: View {
    let header: HeaderModel
    let cpu: CPUModel
    let gpu: GPUModel
    let memory: MemoryModel
    let disk: DiskModel
    let network: NetworkModel
    let fan: FanModel
    let battery: BatteryModel
    let processes: ProcessModel
    @ObservedObject var fanControl: FanController
    @ObservedObject var helper: HelperClient
    @ObservedObject var charge: ChargeLimitController
    @ObservedObject var lowLag: LowLagController
    @ObservedObject var awake: KeepAwakeController
    @ObservedObject var screen: CleanScreenController
    @ObservedObject var privacy: PrivacyMonitor
    @ObservedObject var brightness: BrightnessController
    var moleRunning: Bool

    var body: some View {
        VStack(spacing: 10) {
            HeaderCard(model: header)
            if moleRunning {
                Text("Mole is running. Set its fan to Auto and turn off its charge limit and Low Lag, or quit Mole.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(spacing: 8) {
                            CPUCard(model: cpu)
                            MemoryCard(model: memory)
                            NetworkCard(model: network, lowLag: lowLag)
                        }
                        .frame(width: 171.5)
                        VStack(spacing: 8) {
                            GPUCard(model: gpu)
                            DiskCard(model: disk)
                            FanCard(model: fan, control: fanControl, helper: helper)
                        }
                        .frame(width: 171.5)
                    }
                    .frame(width: 351)
                    VStack(spacing: 8) {
                        BrightnessCard(brightness: brightness)
                        BatteryCard(model: battery, charge: charge)
                        ProcessCard(model: processes)
                    }
                    .frame(width: 351, height: 496, alignment: .top)
                }
            }
            .scrollIndicators(.visible)
            BottomBar(privacy: privacy, awake: awake, screen: screen)
        }
        .padding(14)
        .background(panelBackground)
    }
}

private struct HeaderCard: View {
    @ObservedObject var model: HeaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                chip(model.state.chip)
                chip(model.state.memory)
                chip(model.state.os)
                chip(model.state.uptime)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CPUCard: View {
    @ObservedObject var model: CPUModel

    var body: some View {
        metricCard {
            title("CPU", value: percent(model.state.usage), extra: degrees(model.state.celsius))
            chartSlot { Sparkline(values: model.state.history, ceiling: 100, unit: "%") }
            footnote("\(caption) · \(model.state.thermalState)")
        }

    }

    private var caption: String { "\(model.state.coreCount) cores" }
}

struct GPUCard: View {
    @ObservedObject var model: GPUModel

    var body: some View {
        metricCard {
            title("GPU", value: percent(model.state.usage), extra: degrees(model.state.celsius))
            chartSlot { Sparkline(values: model.state.history, ceiling: 100, unit: "%") }
            footnote(caption)
        }

    }

    private var caption: String {
        if let watts = model.state.watts {
            return String(format: "%.1fW", watts)
        }
        return "Power —"
    }
}

struct MemoryCard: View {
    @ObservedObject var model: MemoryModel

    var body: some View {
        metricCard {
            if let state = model.state {
                title("Memory pressure", value: state.pressure, extra: percent(state.usedPercent))
                    .foregroundStyle(pressureColor(state.pressure))
                chartSlot { Sparkline(values: state.pressureHistory, ceiling: 4, unit: "pressure", color: pressureColor(state.pressure)) }
                footnote("\(memory(state.used)) / \(memory(state.total))")
            } else {
                title("Memory", value: "—", extra: "Unavailable")
            }
        }

    }
}

struct DiskCard: View {
    @ObservedObject var model: DiskModel

    var body: some View {
        metricCard {
            if let state = model.state {
                title("Free space", value: decimal(state.free), extra: "of \(decimal(state.total))")
                chartSlot { bar(fraction: 1 - state.usedPercent / 100) }
                footnote("R \(rate(state.readPerSecond)) · W \(rate(state.writePerSecond))")
            } else {
                title("Free space", value: "—", extra: nil)
            }
        }

    }
}

struct NetworkCard: View {
    @ObservedObject var model: NetworkModel
    @ObservedObject var lowLag: LowLagController

    var body: some View {
        metricCard {
            title("Network", value: rate(model.state.downPerSecond), extra: model.state.kind)
            chartSlot { Sparkline(values: model.state.history, secondary: model.state.upHistory, unit: "B/s") }
            HStack(spacing: 4) {
                Text("Up \(rate(model.state.upPerSecond))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)
                Button(lowLag.enabled ? "On" : "Low Lag") {
                    lowLag.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(lowLag.enabled ? accent : nil)
                .help(lowLag.message ?? "Turns off AWDL. AirDrop and iPhone Mirroring stop until Low Lag is off.")
            }
            .frame(height: 16)
        }
        .help("Last 5 min · solid download · dashed upload. Primary interface only; VPN traffic is not added twice.")
    }
}

struct FanCard: View {
    @ObservedObject var model: FanModel
    @ObservedObject var control: FanController
    @ObservedObject var helper: HelperClient

    var body: some View {
        metricCard {
            title("Fan", value: rpmText, extra: speedText)
            footnote(control.message ?? helperHint)
                .frame(height: 58, alignment: .center)
                .help(helperHelp + "\n" + model.fans.map { "Fan \($0.index + 1): \(Int($0.rpm)) RPM" }.joined(separator: "\n"))
            if case .enabled = helper.status {
                Picker("Mode", selection: Binding(get: { control.mode }, set: { control.select($0) })) {
                    ForEach(FanMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            } else if case .needsApproval = helper.status {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Install helper") { helper.install() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var fastest: FanReading? { model.fans.max { $0.rpm < $1.rpm } }

    private var rpmText: String {
        guard let fastest else { return "—" }
        return String(format: "%.0f RPM", fastest.rpm)
    }

    private var speedText: String {
        guard let fastest else { return "—" }
        let percent = fastest.maximum > 0 ? min(100, fastest.rpm / fastest.maximum * 100) : 0
        return String(format: "%.0f%% max", percent)
    }

    private var helperHint: String {
        switch helper.status {
        case .enabled: return detail
        case .needsApproval: return "Allow it in Login Items"
        case .notRegistered: return "Password installs the fan helper"
        case .unavailable: return "Install failed"
        }
    }

    private var helperHelp: String {
        if case .unavailable(let reason) = helper.status { return reason }
        return control.message ?? helperHint
    }

    private var detail: String {
        if model.fans.contains(where: \.manual), control.mode == .auto {
            return "Manual fan control detected"
        }
        switch control.mode {
        case .auto: return "Managed by macOS"
        case .cool: return "Starts at \(control.floorPercent)%, faster as it heats"
        case .max: return "Holding at maximum"
        }
    }
}

private struct BrightnessCard: View {
    @ObservedObject var brightness: BrightnessController

    var body: some View {
        if brightness.macAvailable || brightness.externalConnected {
            card {
                Text("Brightness")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if brightness.macAvailable {
                    row("MacBook", value: Binding(get: { brightness.mac }, set: { brightness.setMac($0) }), editing: brightness.setEditingMac)
                }
                if brightness.externalConnected {
                    row(
                        "External",
                        value: Binding(get: { brightness.external }, set: { brightness.setExternal($0) }),
                        editing: brightness.setEditingExternal,
                        percent: brightness.externalKnown ? "\(Int((brightness.external * 100).rounded()))%" : "—"
                    )
                }
            }
        }
    }

    private func row(_ title: String, value: Binding<Double>, editing: @escaping (Bool) -> Void, percent: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: 0...1, onEditingChanged: editing)
                .controlSize(.small)
            Text(percent ?? "\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
        .frame(height: 22)
    }
}

private struct BatteryCard: View {
    @ObservedObject var model: BatteryModel
    @ObservedObject var charge: ChargeLimitController

    var body: some View {
        card {
            if let state = model.state {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(state.percent)%")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let health = state.healthPercent {
                        Text("≈\(health)% Health")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack {
                Text(detail(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)
                }
                if !model.accessories.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(model.accessories) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .center)
                                Text(deviceTitle(item.name))
                                    .font(.callout)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if item.charging {
                                    Image(systemName: "bolt.fill")
                                        .font(.caption2)
                                        .foregroundStyle(accent)
                                }
                                Text("\(item.percent)%")
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 48, alignment: .trailing)
                            }
                            .frame(height: 22)
                            .help(item.name)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Toggle(charge.usesSystemLimit ? "Limit \(charge.systemLimitPercent ?? 80)%" : "Limit 80%", isOn: Binding(
                        get: { charge.enabled },
                        set: { charge.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(charge.usesSystemLimit ? "Set in System Settings → Battery" : "Limit charging to 80%")
                    Button("Charge to 100%") { charge.chargeToFull() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
                if let message = charge.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            } else {
                Text("Battery").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ state: BatteryReading) -> String {
        if let watts = state.watts, watts < -0.05 {
            return String(format: "Discharging %.1f W", abs(watts)) + (state.onAC ? " · plugged in" : " · on battery")
        }
        if state.isCharging {
            let watts = state.watts.map { String(format: "Charging power %.1fW", $0) } ?? "Charging"
            let limit = state.systemLimitPercent ?? (charge.enabled ? 80 : 100)
            if limit < 100, let seconds = ChargeEstimate.seconds(toLimit: Double(limit) / 100, fullChargeMah: state.fullChargeMah, remainingMah: state.remainingMah, amperageMa: state.amperageMa), seconds > 1 {
                return "\(watts) · ≈\(Int(ceil(seconds / 60))) min to \(limit)%"
            }
            if let minutes = state.minutesRemaining {
                return "\(watts) · full in \(minutes / 60):\(String(format: "%02d", minutes % 60))"
            }
            return watts
        }
        if let minutes = state.minutesRemaining, !state.onAC {
            return "On battery · ≈\(minutes / 60) hr \(minutes % 60) min left"
        }
        return state.onAC ? "Plugged in" : state.watts.map { String(format: "On battery · %.1f W discharge", abs($0)) } ?? "On battery"
    }

    private func deviceTitle(_ name: String) -> String {
        let lower = name.lowercased()
        let side: String
        if lower.hasSuffix(" left") { side = " L" }
        else if lower.hasSuffix(" right") { side = " R" }
        else if lower.hasSuffix(" case") { side = " Case" }
        else { side = "" }
        let base: String
        if lower.contains("airpod") || lower.contains("buds") || lower.contains("headphone") {
            base = lower.contains("airpod") ? "AirPods" : name
        } else if lower.contains("mouse") {
            base = "Mouse"
        } else if lower.contains("keyboard") && lower.contains("trackpad") {
            base = "Keyboard"
        } else if lower.contains("keyboard") || lower.contains("key") {
            base = "Keyboard"
        } else if lower.contains("trackpad") || lower.contains("track") {
            base = "Trackpad"
        } else if lower.contains("watch") {
            base = "Watch"
        } else if lower.contains("pencil") {
            base = "Pencil"
        } else {
            var trimmed = name
            for suffix in [" left", " right", " case"] where trimmed.lowercased().hasSuffix(suffix) {
                trimmed = String(trimmed.dropLast(suffix.count))
            }
            if trimmed.hasPrefix("Apple ") { trimmed = String(trimmed.dropFirst(6)) }
            base = trimmed
        }
        return base + side
    }
}

struct ProcessCard: View {
    @ObservedObject var model: ProcessModel
    @State private var pending: AppUsageGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
            Text(model.includeSystem ? "All Processes" : "Applications")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            }
            Toggle("Include system processes", isOn: $model.includeSystem)
                .toggleStyle(.switch).controlSize(.mini)
                .onChange(of: model.includeSystem) { model.rows = [] }
            Picker("Sort", selection: $model.sort) {
                Text("Memory").tag(ProcessSort.memory)
                Text("% CPU").tag(ProcessSort.cpu)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Process CPU: 100% = one core; can exceed 100%. Memory is physical footprint.")
            if model.visible.isEmpty {
                Text(model.health.failed ? "Process data unavailable" : "Waiting for samples…").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
            VStack(spacing: 6) {
            ForEach(model.visible) { row in
                HStack(spacing: 8) {
                    Text(row.group.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.sort == .cpu ? percent(row.cpuPercent) : memory(Int64(row.group.totalBytes)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Menu {
                        Button("Quit") { pending = row.group }
                        Button("Force Quit") { pending = row.group }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 18)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!row.group.canTerminate || !model.health.isFresh(at: SampleClock.now))
                }
                .font(.callout)
            }
            }
            }
            .frame(maxHeight: .infinity)
            .scrollIndicators(.visible)
            if let pending {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quit \(pending.name)? This may cause unsaved data to be lost.")
                        .font(.caption)
                    HStack {
                        Button("Quit") { terminate(pending, force: false) }
                        Button("Force Quit") { terminate(pending, force: true) }
                        Button("Cancel") { self.pending = nil }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func terminate(_ group: AppUsageGroup, force: Bool) {
        let service = AppTerminationService()
        if force { try? service.forceQuit(group) } else { try? service.quit(group) }
        pending = nil
    }
}

private struct BottomBar: View {
    @ObservedObject var privacy: PrivacyMonitor
    @ObservedObject var awake: KeepAwakeController
    @ObservedObject var screen: CleanScreenController

    var body: some View {
        HStack(spacing: 6) {
            Label(privacy.text, systemImage: privacy.camera || privacy.microphone ? "video.fill" : "video.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Button("15 minutes") { awake.start(minutes: 15) }
                Button("1 hour") { awake.start(minutes: 60) }
                Button("2 hours") { awake.start(minutes: 120) }
                Button("Until turned off") { awake.start(minutes: nil) }
                if awake.active {
                    Button("Stop") { awake.stop() }
                }
            } label: {
                barLabel(awake.remainingText ?? "Awake", systemImage: "sun.max")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(awake.paused ? "Paused below 20% battery" : "Keep the display awake")
            Button {
                screen.toggle()
            } label: {
                barLabel("Screen", systemImage: "moon")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Hold Esc for 3 seconds")
            Button {
                DesktopCleaner.clean()
            } label: {
                barLabel("Backup", systemImage: "desktopcomputer")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Move Desktop items into Documents/datas")
        }
        .font(.system(size: 13))
        .controlSize(.regular)
    }

    private func barLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13))
            .labelStyle(.titleAndIcon)
    }
}

/// Vector paths avoid a separate Canvas renderer and its backing resources per chart.
private struct SparklinePath: Shape {
    var points: [HistoryPoint]
    var scale: Double
    var end: Double
    var stepped: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var previous: HistoryPoint?
        let height = max(rect.height - 13, 1)
        for point in points {
            guard let value = point.value, point.time >= end - 300 else { previous = nil; continue }
            let x = rect.minX + rect.width * (point.time - end + 300) / 300
            let y = rect.maxY - min(max(value / scale, 0), 1) * height - 1
            let position = CGPoint(x: x, y: y)
            if let previous, point.time - previous.time <= 10 {
                if stepped, let priorValue = previous.value {
                    let priorY = rect.maxY - min(max(priorValue / scale, 0), 1) * height - 1
                    path.addLine(to: CGPoint(x: x, y: priorY))
                }
                path.addLine(to: position)
            } else { path.move(to: position) }
            previous = point
        }
        return path
    }
}

private struct Sparkline: View {
    var values: [HistoryPoint]
    var secondary: [HistoryPoint] = []
    var ceiling: Double? = nil
    var unit = "%"
    var color: Color = accent
    @State private var hover: CGFloat?

    private var upper: Double { ceiling ?? max((values + secondary).compactMap(\.value).max() ?? 1, 1) }
    private var end: Double { max(values.last?.time ?? 0, secondary.last?.time ?? 0) }

    var body: some View {
        GeometryReader { proxy in
            let scale = upper
            let endTime = end
            ZStack {
                SparklinePath(points: values, scale: scale, end: endTime, stepped: unit == "pressure")
                    .stroke(color, style: StrokeStyle(lineWidth: 1.3))
                if !secondary.isEmpty {
                    SparklinePath(points: secondary, scale: scale, end: endTime, stepped: false)
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.3, dash: [3, 2]))
                }
            }
            .overlay(alignment: .top) {
                HStack {
                    Text("5 min")
                    Spacer()
                    Text(ceiling == nil ? RateFormat.bytesPerSecond(upper) : (unit == "pressure" ? "1 / 2 / 4" : "100%"))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .onContinuousHover { phase in
                switch phase { case .active(let location): hover = location.x; case .ended: hover = nil }
            }
            .help(hoverText(width: proxy.size.width))
        }
        .frame(height: 58)
        .accessibilityLabel("Last 5 minutes; \(unit)")
    }

    private func hoverText(width: CGFloat) -> String {
        guard let hover, width > 0 else { return "Last 5 minutes · gaps mean no data" }
        let time = end - 300 + Double(hover / width) * 300
        guard let point = values.min(by: { abs($0.time - time) < abs($1.time - time) }), abs(point.time - time) <= 5 else { return "No sample" }
        let date = Date().addingTimeInterval(point.time - SampleClock.now)
        let value = point.value.map { unit == "B/s" ? RateFormat.bytesPerSecond($0) : String(format: "%.1f %@", $0, unit) } ?? "Unavailable"
        let second = secondary.min(by: { abs($0.time - time) < abs($1.time - time) })
        let other = second.flatMap { abs($0.time - time) <= 5 ? $0.value : nil }.map { " · dashed \(RateFormat.bytesPerSecond($0))" } ?? ""
        return "\(date.formatted(date: .omitted, time: .standard)) · \(value)\(other)"
    }
}

private struct DetailsButton: View {
    var title: String
    var lines: [String]
    var cores: [Double] = []
    var history: [HistoryPoint] = []
    var secondary: [HistoryPoint] = []
    var ceiling: Double? = nil
    var unit = "%"
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "info.circle").font(.caption2) }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(8)
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    ForEach(lines, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    if !history.isEmpty {
                        Sparkline(values: history, secondary: secondary, ceiling: ceiling, unit: unit)
                        Text("Last 5 minutes").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !cores.isEmpty {
                        ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                            HStack { Text("Core \(index + 1)"); bar(fraction: value / 100); Text(percent(value)).monospacedDigit() }.font(.caption)
                        }
                    }
                }.padding(16).frame(width: 320)
            }
    }
}

private func healthLabel(_ health: SampleHealth) -> some View {
    Text(health.label(at: SampleClock.now))
        .font(.system(size: 11))
        .foregroundStyle(health.isFresh(at: SampleClock.now) ? Color.secondary : Color.orange)
        .help("Source: \(health.source). Last successful sample: \(health.lastSuccess.map { "\(Int(max(0, SampleClock.now - $0)))s ago" } ?? "none")")
}

private func pressureColor(_ value: String) -> Color {
    switch value { case "Normal": accent; case "High": .orange; case "Critical": .red; default: .secondary }
}

private func rate(_ value: Double?) -> String { value.map(RateFormat.bytesPerSecond) ?? "—" }

private let accent = Color(red: 0.55, green: 0.86, blue: 0.45)
private let panelBackground = Color(red: 0.09, green: 0.085, blue: 0.07)

private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        content()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
}

private func metricCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        content()
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
}

private func chartSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .center)
}

private func footnote(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)

        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
}

private func title(_ name: String, value: String, extra: String?) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let extra {
                Text(extra)
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        Text(value)
            .font(.system(size: 24, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .topLeading)
}

private func chip(_ text: String) -> some View {
    Text(text)
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: Capsule())
}

private func bar(fraction: Double) -> some View {
    GeometryReader { proxy in
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.08))
            Capsule().fill(accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
        }
    }
    .frame(height: 6)
}

private func coreBars(_ cores: [Double]) -> some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: min(max(cores.count, 1), 9))
    return LazyVGrid(columns: columns, spacing: 2) {
        ForEach(Array(cores.enumerated()), id: \.offset) { _, value in
            Capsule()
                .fill(accent.opacity(0.25 + 0.75 * min(value, 100) / 100))
                .frame(height: 8)
        }
    }
}

private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }

private func degrees(_ value: Double?) -> String? {
    value.map { String(format: "%.0f°", $0) }
}

private func memory(_ bytes: Int64) -> String {
    String(format: "%.1f GiB", Double(bytes) / 1024 / 1024 / 1024)
}

private func decimal(_ bytes: Int64) -> String {
    let value = Double(max(bytes, 0))
    if value >= 1_000_000_000_000 { return String(format: "%.1f TB", value / 1_000_000_000_000) }
    if value >= 1_000_000_000 { return String(format: "%.0f GB", value / 1_000_000_000) }
    return String(format: "%.0f MB", value / 1_000_000)
}

private func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
