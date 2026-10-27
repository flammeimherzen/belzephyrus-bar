import AppKit
import Foundation

@MainActor
enum DesktopCleaner {
    private static var running = false
    private nonisolated static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    static func clean() {
        guard !running else { return }
        running = true
        Task.detached {
            let result = gather()
            await MainActor.run {
                running = false
                present(result)
            }
        }
    }

    private nonisolated static func gather(now: Date = Date()) -> MoveResult {
        let calendar = Calendar.current
        let month = months[calendar.component(.month, from: now) - 1]
        let folderName = "\(calendar.component(.day, from: now))\(month)"
        let fileManager = FileManager.default
        guard let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return MoveResult(moved: 0, folderName: folderName, failures: ["The Desktop folder is unavailable."])
        }
        let destination = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/datas/\(month)/\(folderName)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return MoveResult(moved: 0, folderName: folderName, failures: [error.localizedDescription])
        }

        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            return MoveResult(moved: 0, folderName: folderName, failures: [error.localizedDescription])
        }

        let destinationPath = destination.standardizedFileURL.path
        var moved = 0
        var failures: [String] = []
        for item in items where item.standardizedFileURL.path != destinationPath {
            let target = uniqueURL(named: item.lastPathComponent, in: destination, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: item, to: target)
                moved += 1
            } catch {
                failures.append("\(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return MoveResult(moved: moved, folderName: folderName, failures: failures)
    }

    private nonisolated static func uniqueURL(named name: String, in folder: URL, fileManager: FileManager) -> URL {
        let direct = folder.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: direct.path) { return direct }
        let file = name as NSString
        let base = file.deletingPathExtension
        let ext = file.pathExtension
        var index = 2
        while true {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(next)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func present(_ result: MoveResult) {
        guard result.moved == 0 || !result.failures.isEmpty else { return }
        let alert = NSAlert()
        if result.moved == 0, result.failures.isEmpty {
            alert.messageText = "Desktop is empty"
            alert.informativeText = "Nothing to move."
        } else if result.moved == 0 {
            alert.messageText = "Could not clean the Desktop"
            alert.informativeText = result.failures.prefix(8).joined(separator: "\n")
        } else {
            alert.messageText = "Moved \(result.moved) items into \(result.folderName)"
            alert.informativeText = result.failures.prefix(8).joined(separator: "\n")
        }
        alert.addButton(withTitle: "OK")
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private struct MoveResult: Sendable {
    var moved: Int
    var folderName: String
    var failures: [String]
}
