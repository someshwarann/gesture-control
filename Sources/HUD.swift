import AppKit

/// Small floating pill in the top-right corner that shows what the app sees.
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        label.frame = NSRect(x: 10, y: 10, width: 240, height: 20)
        bg.addSubview(label)
        panel.contentView = bg
    }

    func show(_ text: String) {
        label.stringValue = text
        if let s = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: s.maxX - 276, y: s.maxY - 52))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
