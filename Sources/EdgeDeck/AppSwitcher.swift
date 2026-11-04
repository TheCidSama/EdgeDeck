import AppKit

/// The switcher shown while sliding along the top edge: a bar of open apps in the middle of the screen,
/// like Cmd-Tab, whose highlight follows the finger. Lifting the finger switches to the highlighted app.
/// Its window only exists while it's showing. Main thread only.
enum AppSwitcher {
    private static var panel: NSPanel?
    private static var bar: SwitcherBar?
    private static var apps: [NSRunningApplication] = []
    private static var index = 0
    private static var current: Int?   // the app that was in front when the slide began

    static func begin() {
        apps = orderedApps()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        current = apps.firstIndex { $0.processIdentifier == front }
        index = current ?? 0
        guard apps.count > 1 else { apps = []; return }
        show()
    }

    static func move(by steps: Int) {
        guard !apps.isEmpty else { return }
        let target = min(apps.count - 1, max(0, index + steps))
        // At either end nothing moves and there is no tick, so you can feel the limit.
        guard target != index else { return }
        index = target
        Haptics.tick()
        bar?.selected = index
    }

    static func commit() {
        guard !apps.isEmpty else { return }
        let app = apps[index], switches = index != current
        hide()
        guard switches else { return }
        Haptics.thump()
        if let url = app.bundleURL {
            // Opening it like a Dock click also brings back hidden or minimized windows.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app.activate(options: [])
        }
    }

    static func cancel() { hide() }

    /// Front to back: the frontmost app, then apps by their frontmost window on screen, then the rest.
    /// Window owners are readable without Screen Recording access (only titles aren't).
    private static func orderedApps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [pid_t] = []
        var seen = Set<pid_t>()
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, byPID[front] != nil {
            order.append(front)
            seen.insert(front)
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where w[kCGWindowLayer as String] as? Int == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, byPID[pid] != nil, seen.insert(pid).inserted { order.append(pid) }
        }
        return order.compactMap { byPID[$0] } + running.filter { !seen.contains($0.processIdentifier) }
    }

    private static func show() {
        hide()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }

        let maxWidth = screen.visibleFrame.width - 80
        let cell = min(SwitcherBar.cell, (maxWidth - 2 * SwitcherBar.pad) / CGFloat(apps.count))
        let size = NSSize(width: cell * CGFloat(apps.count) + 2 * SwitcherBar.pad, height: cell + SwitcherBar.labelHeight + 2 * SwitcherBar.pad)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 24
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        let b = SwitcherBar(frame: blur.bounds, apps: apps, cell: cell)
        b.selected = index
        blur.addSubview(b)
        p.contentView = blur

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
        panel = p
        bar = b
    }

    private static func hide() {
        guard let p = panel else { return }
        panel = nil
        bar = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

/// The row of app icons, with the highlighted app's name underneath.
private final class SwitcherBar: NSView {
    static let cell: CGFloat = 104
    static let pad: CGFloat = 18
    static let labelHeight: CGFloat = 30

    var selected = 0 {
        didSet { if selected != oldValue { needsDisplay = true } }
    }

    private let apps: [NSRunningApplication]
    private let cell: CGFloat

    init(frame: NSRect, apps: [NSRunningApplication], cell: CGFloat) {
        self.apps = apps
        self.cell = cell
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor(red: 0.27, green: 0.56, blue: 1, alpha: 1)
        let rowY = Self.pad + Self.labelHeight
        for (i, app) in apps.enumerated() {
            let box = NSRect(x: Self.pad + CGFloat(i) * cell, y: rowY, width: cell, height: cell).insetBy(dx: 4, dy: 4)
            if i == selected {
                let path = NSBezierPath(roundedRect: box, xRadius: 18, yRadius: 18)
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = blue.withAlphaComponent(0.7)
                glow.shadowBlurRadius = 14
                glow.set()
                NSColor(white: 1, alpha: 0.14).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                blue.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            let inset = box.width * (i == selected ? 0.1 : 0.14)
            app.icon?.draw(in: box.insetBy(dx: inset, dy: inset))
        }

        let name = apps[selected].localizedName ?? ""
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor(white: 0.95, alpha: 1), .paragraphStyle: style,
        ])
        text.draw(in: NSRect(x: Self.pad, y: Self.pad, width: bounds.width - 2 * Self.pad, height: 22))
    }
}
