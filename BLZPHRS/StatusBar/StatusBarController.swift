import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 380, height: 720),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let menuFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private var symbolImages: [String: NSImage] = [:]
    private var monitor: Any?
    private var open = false
    var onOpenChanged: ((Bool) -> Void)?
    var onQuit: (() -> Void)?
    var makeRoot: (() -> AnyView)?

    override init() {
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render(MenuBarSnapshot(items: [("memorychip", "…")], help: "Monitoring"))
    }

    func render(_ snapshot: MenuBarSnapshot) {
        guard let button = item.button else { return }
        let result = NSMutableAttributedString()
        let font = menuFont
        let widths: [CGFloat] = snapshot.items.map { $0.symbol == "network" ? 140 : 78 }
        let paragraph = NSMutableParagraphStyle()
        var offset: CGFloat = 0
        paragraph.tabStops = widths.dropLast().map { width in
            offset += width
            return NSTextTab(textAlignment: .left, location: offset)
        }
        for (index, item) in snapshot.items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\t", attributes: [.font: font])) }
            if symbolImages[item.symbol] == nil {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                symbolImages[item.symbol] = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            }
            if let image = symbolImages[item.symbol] {
                let attachment = NSTextAttachment()
                attachment.image = image
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            result.append(NSAttributedString(string: item.text, attributes: [.font: font]))
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        let length = widths.reduce(0, +) + 12
        if item.length != length { item.length = length }
        button.attributedTitle = result
        button.toolTip = snapshot.help
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showMenu() } else { toggle() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Monitoring", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    @objc private func openSettings() {
        close()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        onQuit?()
    }

    private func toggle() {
        if open { close() } else { present() }
    }

    var panelIsVisible: Bool { panel.isVisible && panel.occlusionState.contains(.visible) }

    func showForProfiling() { if !open { present(dismissOnOutsideClick: false) } }

    private func present(dismissOnOutsideClick: Bool = true) {
        guard let root = makeRoot?() else { return }
        let anchor = statusAnchor()
        let screen = anchor.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let top = visible.maxY - 8
        let width = min(CGFloat(740), visible.width - 16)
        let height = min(580, max(1, top - visible.minY - 8))
        // Bound the SwiftUI scroll viewport to the actual panel, not a larger
        // provisional hosting size that can hide the bottom of the viewport.
        let host = NSHostingView(rootView: root.preferredColorScheme(.dark)
            .frame(width: width, height: height))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = host
        panel.setContentSize(NSSize(width: width, height: height))
        let x: CGFloat
        let y: CGFloat
        if let anchor {
            x = min(max(anchor.x - width / 2, visible.minX + 8), visible.maxX - width - 8)
            y = top - height
        } else {
            x = visible.maxX - width - 8
            y = visible.maxY - height - 8
        }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        open = true
        onOpenChanged?(true)
        guard dismissOnOutsideClick else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.open, self.monitor == nil else { return }
            self.monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
    }

    private func statusAnchor() -> NSPoint? {
        guard let button = item.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard rect.width > 1, rect.height > 1 else { return nil }
        return NSPoint(x: rect.midX, y: rect.minY)
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard open else { return }
        open = false
        onOpenChanged?(false)
    }
}
