import AppKit

// Private but stable (used by AltTab, Rectangle...): the window server id of an Accessibility window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Open windows of other apps, through the Accessibility API. Main thread only.
enum Windows {
    struct Info {
        let pid: pid_t
        let id: CGWindowID
        let title: String
        let app: NSRunningApplication
    }

    static func list() -> [Info] {
        let me = ProcessInfo.processInfo.processIdentifier
        var result: [Info] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            for window in axWindows(app.processIdentifier) {
                guard attribute(window, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole,
                      let id = windowID(window) else { continue }
                let title = attribute(window, kAXTitleAttribute) as String? ?? ""
                result.append(Info(pid: app.processIdentifier, id: id, title: title, app: app))
            }
        }
        return result
    }

    /// Brings one window to the front. False if it no longer exists.
    static func focus(pid: pid_t, id: CGWindowID) -> Bool {
        guard exists(pid: pid, id: id), let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if let window = element(pid: pid, id: id) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        app.activate(options: [])
        return true
    }

    /// Checks the window server, which also sees windows on other Spaces.
    static func exists(pid: pid_t, id: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let window = info.first else { return false }
        return window[kCGWindowOwnerPID as String] as? pid_t == pid
    }

    static func element(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        axWindows(pid).first { windowID($0) == id }
    }

    private static func axWindows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3) // don't hang on a frozen app
        return attribute(app, kAXWindowsAttribute) as [AXUIElement]? ?? []
    }

    private static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// Empties window slots when their window closes or their app quits. Main thread only.
final class WindowWatcher {
    static let shared = WindowWatcher()

    private var observers: [pid_t: AXObserver] = [:]
    private var watched: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]

    /// Clears slots whose window is gone and starts watching the others.
    func sync() {
        var live = Set<CGWindowID>()
        var gone: [CGWindowID] = []
        for side in Side.allCases {
            for case .window(let pid, let id, _, _)? in Settings.shared.items(side) {
                guard Windows.exists(pid: pid, id: id) else { gone.append(id); continue }
                live.insert(id)
                if watched[id] == nil, let element = Windows.element(pid: pid, id: id), let observer = observer(pid),
                   AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil) == .success {
                    watched[id] = (pid, element)
                }
            }
        }
        for (id, w) in watched where !live.contains(id) {
            if let observer = observers[w.pid] {
                AXObserverRemoveNotification(observer, w.element, kAXUIElementDestroyedNotification as CFString)
            }
            watched[id] = nil
        }
        clearSlots { _, id in gone.contains(id) }
    }

    func appTerminated(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        watched = watched.filter { $0.value.pid != pid }
        clearSlots { slotPID, _ in slotPID == pid }
    }

    fileprivate func destroyed(_ element: AXUIElement) {
        guard let id = watched.first(where: { CFEqual($0.value.element, element) })?.key else { return }
        watched[id] = nil
        clearSlots { _, slotID in slotID == id }
    }

    private func clearSlots(where matches: (pid_t, CGWindowID) -> Bool) {
        let s = Settings.shared
        for side in Side.allCases {
            for (slot, item) in s.items(side).enumerated() {
                if case .window(let pid, let id, _, _)? = item, matches(pid, id) { s.setItem(nil, side, slot) }
            }
        }
    }

    private func observer(_ pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, _ in WindowWatcher.shared.destroyed(element) }, &created) == .success,
              let observer = created else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        return observer
    }
}
