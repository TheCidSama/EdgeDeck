import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN
import CTouch

/// Volume and brightness, shown on the notch. Main thread only.
enum Controls {
    /// Same 16 steps as the keyboard keys.
    private static let levels: Float = 16

    static func step(_ side: Side, by direction: Int) {
        guard let before = level(side) else { return }
        let muted = side == .right && isMuted()
        let target = next(before, direction)
        let unmutes = muted && direction > 0
        // At the end of the range nothing changes and there is no tick, so you can feel the limit.
        if target != before || unmutes {
            Haptics.tick()
            setLevel(side, target, unmute: unmutes)
        }
        NotchDrop.showLevel(side, muted && !unmutes ? 0 : target)
    }

    private static func next(_ value: Float, _ direction: Int) -> Float {
        min(1, max(0, ((value * levels).rounded() + Float(direction)) / levels))
    }

    private static func level(_ side: Side) -> Float? {
        if side == .left {
            var value: Float = 0
            return ct_brightness_get(&value) ? value : nil
        }
        guard let device = outputDevice() else { return nil }
        var address = volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setLevel(_ side: Side, _ value: Float, unmute: Bool) {
        if side == .left {
            _ = ct_brightness_set(value)
            return
        }
        guard let device = outputDevice() else { return }
        if unmute { setMuted(device, false) }
        var address = volumeAddress
        var target = value
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &target)
    }

    // MARK: CoreAudio, default output device

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static func outputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isMuted() -> Bool {
        guard let device = outputDevice() else { return false }
        var address = muteAddress
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr && muted != 0
    }

    private static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// Runs what is in a slot. Main thread only.
enum Actions {
    static func perform(_ zone: Engine.Zone) {
        guard let item = Settings.shared.item(zone.side, zone.slot) else { return }
        switch item {
        case .app(let path):
            Haptics.thump()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        case .window(let pid, let id, _, _):
            if Windows.focus(pid: pid, id: id) {
                Haptics.thump()
            } else {
                Settings.shared.setItem(nil, zone.side, zone.slot) // the window is gone
            }
        case .wifi:
            Radios.toggleWiFi()
        case .bluetooth:
            Radios.toggleBluetooth()
        }
    }
}

/// Wi-Fi (CoreWLAN) and Bluetooth (IOBluetooth's power functions, as used by blueutil).
enum Radios {
    static func toggleWiFi() {
        guard let wifi = CWWiFiClient.shared().interface() else {
            NotchDrop.show(.wifi, on: false, failed: true)
            return
        }
        let on = !wifi.powerOn()
        do {
            try wifi.setPower(on)
            Haptics.thump()
            NotchDrop.show(.wifi, on: on)
        } catch {
            NotchDrop.show(.wifi, on: wifi.powerOn(), failed: true)
        }
    }

    static func toggleBluetooth() {
        guard let get = bluetooth.get, let set = bluetooth.set else {
            NotchDrop.show(.bluetooth, on: false, failed: true)
            return
        }
        let on = get() == 0
        set(on ? 1 : 0)
        Haptics.thump()
        NotchDrop.show(.bluetooth, on: on)
    }

    private typealias PowerGet = @convention(c) () -> Int32
    private typealias PowerSet = @convention(c) (Int32) -> Void

    private static let bluetooth: (get: PowerGet?, set: PowerSet?) = {
        guard let lib = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let get = dlsym(lib, "IOBluetoothPreferenceGetControllerPowerState"),
              let set = dlsym(lib, "IOBluetoothPreferenceSetControllerPowerState")
        else { return (nil, nil) }
        return (unsafeBitCast(get, to: PowerGet.self), unsafeBitCast(set, to: PowerSet.self))
    }()
}

/// Trackpad haptics: the trackpad's own actuator, with AppKit's haptics as a fallback.
enum Haptics {
    static func tick() { play(3, fallback: .alignment) }
    static func thump() { play(6, fallback: .levelChange) }

    private static func play(_ actuation: Int32, fallback: NSHapticFeedbackManager.FeedbackPattern) {
        guard Settings.shared.haptics else { return }
        if !ct_haptic(actuation) {
            NSHapticFeedbackManager.defaultPerformer.perform(fallback, performanceTime: .now)
        }
    }
}
