import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var helper: HelperClient
    @ObservedObject var charge: ChargeLimitController
    @ObservedObject var fan: FanController

    var body: some View {
        Form {
            Section("Menu bar") {
                metricPicker("First", selection: $settings.slot1)
                metricPicker("Second", selection: $settings.slot2)
                metricPicker("Third", selection: $settings.slot3)
            }
            Section("Fan") {
                Stepper("Cool starts at \(settings.coolFloor)%", value: $settings.coolFloor, in: 20...80, step: 5)
                Toggle("Return to Auto when the Mac is cool", isOn: $settings.autoReturnWhenCool)
            }
            Section("Battery") {
                Toggle(charge.usesSystemLimit ? "Limit \(charge.systemLimitPercent ?? 80)%" : "Limit charge to 80%", isOn: Binding(
                    get: { charge.usesSystemLimit || settings.chargeLimit },
                    set: { newValue in
                        guard !charge.usesSystemLimit else { return }
                        settings.chargeLimit = newValue
                        charge.setEnabled(newValue)
                    }
                ))
                .disabled(charge.usesSystemLimit)
                if charge.usesSystemLimit {
                    Text("macOS is limiting charge to \(charge.systemLimitPercent ?? 80)%. Change it in System Settings → Battery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Awake") {
                Toggle("Stay awake with the lid closed", isOn: $settings.allowClosedLid)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: launchBinding)
            }
            Section("Helper") {
                Text(helperText)
                if case .needsApproval = helper.status {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                } else if helper.status != .enabled {
                    Button("Install helper") { helper.install() }
                }
                Text("Installing asks for your password. The helper then shows up in Login Items → Allow in the Background. Fan, charge limit, and Low Lag changes last only while Monitoring is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { helper.refreshStatus() }
        .onChange(of: settings.coolFloor) { _, _ in fan.resend() }
        .onChange(of: settings.autoReturnWhenCool) { _, _ in fan.resend() }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                if enabled { try? SMAppService.mainApp.register() }
                else { try? SMAppService.mainApp.unregister() }
            }
        )
    }

    private var helperText: String {
        switch helper.status {
        case .enabled: "Helper is installed"
        case .needsApproval: "Allow Monitoring in Login Items → Allow in the Background"
        case .notRegistered: "Helper is not installed"
        case .unavailable(let reason): reason
        }
    }

    private func metricPicker(_ title: String, selection: Binding<MenuMetric>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MenuMetric.allCases) { metric in
                Text(metric.title).tag(metric)
            }
        }
    }
}
