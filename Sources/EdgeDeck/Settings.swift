import Foundation

enum Side: Int, CaseIterable, Codable {
    case left, right
}

/// What a slot does when it is double-tapped.
enum SlotItem: Codable, Equatable {
    case app(path: String)
    /// One window of a running app. Cleared when the window closes.
    case window(pid: Int32, windowID: UInt32, appPath: String, title: String)
    case wifi
    case bluetooth
}

extension Notification.Name {
    static let slotsChanged = Notification.Name("EdgeDeck.slotsChanged")
}

/// User preferences, stored in UserDefaults. Main thread only.
final class Settings {
    static let shared = Settings()
    static let maxSlots = 4
    static let widthRange = 0.08...0.15

    private let d = UserDefaults.standard
    private var slots: [Side: [SlotItem?]] = [:]

    var enabled: Bool {
        get { bool("enabled", true) }
        set { d.set(newValue, forKey: "enabled") }
    }

    /// Width of each edge strip as a fraction of the trackpad width.
    var edgeWidth: Double {
        get { Self.clampWidth(d.object(forKey: "edgeWidth") as? Double ?? 0.15) }
        set { d.set(Self.clampWidth(newValue), forKey: "edgeWidth") }
    }

    private static func clampWidth(_ value: Double) -> Double {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    /// 3 or 4 slots on each edge, stacked top to bottom.
    var slotsPerSide: Int {
        get { d.object(forKey: "slotsPerSide") as? Int == 4 ? 4 : 3 }
        set { d.set(newValue, forKey: "slotsPerSide") }
    }

    var haptics: Bool {
        get { bool("haptics", true) }
        set { d.set(newValue, forKey: "haptics") }
    }

    /// Two-finger slide on the left edge for brightness, on the right edge for volume.
    var gestures: Bool {
        get { bool("gestures", true) }
        set { d.set(newValue, forKey: "gestures") }
    }

    /// Slide left/right along the top (or bottom) edge to switch apps.
    var appSwitcher: Bool {
        get { bool("appSwitcher", true) }
        set { d.set(newValue, forKey: "appSwitcher") }
    }

    enum SwitcherEdge: String { case top, bottom }

    var switcherEdge: SwitcherEdge {
        get { SwitcherEdge(rawValue: d.string(forKey: "switcherEdge") ?? "") ?? .top }
        set { d.set(newValue.rawValue, forKey: "switcherEdge") }
    }

    /// Double-tap the top-right corner to mute.
    var muteCorner: Bool {
        get { bool("muteCorner", true) }
        set { d.set(newValue, forKey: "muteCorner") }
    }

    /// Depth of the top and bottom strips as a fraction of the trackpad height, or 0 when they have nothing to do.
    /// They follow the edge width so one slider sets every edge; the side slots sit between them.
    var topDepth: Double { (appSwitcher && switcherEdge == .top) || muteCorner ? edgeWidth : 0 }
    var bottomDepth: Double { appSwitcher && switcherEdge == .bottom ? edgeWidth : 0 }

    /// The item in a slot (0 = top), or nil if empty.
    func item(_ side: Side, _ slot: Int) -> SlotItem? {
        let list = items(side)
        return slot < list.count ? list[slot] : nil
    }

    func setItem(_ item: SlotItem?, _ side: Side, _ slot: Int) {
        var list = items(side)
        list[slot] = item
        slots[side] = list
        d.set(try? JSONEncoder().encode(list), forKey: key(side))
        NotificationCenter.default.post(name: .slotsChanged, object: nil)
    }

    func items(_ side: Side) -> [SlotItem?] {
        if let cached = slots[side] { return cached }
        var list: [SlotItem?] = []
        if let data = d.data(forKey: key(side)), let decoded = try? JSONDecoder().decode([SlotItem?].self, from: data) {
            list = decoded
        } else if let paths = d.stringArray(forKey: side == .left ? "leftApps" : "rightApps") {
            list = paths.map { $0.isEmpty ? nil : .app(path: $0) } // apps saved by version 1.0
        }
        while list.count < Self.maxSlots { list.append(nil) }
        slots[side] = list
        return list
    }

    private func key(_ side: Side) -> String { side == .left ? "leftSlots" : "rightSlots" }

    private func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
}
