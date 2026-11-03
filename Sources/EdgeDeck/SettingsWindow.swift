import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// Colors of the dark settings window.
private enum Theme {
    static let background = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
    static let blue = NSColor(red: 0.27, green: 0.56, blue: 1, alpha: 1)
    static let text = NSColor(white: 0.92, alpha: 1)
    static let dim = NSColor(white: 0.55, alpha: 1)
}

/// The settings window. Created on demand and thrown away when closed.
final class SettingsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?

    private let pad = PadView()
    private let widthLabel = NSTextField(labelWithString: "")
    private let accessRow = NSStackView()
    private var slotsObserver: NSObjectProtocol?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "EdgeDeck"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        refresh()
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        Engine.shared.preview = { [weak self] points in self?.pad.fingers = points }
        slotsObserver = NotificationCenter.default.addObserver(forName: .slotsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.pad.needsDisplay = true
        }
    }

    func windowWillClose(_ notification: Notification) {
        Engine.shared.preview = nil
        if let slotsObserver { NotificationCenter.default.removeObserver(slotsObserver) }
        onClose?()
    }

    func refresh() {
        accessRow.isHidden = AXIsProcessTrusted()
        widthLabel.stringValue = "\(Int((Settings.shared.edgeWidth * 100).rounded()))%"
        pad.needsDisplay = true
    }

    private func build() {
        let s = Settings.shared

        let title = NSTextField(labelWithString: "EdgeDeck")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = Theme.text
        let subtitle = NSTextField(labelWithString: "Your trackpad's edges, as a deck.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Theme.dim
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 512).isActive = true

        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 512 + 2 * PadView.glowRoom).isActive = true
        pad.heightAnchor.constraint(equalToConstant: 320 + 2 * PadView.glowRoom).isActive = true
        pad.onPick = { [weak self] side, slot, point in self?.showPicker(side, slot, at: point) }
        pad.onClear = { side, slot in Settings.shared.setItem(nil, side, slot) }

        let hint = NSTextField(wrappingLabelWithString:
            "Click a slot to put an app, an open window, Wi-Fi or Bluetooth in it; right-click to clear it. "
            + "On the trackpad, double-tap a slot to use it.\n"
            + "Slide up or down on the left edge for brightness, on the right edge for volume.")
        hint.textColor = Theme.dim
        hint.font = .systemFont(ofSize: 12)
        hint.preferredMaxLayoutWidth = 512

        let slider = NSSlider(
            value: s.edgeWidth, minValue: Settings.widthRange.lowerBound, maxValue: Settings.widthRange.upperBound,
            target: self, action: #selector(widthChanged))
        slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        widthLabel.textColor = Theme.blue

        let slots = NSSegmentedControl(labels: ["3 slots", "4 slots"], trackingMode: .selectOne, target: self, action: #selector(slotsChanged))
        slots.selectedSegment = s.slotsPerSide == 4 ? 1 : 0

        let haptics = NSButton(checkboxWithTitle: "Haptic feedback", target: self, action: #selector(hapticsChanged))
        haptics.state = s.haptics ? .on : .off
        let gestures = NSButton(checkboxWithTitle: "Slide on edges for brightness and volume", target: self, action: #selector(gesturesChanged))
        gestures.state = s.gestures ? .on : .off
        let login = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(loginChanged))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let grid = NSGridView(views: [
            [label("Edge width:"), NSStackView(views: [slider, widthLabel])],
            [label("Each edge:"), slots],
            [NSGridCell.emptyContentView, haptics],
            [NSGridCell.emptyContentView, gestures],
            [NSGridCell.emptyContentView, login],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        let card = Card(content: grid)

        let warning = NSTextField(labelWithString: "Window slots and click blocking need Accessibility access.")
        warning.textColor = .systemOrange
        let grant = NSButton(title: "Open Settings…", target: self, action: #selector(openAccessibility))
        accessRow.setViews([warning, grant], in: .leading)

        let stack = NSStackView(views: [header, pad, hint, card, accessRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(4, after: header)
        stack.setCustomSpacing(4, after: pad)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24 - PadView.glowRoom, bottom: 22, right: 24 - PadView.glowRoom)
        window.contentView = stack
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = Theme.dim
        return field
    }

    // MARK: Slot picker

    private func showPicker(_ side: Side, _ slot: Int, at point: NSPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ image: NSImage?, _ action: (() -> Void)?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.image = image.map(menuIcon)
            item.isEnabled = action != nil
            menu.addItem(item)
            return item
        }
        let set = { (item: SlotItem?) in Settings.shared.setItem(item, side, slot) }

        add("Application…", Glyphs.symbol("square.grid.2x2")) { [weak self] in self?.pickApp(side, slot) }
        add("Wi-Fi On/Off", Radio.wifi.icon()) { set(.wifi) }
        add("Bluetooth On/Off", Radio.bluetooth.icon()) { set(.bluetooth) }
        menu.addItem(.separator())
        add("Open Windows", nil, nil)

        if !AXIsProcessTrusted() {
            add("Allow Accessibility access to list windows", nil, nil)
        } else {
            let windows = Windows.list()
            if windows.isEmpty { add("No open windows", nil, nil) }
            for w in windows {
                let appName = w.app.localizedName ?? "App"
                let title = w.title.isEmpty ? appName : w.title
                let label = w.title.isEmpty ? appName : "\(appName) — \(w.title)"
                let item = add(label.count > 70 ? String(label.prefix(69)) + "…" : label, w.app.icon) {
                    set(.window(pid: w.pid, windowID: w.id, appPath: w.app.bundleURL?.path ?? "", title: title))
                }
                item.indentationLevel = 1
            }
        }

        if Settings.shared.item(side, slot) != nil {
            menu.addItem(.separator())
            add("Remove", nil) { set(nil) }
        }
        menu.popUp(positioning: nil, at: point, in: pad)
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    private func menuIcon(_ image: NSImage) -> NSImage {
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            image.draw(in: Glyphs.fitted(image.size, in: r))
            return true
        }
        icon.isTemplate = image.isTemplate
        return icon
    }

    private func pickApp(_ side: Side, _ slot: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.setItem(.app(path: url.path), side, slot)
        }
    }

    // MARK: Controls

    @objc private func widthChanged(_ sender: NSSlider) {
        Settings.shared.edgeWidth = sender.doubleValue
        Engine.shared.reload()
        refresh()
    }

    @objc private func slotsChanged(_ sender: NSSegmentedControl) {
        Settings.shared.slotsPerSide = sender.selectedSegment == 1 ? 4 : 3
        Engine.shared.reload()
        pad.needsDisplay = true
    }

    @objc private func hapticsChanged(_ sender: NSButton) {
        Settings.shared.haptics = sender.state == .on
        if sender.state == .on { Haptics.thump() }
    }

    @objc private func gesturesChanged(_ sender: NSButton) {
        Settings.shared.gestures = sender.state == .on
        Engine.shared.reload()
    }

    @objc private func loginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc private func openAccessibility() { onOpenAccessibility?() }
}

/// A rounded dark panel around some content.
private final class Card: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 512),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// Drawing of the trackpad with its glowing edge slots and live finger positions.
final class PadView: NSView {
    /// Space around the pad for the edge glow.
    static let glowRoom: CGFloat = 16

    var fingers: [CGPoint] = [] {
        didSet { if fingers != oldValue { needsDisplay = true } }
    }
    var onPick: ((Side, Int, NSPoint) -> Void)?
    var onClear: ((Side, Int) -> Void)?

    private var icons: [String: NSImage] = [:]
    private var padRect: NSRect { bounds.insetBy(dx: Self.glowRoom, dy: Self.glowRoom) }

    override var mouseDownCanMoveWindow: Bool { false }

    private func stripRect(_ side: Side) -> NSRect {
        let r = padRect
        let w = (r.width * CGFloat(Settings.shared.edgeWidth)).rounded()
        return NSRect(x: side == .left ? r.minX : r.maxX - w, y: r.minY, width: w, height: r.height)
    }

    private func slotRect(_ side: Side, _ slot: Int) -> NSRect {
        let s = Settings.shared, r = padRect
        let w = (r.width * CGFloat(s.edgeWidth)).rounded()
        let h = r.height / CGFloat(s.slotsPerSide)
        let x = side == .left ? r.minX : r.maxX - w
        return NSRect(x: x, y: r.maxY - h * CGFloat(slot + 1), width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = padRect
        let radius: CGFloat = 16
        let body = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        // Halo: blurred blue strips behind the pad, so the glow spills out of its sides.
        for side in Side.allCases {
            withShadow(Theme.blue.withAlphaComponent(0.9), blur: 26) {
                Theme.blue.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: stripRect(side).insetBy(dx: 2, dy: 6), xRadius: radius, yRadius: radius).fill()
            }
        }

        NSGradient(starting: NSColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1),
                   ending: NSColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1))?.draw(in: body, angle: -90)

        NSGraphicsContext.saveGraphicsState()
        body.addClip()

        for side in Side.allCases {
            // Blue halo, brightest at the outer edge, fading out past the strip into the normal trackpad.
            let strip = stripRect(side)
            let fade: CGFloat = 70
            let halo = NSRect(x: side == .left ? strip.minX : strip.minX - fade, y: strip.minY,
                              width: strip.width + fade, height: strip.height)
            let stripEnd = strip.width / halo.width
            let wash = NSGradient(
                colors: [0.32, 0.12, 0.04, 0].map { Theme.blue.withAlphaComponent($0) },
                atLocations: [0, stripEnd, stripEnd + (1 - stripEnd) * 0.45, 1],
                colorSpace: .sRGB)
            wash?.draw(in: halo, angle: side == .left ? 0 : 180)
            for slot in 0..<Settings.shared.slotsPerSide { drawSlot(side, slot) }
        }

        let middle = NSAttributedString(string: "NORMAL TRACKPAD", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .kern: 2,
            .foregroundColor: NSColor(white: 1, alpha: 0.18),
        ])
        let size = middle.size()
        middle.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))

        for p in fingers {
            let c = NSPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
            withShadow(Theme.blue, blur: 16) {
                NSColor(red: 0.6, green: 0.78, blue: 1, alpha: 0.9).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 1, alpha: 0.10).setStroke()
        body.lineWidth = 1
        body.stroke()
    }

    private func withShadow(_ color: NSColor, blur: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = .zero
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSlot(_ side: Side, _ slot: Int) {
        let rect = slotRect(side, slot).insetBy(dx: 5, dy: 4)
        let card = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let item = Settings.shared.item(side, slot)
        NSColor(white: 0, alpha: item == nil ? 0.25 : 0.4).setFill()
        card.fill()

        guard let item else {
            draw("+", in: rect, size: 20, color: Theme.blue.withAlphaComponent(0.85))
            return
        }
        let iconSize = min(rect.width - 10, rect.height - 26, 44)
        let iconRect = NSRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2 + 7, width: iconSize, height: iconSize)
        let name: String
        switch item {
        case .app(let path):
            appIcon(path).draw(in: iconRect)
            name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        case .window(_, _, let appPath, let title):
            appIcon(appPath).draw(in: iconRect)
            drawWindowBadge(on: iconRect)
            name = title
        case .wifi:
            Glyphs.draw(Radio.wifi.icon(), in: iconRect.insetBy(dx: iconSize * 0.15, dy: iconSize * 0.15), color: Theme.text)
            name = Radio.wifi.name
        case .bluetooth:
            Glyphs.draw(Radio.bluetooth.icon(), in: iconRect.insetBy(dx: iconSize * 0.15, dy: iconSize * 0.15), color: Theme.text)
            name = Radio.bluetooth.name
        }
        let nameRect = NSRect(x: rect.minX + 3, y: iconRect.minY - 18, width: rect.width - 6, height: 15)
        draw(name, in: nameRect, size: 10, color: Theme.text)
    }

    private func appIcon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// Small window glyph on the icon, so a window slot reads differently from an app slot.
    private func drawWindowBadge(on iconRect: NSRect) {
        let badge = NSRect(x: iconRect.maxX - 14, y: iconRect.minY - 2, width: 16, height: 16)
        Theme.blue.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        Glyphs.draw(Glyphs.symbol("macwindow"), in: badge.insetBy(dx: 3, dy: 3), color: .white)
    }

    private func draw(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style,
        ])
        let h = string.size().height
        string.draw(with: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func hit(_ event: NSEvent) -> (Side, Int)? {
        let p = convert(event.locationInWindow, from: nil)
        for side in Side.allCases {
            for slot in 0..<Settings.shared.slotsPerSide where slotRect(side, slot).contains(p) { return (side, slot) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if let (side, slot) = hit(event) { onPick?(side, slot, convert(event.locationInWindow, from: nil)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (side, slot) = hit(event), Settings.shared.item(side, slot) != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove", action: #selector(removeItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [side.rawValue, slot]
        menu.addItem(item)
        return menu
    }

    @objc private func removeItem(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [Int], let side = Side(rawValue: v[0]) else { return }
        onClear?(side, v[1])
    }
}
