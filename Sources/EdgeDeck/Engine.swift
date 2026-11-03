import AppKit
import CTouch

/// Turns raw trackpad touches into edge actions:
/// - a double tap (or double click) on a filled edge slot runs that slot; its clicks are swallowed;
/// - a vertical slide that starts on an edge changes brightness (left) or volume (right).
final class Engine {
    static let shared = Engine()

    struct Zone: Equatable {
        let side: Side
        let slot: Int
    }

    private struct Geometry {
        var width: Float = 0.15
        var slots = 3
        var enabled = true
        var gestures = true
        var filled = Set<Int>()
        var doubleTap: TimeInterval = 0.5

        func isFilled(_ z: Zone) -> Bool { filled.contains(z.side.rawValue * Settings.maxSlots + z.slot) }
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
        var g = Geometry(width: Float(s.edgeWidth), slots: s.slotsPerSide, enabled: s.enabled, gestures: s.gestures)
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
            startZone = zone(t.x, t.y, g)
            slideSide = g.gestures ? startZone?.side : nil
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

        guard let side = slideSide else { return }
        let insideStrip = side == .left ? t.x < g.width + slideExitMargin : t.x > 1 - g.width - slideExitMargin
        guard insideStrip else {
            // Left the edge: the rest of this touch moves the cursor normally.
            slideSide = nil
            sliding = false
            return
        }
        if !sliding {
            if abs(dy) < slideStart {
                if abs(dx) > slideStart { slideSide = nil } // moving the cursor out of the edge
                return
            }
            // Loose check: on the very edge the reported x drifts inward while sliding.
            guard abs(dy) > abs(dx) else { slideSide = nil; return }
            sliding = true
            lastStepY = startY
        }

        // Keep the cursor still while sliding.
        CGWarpMouseCursorPosition(cursor)
        CGAssociateMouseAndMouseCursorPosition(1) // removes the short freeze after a warp

        var steps = 0
        while t.y - lastStepY >= stepDistance { lastStepY += stepDistance; steps += 1 }
        while lastStepY - t.y >= stepDistance { lastStepY -= stepDistance; steps -= 1 }
        if steps != 0 {
            DispatchQueue.main.async {
                for _ in 0..<abs(steps) { Controls.step(side, by: steps > 0 ? 1 : -1) }
            }
        }
    }

    private func endTouch(_ now: TimeInterval, lifted: Bool, _ g: Geometry) {
        guard fingerID != -1 else { return }
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

    private func zone(_ x: Float, _ y: Float, _ g: Geometry) -> Zone? {
        let side: Side
        if x < g.width { side = .left } else if x > 1 - g.width { side = .right } else { return nil }
        let slot = min(g.slots - 1, max(0, Int((1 - y) * Float(g.slots))))
        return Zone(side: side, slot: slot)
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
