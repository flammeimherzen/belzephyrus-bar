import AppKit
import Combine
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    let settings: SettingsStore = {
        guard PerformanceProbe.requested else { return SettingsStore() }
        // Volatile preference domain: preserve selected metrics without changing user defaults.
        let defaults = UserDefaults(suiteName: "Monitoring.PerformanceProbe")!
        var values: [String: Any] = [:]
        for key in ["slot1", "slot2", "slot3", "coolFloor"] { values[key] = UserDefaults.standard.object(forKey: key) }
        values["chargeLimit"] = false
        values["allowClosedLid"] = false
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        return SettingsStore(defaults: defaults)
    }()
    let helper = HelperClient()
    let engine = MetricsEngine()
    lazy var fan = FanController(helper: helper, settings: settings)
    lazy var charge = ChargeLimitController(helper: helper, settings: settings)
    lazy var lowLag = LowLagController(helper: helper)
    lazy var awake = KeepAwakeController(helper: helper, settings: settings)
    lazy var screen = CleanScreenController()
    let brightness = BrightnessController()
    let privacy = PrivacyMonitor()
    private var status: StatusBarController?
    private var performanceProbe: PerformanceProbe?
    private var moleRunning = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted calculation tests must not initialize hardware controllers.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        helper.refreshStatus()
        engine.onBattery = { [weak self] reading in
            self?.charge.note(reading)
            self?.awake.note(percent: reading.percent, onAC: reading.onAC)
        }
        let status = StatusBarController()
        status.makeRoot = { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            self.brightness.prepareForDisplay()
            return AnyView(self.dashboard)
        }
        status.onOpenChanged = { [weak self] open in
            guard let self else { return }
            if open {
                self.moleRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tw93.MoleApp").isEmpty
                self.privacy.start()
            } else {
                self.privacy.stop()
            }
            self.engine.setPanelOpen(open)
        }
        status.onQuit = { [weak self] in self?.requestQuit() }
        engine.menuChanged = { [weak status] snapshot in status?.render(snapshot) }
        engine.start(settings: settings)
        self.status = status
        if settings.chargeLimit { charge.setEnabled(true) }
        if PerformanceProbe.requested {
            let probe = PerformanceProbe(status: status, settings: settings)
            performanceProbe = probe
            probe.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if PerformanceProbe.requested {
            engine.stop()
            privacy.stop()
            return .terminateNow
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .terminateNow }
        guard !quitting else { return .terminateNow }
        quitting = true
        awake.stop()
        screen.stop()
        lowLag.stop()
        fan.prepareToQuit { [weak self] confirmed in
            Task { @MainActor in
                if confirmed {
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else {
                    self?.confirmUnrestoredFans()
                }
            }
        }
        return .terminateLater
    }

    private var dashboard: some View {
        DashboardView(
            header: engine.header,
            cpu: engine.cpu,
            gpu: engine.gpu,
            memory: engine.memory,
            disk: engine.disk,
            network: engine.network,
            fan: engine.fan,
            battery: engine.battery,
            processes: engine.processes,
            fanControl: fan,
            helper: helper,
            charge: charge,
            lowLag: lowLag,
            awake: awake,
            screen: screen,
            privacy: privacy,
            brightness: brightness,
            moleRunning: moleRunning
        )
        .allowsHitTesting(!PerformanceProbe.requested)
    }

    private func requestQuit() {
        NSApp.terminate(nil)
    }

    private func confirmUnrestoredFans() {
        let alert = NSAlert()
        alert.messageText = "Fan Restore Unconfirmed"
        alert.informativeText = "The fans may still be under manual control."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            quitting = false
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }
}

@main
struct BLZPHRSApp: App {
    @NSApplicationDelegateAdaptor(AppCoordinator.self) private var coordinator

    var body: some Scene {
        Settings {
            SettingsView(settings: coordinator.settings, helper: coordinator.helper, charge: coordinator.charge, fan: coordinator.fan)
        }
    }
}
