import AppKit
import Foundation

@MainActor
final class AppTerminationService {
    func quit(pid: pid_t) throws {
        try terminate(pid: pid, force: false)
    }

    func forceQuit(pid: pid_t) throws {
        try terminate(pid: pid, force: true)
    }

    private func terminate(pid: pid_t, force: Bool) throws {
        guard pid != getpid() else {
            throw AppTerminationError.currentApp
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw AppTerminationError.notFound
        }

        let didRequestQuit = force ? app.forceTerminate() : app.terminate()
        guard didRequestQuit else {
            throw AppTerminationError.denied
        }
    }
}

enum AppTerminationError: LocalizedError {
    case currentApp
    case notFound
    case denied

    var errorDescription: String? {
        switch self {
        case .currentApp:
            "BLZPHRS cannot quit itself from the process list"
        case .notFound:
            "The app is no longer running"
        case .denied:
            "macOS did not allow this app to be quit"
        }
    }
}
