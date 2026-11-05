import AppKit
import CTouch

/// Turns raw trackpad touches into edge actions:
/// - a double tap (or double click) on a filled edge slot runs that slot; its clicks are swallowed;
/// - a double tap on the top-right corner mutes;
/// - a two-finger vertical slide that starts on a side edge changes brightness (left) or volume (right);
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
    // A slide stops once the outer finger is this far past its edge strip. Fingers on the very edge read
    // a bit inward as they roll, so the strip's own border is too tight.
    private let slideExitMargin: Float = 0.06
    // How far into the pad the inner finger of a two-finger edge slide may rest: two fingers side by side
    // are wider than the strip.
    private let pairReach: Float = 0.2
    private let tapMaxMove: Float = 0.04
    // A double tap counts only if each tap is this short and the second starts this soon after the first
    // lifts. Tight on purpose, so a stray touch on an edge never opens anything.
    private let tapMaxDuration = 0.2
    private let doubleTapGap = 0.25
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
    private var scrollGuard = false                     // a two-finger edge slide is on: its scrolls aren't for the window
    private var momentumUntil: TimeInterval = 0         // ...and nor is the momentum scroll after it

    // Multitouch thread only.
    private var fingerID: Int32 = -1
    private var startX: Float = 0
    private var startY: Float = 0
    private var startTime: TimeInterval = 0
    private var startZone: Zone?
    private var moved = false
    private var pairKey: Int64?        // the two fingers of a two-finger touch
    private var pairStartX: Float = 0
    private var pairStartY: Float = 0
    private var pairSide: Side?        // the edge a two-finger slide started on
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
            endPair(now)
            waitForLift = false
            return
        }
        guard g.enabled, let touches else {
            endTouch(now, lifted: false, g)
            endPair(now)
            return
        }
        guard !waitForLift else { return }

        switch count {
        case 1 where pairKey == nil:
            single(touches.pointee, now, g)
        case 2:
            if fingerID != -1 { endTouch(now, lifted: false, g) }
            lastHit = nil
            pair(touches[0], touches[1], now, g)
        default:
            // Three or more fingers are a normal gesture, and one of two lifting ends a slide: stay out until all lift.
            endTouch(now, lifted: false, g)
            endPair(now)
            waitForLift = true
            lastHit = nil
        }
    }

    /// One finger: taps on slots and the mute corner, and sideways slides on the switcher strip.
    private func single(_ t: ct_touch, _ now: TimeInterval, _ g: Geometry) {
        if t.id != fingerID {
            fingerID = t.id
            startX = t.x
            startY = t.y
            startTime = now
            moved = false
            switching = false
            startZone = zone(t.x, t.y, g)
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

        // Decide once the finger has moved far enough: sideways on the switcher strip switches apps,
        // anything else is normal cursor movement.
        guard switchFrom, max(abs(dx), abs(dy)) >= slideStart else { return }
        guard abs(dx) > abs(dy) else { switchFrom = false; return }
        switching = true
        lastStepX = t.x
        let first = dx > 0 ? 1 : -1
        DispatchQueue.main.async { AppSwitcher.begin(); AppSwitcher.move(by: first) }
        holdCursor()
    }

    /// Two fingers: an up/down slide that starts on a side edge changes brightness (left) or volume (right).
    private func pair(_ a: ct_touch, _ b: ct_touch, _ now: TimeInterval, _ g: Geometry) {
        let lo = min(a.x, b.x), hi = max(a.x, b.x), x = (a.x + b.x) / 2, y = (a.y + b.y) / 2
        let key = Int64(min(a.id, b.id)) << 32 | Int64(max(a.id, b.id))
        if key != pairKey {
            pairKey = key
            pairStartX = x
            pairStartY = y
            sliding = false
            // The outer finger on the edge, the other one close by.
            pairSide = !g.gestures ? nil
                : lo < g.width && hi < g.width + pairReach ? .left
                : hi > 1 - g.width && lo > 1 - g.width - pairReach ? .right : nil
            let guarding = pairSide != nil
            locked { scrollGuard = guarding }
            return
        }
        guard let side = pairSide else { return }

        let outer = side == .left ? lo : hi
        let onEdge = side == .left ? outer < g.width + slideExitMargin : outer > 1 - g.width - slideExitMargin
        let dx = x - pairStartX, dy = y - pairStartY
        if !sliding {
            guard max(abs(dx), abs(dy)) >= slideStart || !onEdge else { return }
            // Loose check: on the very edge the reported x drifts inward while sliding.
            guard onEdge, abs(dy) > abs(dx) else {
                // A sideways swipe or a move off the edge: it's a normal two-finger gesture after all.
                pairSide = nil
                locked { scrollGuard = false }
                return
            }
            sliding = true
            lastStepY = pairStartY
        } else if !onEdge {
            // Slid off the edge: no more level changes, but keep the scroll away until the fingers lift.
            pairSide = nil
            return
        }

        var steps = 0
        while y - lastStepY >= stepDistance { lastStepY += stepDistance; steps += 1 }
        while lastStepY - y >= stepDistance { lastStepY -= stepDistance; steps -= 1 }
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

    private func endPair(_ now: TimeInterval) {
        guard pairKey != nil else { return }
        pairKey = nil
        pairSide = nil
        sliding = false
        locked {
            if scrollGuard { momentumUntil = now + 1.5 }
            scrollGuard = false
        }
    }

    private func endTouch(_ now: TimeInterval, lifted: Bool, _ g: Geometry) {
        guard fingerID != -1 else { return }
        if switching {
            // Lifting picks the highlighted app; a second finger landing cancels.
            DispatchQueue.main.async { lifted ? AppSwitcher.commit() : AppSwitcher.cancel() }
            switching = false
        }
        switchFrom = false
        let still = lifted && !moved
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
    }

    /// One tap or click on a filled slot: the second one in time runs the slot.
    private func hit(_ z: Zone, startedAt start: TimeInterval, liftedAt now: TimeInterval, _ g: Geometry) {
        if let last = lastHit, last.zone == z, start - last.at <= doubleTapGap {
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
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .scrollWheel]
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
        case .scrollWheel:
            if scrollIsOnEdge(event) { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// To macOS a two-finger edge slide is also a scroll: keep it (and the momentum after it) from the window underneath.
    private func scrollIsOnEdge(_ event: CGEvent) -> Bool {
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        let now = ProcessInfo.processInfo.systemUptime
        return locked { scrollGuard || (momentum && now < momentumUntil) }
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
