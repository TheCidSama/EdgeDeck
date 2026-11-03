import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindow? // released on close to free its memory
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "EdgeDeck")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !Engine.shared.start() {
            let alert = NSAlert()
            alert.messageText = "No trackpad found"
            alert.informativeText = "EdgeDeck could not read the trackpad, so edge clicks and slides won't work."
            alert.runModal()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Engine.shared.restartTouches()
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                WindowWatcher.shared.appTerminated(app.processIdentifier)
            }
        }
        NotificationCenter.default.addObserver(forName: .slotsChanged, object: nil, queue: .main) { _ in
            Engine.shared.reload()
            WindowWatcher.shared.sync()
        }

        startClickTap(prompt: true)
        WindowWatcher.shared.sync()

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showSettings()
        }
    }

    /// Clicks need Accessibility access; keep checking until the user grants it.
    private func startClickTap(prompt: Bool) {
        if Engine.shared.startClickTap() { return }
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard Engine.shared.startClickTap() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.settingsWindow?.refresh()
            WindowWatcher.shared.sync()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let enabled = menu.addItem(withTitle: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = Settings.shared.enabled ? .on : .off
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Allow Accessibility to Open Apps…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit EdgeDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        Engine.shared.reload()
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showSettings() {
        WindowWatcher.shared.sync()
        if settingsWindow == nil {
            let w = SettingsWindow()
            w.onClose = { [weak self] in self?.settingsWindow = nil }
            w.onOpenAccessibility = { [weak self] in self?.openAccessibility() }
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.window.makeKeyAndOrderFront(nil)
    }
}
