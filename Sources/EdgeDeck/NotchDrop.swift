import AppKit
import QuartzCore

enum Radio {
    case wifi, bluetooth

    var name: String { self == .wifi ? "Wi-Fi" : "Bluetooth" }

    func icon(on: Bool = true) -> NSImage {
        self == .wifi ? Glyphs.symbol(on ? "wifi" : "wifi.slash") : Glyphs.bluetooth()
    }
}

/// Status shown by stretching the notch sideways: an icon slides out of its left end and the value
/// (On/Off, or a volume/brightness bar) out of its right end, then both slide back in.
/// Same height as the notch. Its window only exists while it is on screen.
final class NotchDrop {
    private enum Content {
        case radio(Radio, on: Bool, failed: Bool)
        case level(Side, Float)

        var isLevel: Bool { if case .level = self { true } else { false } }
    }

    private static var current: NotchDrop?

    static func show(_ radio: Radio, on: Bool, failed: Bool = false) {
        present(.radio(radio, on: on, failed: failed))
    }

    /// Volume (right) or brightness (left), 0...1. Repeated calls while sliding update it in place.
    static func showLevel(_ side: Side, _ value: Float) {
        present(.level(side, value))
    }

    private static func present(_ content: Content) {
        if let current, !current.closing, current.isLevel == content.isLevel {
            current.update(content, first: false)
            return
        }
        current?.dismissNow() // the two layouts have different widths
        let drop = NotchDrop(isLevel: content.isLevel)
        current = drop
        drop.update(content, first: true)
    }

    private let isLevel: Bool
    private let panel: NSPanel
    private let shape = CALayer()
    private let leftWing = CALayer()
    private let rightWing = CALayer()
    private let icon = CALayer()      // filled with the state color, cut out by iconMask
    private let iconMask = CALayer()
    private let status = CATextLayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let closedSize: CGSize
    private let openSize: CGSize
    private let leftWidth: CGFloat
    private let rightWidth: CGFloat
    private let closedX: CGFloat
    private let openX: CGFloat // the shape's center moves when the wings differ in width
    private let scale: CGFloat
    private var symbol = ""
    private var hideTimer: Timer?
    private var closing = false

    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let offColor = NSColor(white: 0.55, alpha: 1)

    private init(isLevel: Bool) {
        self.isLevel = isLevel
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        scale = screen.backingScaleFactor
        // Without a notch the wings grow out of the middle of the menu bar.
        var notchWidth: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let height = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : max(menuBar, 24)

        let widest = ["On", "Off", "Error"].map { NSAttributedString(string: $0, attributes: [.font: Self.font]).size().width }.max()!
        // Levels: a snug wing for the icon, a wider one for the bar.
        leftWidth = isLevel ? max(height * 1.3, 40) : max(height * 1.6, widest + 26)
        rightWidth = isLevel ? max(height * 2.6, 88) : leftWidth
        closedSize = CGSize(width: notchWidth, height: height)
        openSize = CGSize(width: notchWidth + leftWidth + rightWidth, height: height)

        // room for overshoot and shadow
        let size = CGSize(width: notchWidth + 2 * max(leftWidth, rightWidth) + 60, height: height + 24)
        closedX = size.width / 2
        openX = closedX + (rightWidth - leftWidth) / 2
        panel = DropPanel(
            contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        panel.contentView = view
        let root = view.layer!

        shape.anchorPoint = CGPoint(x: 0.5, y: 1) // stretches out to both sides from the notch
        shape.position = CGPoint(x: closedX, y: size.height)
        shape.bounds = CGRect(origin: .zero, size: closedSize)
        shape.backgroundColor = NSColor.black.cgColor
        shape.cornerRadius = min(12, height / 2)
        shape.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // square top, flush with the screen edge
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowRadius = 8
        shape.shadowOffset = CGSize(width: 0, height: -2)
        shape.shadowOpacity = 0
        root.addSublayer(shape)

        let top = size.height - height
        leftWing.frame = CGRect(x: closedX - notchWidth / 2 - leftWidth, y: top, width: leftWidth, height: height)
        rightWing.frame = CGRect(x: closedX + notchWidth / 2, y: top, width: rightWidth, height: height)
        for w in [leftWing, rightWing] {
            w.opacity = 0
            root.addSublayer(w)
        }

        let iconSize = min(18, height * 0.55)
        icon.frame = CGRect(x: (leftWidth - iconSize) / 2 + 3, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        iconMask.frame = icon.bounds
        iconMask.contentsGravity = .resizeAspect
        icon.mask = iconMask
        leftWing.addSublayer(icon)

        if isLevel {
            let barHeight: CGFloat = 6
            track.frame = CGRect(x: 8, y: (height - barHeight) / 2, width: rightWidth - 26, height: barHeight)
            track.cornerRadius = barHeight / 2
            track.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
            track.masksToBounds = true
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.frame = CGRect(x: 0, y: 0, width: 0, height: barHeight)
            fill.backgroundColor = NSColor.white.cgColor
            fill.cornerRadius = barHeight / 2
            track.addSublayer(fill)
            rightWing.addSublayer(track)
        } else {
            let textHeight = ceil(Self.font.ascender - Self.font.descender)
            status.frame = CGRect(x: 0, y: (height - textHeight) / 2, width: rightWidth - 6, height: textHeight)
            status.alignmentMode = .center
            status.contentsScale = scale
            status.font = Self.font
            status.fontSize = Self.font.pointSize
            rightWing.addSublayer(status)
        }

        panel.orderFrontRegardless()
    }

    private func update(_ content: Content, first: Bool) {
        let tint: NSColor, oldTint: NSColor, glyph: NSImage, name: String
        var on = true, failed = false, value: Float = 0
        switch content {
        case .radio(let radio, let isOn, let didFail):
            on = isOn
            failed = didFail
            tint = failed ? .systemOrange : on ? .systemGreen : Self.offColor
            oldTint = on ? Self.offColor : .systemGreen
            glyph = radio.icon(on: on || failed)
            name = "\(radio.name)\(on || failed)"
        case .level(let side, let level):
            value = level
            tint = .white
            oldTint = .white
            name = Self.levelSymbol(side, level)
            glyph = Glyphs.symbol(name)
        }
        let symbolChanged = name != symbol
        symbol = name
        let fromColor = first ? oldTint.cgColor : icon.presentation()?.backgroundColor ?? icon.backgroundColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if symbolChanged {
            iconMask.contents = Glyphs.cgImage(glyph, box: icon.bounds.width, color: .white, scale: scale)
        }
        icon.backgroundColor = tint.cgColor
        if !isLevel {
            status.string = failed ? "Error" : on ? "On" : "Off"
            status.foregroundColor = tint.cgColor
        }
        leftWing.opacity = 1
        rightWing.opacity = 1
        if first {
            shape.bounds.size = openSize
            shape.position.x = openX
            shape.shadowOpacity = 0.3
            fill.bounds.size.width = track.bounds.width * CGFloat(value)
        }
        CATransaction.commit()

        let delay: CFTimeInterval = first ? 0.06 : 0
        if first {
            // The notch stretches out to both sides; icon and value slide out from behind it.
            add(spring("bounds.size", NSValue(size: closedSize), NSValue(size: openSize), damping: 15, stiffness: 230), shape)
            add(spring("position.x", closedX, openX, damping: 15, stiffness: 230), shape)
            add(basic("shadowOpacity", 0, 0.3, 0.3), shape)
            slide(leftWing, from: leftWidth * 0.7, delay: delay)
            slide(rightWing, from: -rightWidth * 0.7, delay: delay)
        }
        if isLevel {
            if !first {
                // The bar follows the finger.
                let from = fill.presentation()?.bounds.width ?? fill.bounds.width
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                fill.bounds.size.width = track.bounds.width * CGFloat(value)
                CATransaction.commit()
                add(basic("bounds.size.width", from, fill.bounds.width, 0.14), fill)
            }
            if first || symbolChanged {
                add(spring("transform.scale", first ? 0.4 : 0.75, 1, damping: 10, stiffness: 300), icon, delay: delay + 0.05)
            }
        } else {
            add(spring("transform.scale", first ? 0.4 : 0.7, 1, damping: 9, stiffness: 260), icon, delay: delay + 0.05)
            add(basic("backgroundColor", fromColor, tint.cgColor, 0.3), icon, delay: delay + 0.15)
            add(spring("transform.scale", 0.6, 1, damping: 10, stiffness: 260), status, delay: delay + 0.1)
            if !on && !failed {
                // Turning off: the icon gives a little shiver.
                let shiver = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                shiver.values = [0, 0.22, -0.18, 0.1, -0.05, 0]
                shiver.duration = 0.45
                add(shiver, icon, delay: delay + 0.2)
            }
        }
        scheduleClose(after: isLevel ? 1.3 : 1.8)
    }

    private static func levelSymbol(_ side: Side, _ value: Float) -> String {
        if side == .left { return value < 0.5 ? "sun.min.fill" : "sun.max.fill" }
        switch value {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func slide(_ layer: CALayer, from offset: CGFloat, delay: CFTimeInterval) {
        add(basic("opacity", 0, 1, 0.2), layer, delay: delay)
        add(spring("transform.translation.x", offset, 0, damping: 14, stiffness: 220), layer, delay: delay)
    }

    private func scheduleClose(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.close() }
    }

    /// Slides everything back into the notch, then frees the window.
    private func close() {
        closing = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftWing.opacity = 0
        rightWing.opacity = 0
        shape.bounds.size = closedSize
        shape.position.x = closedX
        shape.shadowOpacity = 0
        CATransaction.commit()

        for (layer, offset) in [(leftWing, leftWidth * 0.7), (rightWing, -rightWidth * 0.7)] {
            add(basic("opacity", 1, 0, 0.18), layer)
            add(basic("transform.translation.x", 0, offset, 0.22), layer)
        }
        add(spring("bounds.size", NSValue(size: openSize), NSValue(size: closedSize), damping: 26, stiffness: 260), shape, delay: 0.06)
        add(spring("position.x", openX, closedX, damping: 26, stiffness: 260), shape, delay: 0.06)
        add(basic("shadowOpacity", 0.3, 0, 0.25), shape, delay: 0.06)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.panel.orderOut(nil)
            if NotchDrop.current === self { NotchDrop.current = nil }
        }
    }

    private func dismissNow() {
        closing = true
        hideTimer?.invalidate()
        panel.orderOut(nil)
    }

    // MARK: Animation helpers

    private func add(_ animation: CAAnimation, _ layer: CALayer, delay: CFTimeInterval = 0) {
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: (animation as? CAPropertyAnimation)?.keyPath ?? "group")
    }

    private func spring(_ path: String, _ from: Any, _ to: Any, damping: CGFloat = 14, stiffness: CGFloat = 200) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: path)
        a.fromValue = from
        a.toValue = to
        a.damping = damping
        a.stiffness = stiffness
        a.mass = 1
        a.duration = a.settlingDuration
        return a
    }

    private func basic(_ path: String, _ from: Any?, _ to: Any?, _ duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: path)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }
}

/// Lets the panel sit over the menu bar.
private final class DropPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Icons drawn by the app.
enum Glyphs {
    static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold)) ?? NSImage()
    }

    /// The Bluetooth rune (there is no SF Symbol for it).
    static func bluetooth() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
            let path = NSBezierPath()
            path.move(to: p(0.27, 0.70))
            path.line(to: p(0.73, 0.30))
            path.line(to: p(0.5, 0.07))
            path.line(to: p(0.5, 0.93))
            path.line(to: p(0.73, 0.70))
            path.line(to: p(0.27, 0.30))
            path.lineWidth = r.width * 0.11
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws a template image in one color, aspect-fit into rect.
    static func draw(_ image: NSImage, in rect: NSRect, color: NSColor) {
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: fitted(image.size, in: rect))
    }

    static func fitted(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        return NSRect(x: rect.midX - size.width * s / 2, y: rect.midY - size.height * s / 2,
                      width: size.width * s, height: size.height * s)
    }

    static func cgImage(_ image: NSImage, box: CGFloat, color: NSColor, scale: CGFloat) -> CGImage? {
        let pixels = Int(box * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: box, height: box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(image, in: NSRect(x: 0, y: 0, width: box, height: box), color: color)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
