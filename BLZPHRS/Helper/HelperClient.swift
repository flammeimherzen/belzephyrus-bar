import AppKit
import Combine
import Foundation
import MonitoringKit
import ServiceManagement

enum HelperStatus: Equatable {
    case enabled
    case needsApproval
    case notRegistered
    case unavailable(String)
}

@MainActor
final class HelperClient: ObservableObject {
    @Published private(set) var status: HelperStatus = .notRegistered
    private var connection: NSXPCConnection?
    private let legacyPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.belzephyrus.blzphrs.helper.plist")

    func refreshStatus() {
        switch SMAppService.statusForLegacyPlist(at: legacyPlist) {
        case .enabled: status = .enabled
        case .requiresApproval: status = .needsApproval
        case .notRegistered, .notFound: status = .notRegistered
        @unknown default: status = .unavailable("Unknown helper status")
        }
    }

    /// Installs the root helper. macOS shows a password dialog.
    /// SMJobBless cannot install this development-signed daemon (launchd error 8: job plist not found), so the helper is copied into /Library with administrator privileges.
    func install() {
        NSApp.activate(ignoringOtherApps: true)
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/com.belzephyrus.blzphrs.helper")
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            status = .unavailable("Helper was not found in the app")
            return
        }
        let scriptURL = URL(fileURLWithPath: "/tmp/monitoring-helper-install.sh")
        let plistURL = URL(fileURLWithPath: "/tmp/monitoring-helper.plist")
        do {
            try installScript(source: source.path).write(to: scriptURL, atomically: true, encoding: .utf8)
            try helperPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            status = .unavailable("Could not prepare the installer")
            return
        }
        let apple = """
        do shell script "/bin/sh /tmp/monitoring-helper-install.sh" with administrator privileges with prompt "Monitoring needs its helper to control fans and the charge limit."
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", apple]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            status = .unavailable("Could not ask for administrator approval")
            return
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try? output.write(to: URL(fileURLWithPath: "/tmp/monitoring-helper-install.log"), atomically: true, encoding: .utf8)
        guard task.terminationStatus == 0 else {
            if output.contains("-128") || output.localizedCaseInsensitiveContains("canceled") {
                status = .unavailable("Password was canceled")
            } else {
                let line = output.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                status = .unavailable(line.isEmpty ? "Could not install the helper" : line)
            }
            return
        }
        connection = nil
        if pingHelper() {
            status = .enabled
        } else {
            refreshStatus()
            if case .needsApproval = status {
                SMAppService.openSystemSettingsLoginItems()
            } else if status != .enabled {
                status = .unavailable("Helper installed, but it did not start")
            }
        }
    }

    private var helperPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.belzephyrus.blzphrs.helper</string>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>com.belzephyrus.blzphrs</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>com.belzephyrus.blzphrs.helper</key>
                <true/>
            </dict>
            <key>Program</key>
            <string>/Library/PrivilegedHelperTools/com.belzephyrus.blzphrs.helper</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func installScript(source: String) -> String {
        let quoted = "'" + source.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return [
            "#!/bin/sh",
            "set -eu",
            "SRC=\(quoted)",
            "DEST=/Library/PrivilegedHelperTools/com.belzephyrus.blzphrs.helper",
            "PLIST=/Library/LaunchDaemons/com.belzephyrus.blzphrs.helper.plist",
            "mkdir -p /Library/PrivilegedHelperTools",
            "ditto \"$SRC\" \"$DEST\"",
            "chown root:wheel \"$DEST\"",
            "chmod 544 \"$DEST\"",
            "xattr -d com.apple.quarantine \"$DEST\" 2>/dev/null || true",
            "cp /tmp/monitoring-helper.plist \"$PLIST\"",
            "chown root:wheel \"$PLIST\"",
            "chmod 644 \"$PLIST\"",
            "launchctl bootout system/com.belzephyrus.blzphrs.helper 2>/dev/null || true",
            "launchctl enable system/com.belzephyrus.blzphrs.helper 2>/dev/null || true",
            "launchctl bootstrap system \"$PLIST\"",
            "launchctl kickstart -k system/com.belzephyrus.blzphrs.helper"
        ].joined(separator: "\n") + "\n"
    }

    private func pingHelper() -> Bool {
        let connection = NSXPCConnection(machServiceName: "com.belzephyrus.blzphrs.helper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MonitoringHelperXPC.self)
        let done = DispatchSemaphore(value: 0)
        let flag = PingFlag()
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            done.signal()
        } as? MonitoringHelperXPC
        proxy?.version { @Sendable _ in
            flag.ok = true
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        connection.invalidate()
        return flag.ok
    }

    /// Returns false when the helper cannot be used. The completion then already received the reason.
    private func prepare(_ completion: @escaping @Sendable (String?) -> Void) -> Bool {
        refreshStatus()
        if status != .enabled {
            if case .needsApproval = status {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                install()
                refreshStatus()
            }
        }
        switch status {
        case .enabled:
            return true
        case .needsApproval:
            completion("Allow Monitoring in Login Items → Allow in the Background, then try again.")
            return false
        case .notRegistered:
            completion("The helper is not installed yet.")
            return false
        case .unavailable(let reason):
            completion(reason)
            return false
        }
    }

    func withProxy(_ body: @escaping (MonitoringHelperXPC) -> Void) {
        guard let proxy = proxy() else { return }
        body(proxy)
    }

    func setFan(mode: FanMode, floor: Int, autoReturn: Bool, completion: @escaping @Sendable (String?) -> Void) {
        guard prepare(completion) else { return }
        withProxy { proxy in
            proxy.setFanMode(mode.rawValue, floorPercent: floor, autoReturnWhenCool: autoReturn) { @Sendable error in
                completion(error)
            }
        }
    }

    func setCharging(_ enabled: Bool, completion: @escaping @Sendable (String?) -> Void) {
        guard prepare(completion) else { return }
        withProxy { proxy in
            proxy.setChargingEnabled(enabled) { @Sendable error in
                completion(error)
            }
        }
    }

    func setChargeLimit(_ percent: Int, completion: @escaping @Sendable (String?) -> Void) {
        guard prepare(completion) else { return }
        withProxy { proxy in
            proxy.setChargeLimitPercent(percent) { @Sendable error in
                completion(error)
            }
        }
    }

    func setLowLag(_ enabled: Bool, completion: @escaping @Sendable (Bool, String?) -> Void) {
        guard prepare({ completion(false, $0) }) else { return }
        withProxy { proxy in
            proxy.setLowLagEnabled(enabled) { @Sendable active, error in
                completion(active, error)
            }
        }
    }

    func setClamshell(_ disabled: Bool) {
        guard prepare({ _ in }) else { return }
        withProxy { proxy in
            proxy.setClamshellSleepDisabled(disabled) { @Sendable _ in }
        }
    }

    func restoreAll(completion: @escaping @Sendable (Bool) -> Void) {
        guard let proxy = proxy() else {
            completion(true)
            return
        }
        proxy.restoreAll { @Sendable fansAuto, _ in
            completion(fansAuto)
        }
    }

    private func proxy() -> MonitoringHelperXPC? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: "com.belzephyrus.blzphrs.helper", options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MonitoringHelperXPC.self)
            connection.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            connection.resume()
            self.connection = connection
            let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            let versionProxy = connection.remoteObjectProxyWithErrorHandler(Self.logXPCError) as? MonitoringHelperXPC
            versionProxy?.version { @Sendable version in
                guard version != expected else { return }
                versionProxy?.relaunchIfVersionMismatches(expected) { @Sendable _ in }
            }
        }
        return connection?.remoteObjectProxyWithErrorHandler(Self.logXPCError) as? MonitoringHelperXPC
    }

    private nonisolated static func logXPCError(_ error: Error) {
        NSLog("Monitoring helper: \(error.localizedDescription)")
    }
}

private final class PingFlag: @unchecked Sendable {
    var ok = false
}
