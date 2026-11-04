import AppKit
import CTouch

/// Turns raw trackpad touches into edge actions:
/// - a double tap (or double click) on a filled edge slot runs that slot; its clicks are swallowed;
/// - a double tap on the top-right corner mutes;
/// - a vertical slide that starts on a side edge changes brightness (left) or volume (right);
/// - a horizontal slide that starts on the top (or bottom) edge switches apps.
final class Engine {
    static let shared = Engine()

    enum Zone: Equatable {
        case slot(Side, Int)
        case muteCorner
    }

    private struct Geometry {
        var width: Float = 0.15
        var top: Float = 0       // depth of the top strip, 0 when it's off
        var bottom: Float = 0    // depth of the bottom strip, 0 when it's off
        var slots = 3
        var enabled = true
        var gestures = true
        var switchTop = true     // which strip switches apps (neither when it's off)
        var switchBottom = false
        var mute = true
        var filled = Set<Int>()
        var doubleTap: TimeInterval = 0.5

        func isFilled(_ z: Zone) -> Bool {
            switch z {
            case .slot(let side, let slot): filled.contains(side.rawValue * Settings.maxSlots + slot)
            case .muteCorner: mute
            }
        }
    }

    // Trackpad distance (0...1 of its height) per volume/brightness step.
    private let stepDistance: Float = 0.045
    private let slideStart: Float = 0.05
    // A slide stops once the finger is this far past its edge strip. Fingers on the very edge read
    // a bit inward as they roll, so the strip's own border is too tight.
    private let slideExitMargin: Float = 0.06
    private let tapMaxMove: Float = 0.04
    private let tapMaxDuration = 0.35
    private let tapClickDelay = 0.4
    // Trackpad distance (0...1 of its width) per app while switching.
    private let switchStep: Float = 0.06

    // Shared between the multitouch thread and the main thread.
    private let lock = NSLock()
    private var geometry = Geometry()
    private var pressed: Zone?                          // finger resting on a filled slot right now
    private var clickedDuringTouch = false              // a physical click happened while pressed
    private var tapped: (zone: Zone, at: TimeInterval)? // quick tap that just lifted (tap to click)
    private var previewing = false

    // Multitouch thread only.
    private var fingerID: Int32 = -1
    private var startX: Float = 0
    private var startY: Float = 0
    private var startTime: TimeInterval = 0
    private var startZone: Zone?
    private var moved = false
    private var slideSide: Side?
    private var sliding = false
    private var lastStepY: Float = 0
    private var switchFrom = false   // started on the switcher strip, so a horizontal slide switches apps
    private var switching = false
    private var lastStepX: Float = 0
    private var cursor = CGPoint.zero
    private var waitForLift = false
    private var lastHit: (zone: Zone, at: TimeInterval)?

    // Main thread only.
    private var tap: CFMachPort?
    private var swallowUntilUp = false

    /// Receives live finger positions while the settings window is open.
    var preview: (([CGPoint]) -> Void)? {
        didSet { locked { previewing = preview != nil } }
    }

    func start() -> Bool {
        reload()
        return ct_touch_start { touches, count in Engine.shared.handle(touches, Int(count)) }
    }

    /// The multitouch device stops delivering touches after sleep.
    func restartTouches() {
        ct_touch_stop()
        _ = start()
    }

    /// Call after changing Settings.
    func reload() {
        let s = Settings.shared
        var g = Geometry(width: Float(s.edgeWidth), top: Float(s.topDepth), bottom: Float(s.bottomDepth), slots: s.slotsPerSide,
                         enabled: s.enabled, gestures: s.gestures,
                         switchTop: s.appSwitcher && s.switcherEdge == .top, switchBottom: s.appSwitcher && s.switcherEdge == .bottom,
                         mute: s.muteCorner)
        g.doubleTap = NSEvent.doubleClickInterval
        for side in Side.allCases {
            for slot in 0..<g.slots where s.item(side, slot) != nil {
                g.filled.insert(side.rawValue * Settings.maxSlots + slot)
            }
        }
        locked {
            geometry = g
            pressed = nil
            tapped = nil
        }
    }

    // MARK: Touches (multitouch thread)

    private func handle(_ touches: UnsafePointer<ct_touch>?, _ count: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let (g, wantsPreview) = locked { (geometry, previewing) }

        if wantsPreview {
            let points = touches.map { t in (0..<count).map { CGPoint(x: CGFloat(t[$0].x), y: CGFloat(t[$0].y)) } } ?? []
            DispatchQueue.main.async { self.preview?(points) }
        }

        if count == 0 {
            endTouch(now, lifted: true, g)
            waitForLift = false
            return
        }
        // Several fingers mean a normal gesture (scroll, right click...): stay out until all lift.
        guard count == 1, !waitForLift, g.enabled, let t = touches?.pointee else {
            endTouch(now, lifted: false, g)
            waitForLift = true
            lastHit = nil
            return
        }

        if t.id != fingerID {
            fingerID = t.id
            startX = t.x
            startY = t.y
            startTime = now
            moved = false
            sliding = false
            switching = false
            startZone = zone(t.x, t.y, g)
            slideSide = g.gestures ? side(t.x, g) : nil
            switchFrom = (g.switchTop && t.y > 1 - g.top) || (g.switchBottom && t.y < g.bottom)
            cursor = CGEvent(source: nil)?.location ?? .zero
            let filled = startZone.flatMap { g.isFilled($0) ? $0 : nil }
            locked {
                pressed = filled
                clickedDuringTouch = false
                tapped = nil
            }
            return
        }

        let dx = t.x - startX, dy = t.y - startY
        if !moved && hypot(dx, dy) > tapMaxMove {
            moved = true
            locked { pressed = nil }
        }

        if switching {
            holdCursor()
            var steps = 0
            while t.x - lastStepX >= switchStep { lastStepX += switchStep; steps += 1 }
            while lastStepX - t.x >= switchStep { lastStepX -= switchStep; steps -= 1 }
            if steps != 0 { DispatchQueue.main.async { AppSwitcher.move(by: steps) } }
            return
        }

        if let side = slideSide {
            let insideStrip = side == .left ? t.x < g.width + slideExitMargin : t.x > 1 - g.width - slideExitMargin
            if !insideStrip {
                // Left the edge: no more volume/brightness for this touch.
                slideSide = nil
                sliding = false
            }
        }

        if !sliding {
            // Decide once the finger has moved far enough: sideways on the switcher strip switches apps,
            // up/down on a side edge changes the level, anything else is normal cursor movement.
            guard max(abs(dx), abs(dy)) >= slideStart else { return }
            if switchFrom && abs(dx) > abs(dy) {
                switching = true
                slideSide = nil
                lastStepX = t.x
                let first = dx > 0 ? 1 : -1
                DispatchQueue.main.async { AppSwitcher.begin(); AppSwitcher.move(by: first) }
                holdCursor()
                return
            }
            switchFrom = false
            // Loose check: on the very edge the reported x drifts inward while sliding.
            guard slideSide != nil, abs(dy) > abs(dx) else { slideSide = nil; return }
            sliding = true
            lastStepY = startY
        }
        guard let side = slideSide else { return }

        holdCursor()

        var steps = 0
        while t.y - lastStepY >= stepDistance { lastStepY += stepDistance; steps += 1 }
        while lastStepY - t.y >= stepDistance { lastStepY -= stepDistance; steps -= 1 }
        if steps != 0 {
            DispatchQueue.main.async {
                for _ in 0..<abs(steps) { Controls.step(side, by: steps > 0 ? 1 : -1) }
            }
        }
    }

    /// Keeps the cursor still while a slide drives something else.
    private func holdCursor() {
        CGWarpMouseCursorPosition(cursor)
        CGAssociateMouseAndMouseCursorPosition(1) // removes the short freeze after a warp
    }

    private func endTouch(_ now: TimeInterval, lifted: Bool, _ g: Geometry) {
        guard fingerID != -1 else { return }
        if switching {
            // Lifting picks the highlighted app; a second finger landing cancels.
            DispatchQueue.main.async { lifted ? AppSwitcher.commit() : AppSwitcher.cancel() }
            switching = false
        }
        switchFrom = false
        let still = lifted && !moved && !sliding
        let quick = now - startTime < tapMaxDuration
        let filled = startZone.flatMap { g.isFilled($0) ? $0 : nil }
        let clicked = locked { () -> Bool in
            let clicked = clickedDuringTouch
            clickedDuringTouch = false
            pressed = nil
            if still, quick, let filled { tapped = (filled, now) }
            return clicked
        }
        if still, let filled, quick || clicked { hit(filled, startedAt: startTime, liftedAt: now, g) }
        fingerID = -1
        startZone = nil
        slideSide = nil
        sliding = false
    }

    /// One tap or click on a filled slot: the second one in time runs the slot.
    private func hit(_ z: Zone, startedAt start: TimeInterval, liftedAt now: TimeInterval, _ g: Geometry) {
        if let last = lastHit, last.zone == z, start - last.at <= g.doubleTap {
            lastHit = nil
            DispatchQueue.main.async { Actions.perform(z) }
        } else {
            lastHit = (z, now)
            DispatchQueue.main.async { Haptics.tick() }
        }
    }

    private func side(_ x: Float, _ g: Geometry) -> Side? {
        x < g.width ? .left : x > 1 - g.width ? .right : nil
    }

    /// The tap target under a point. The top strip only has the mute corner, the bottom strip has none;
    /// the side slots sit between them.
    private func zone(_ x: Float, _ y: Float, _ g: Geometry) -> Zone? {
        if g.top > 0, y > 1 - g.top {
            return g.mute && x > 1 - g.width ? .muteCorner : nil
        }
        if y < g.bottom { return nil }
        guard let side = side(x, g) else { return nil }
        let span = 1 - g.top - g.bottom
        let slot = min(g.slots - 1, max(0, Int((1 - g.top - y) / span * Float(g.slots))))
        return .slot(side, slot)
    }

    // MARK: Clicks (main thread)

    /// Needs Accessibility access. Returns false until it is granted.
    func startClickTap() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in Engine.shared.onMouse(type, event) },
            userInfo: nil)
        else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        return true
    }

    private func onMouse(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            if clickIsOnSlot() {
                swallowUntilUp = true
                return nil
            }
        case .leftMouseDragged, .leftMouseUp:
            if swallowUntilUp {
                if type == .leftMouseUp { swallowUntilUp = false }
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Clicks on a filled slot belong to EdgeDeck, so they never reach the app under the cursor.
    private func clickIsOnSlot() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return locked {
            guard geometry.enabled else { return false }
            if pressed != nil {
                clickedDuringTouch = true
                return true
            }
            if let t = tapped, now - t.at < tapClickDelay {
                tapped = nil
                return true
            }
            return false
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
