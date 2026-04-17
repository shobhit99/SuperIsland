import AppKit
import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem

/// Intercepts the hardware volume keys (F10/F11/F12 or touch-bar / keyboard-row
/// equivalents) via a session-level `CGEventTap` so the macOS system overlay
/// (`OSDUIHelper`) never receives the event. The volume change is then applied
/// programmatically via `VolumeManager` and SuperIsland's own HUD is shown.
///
/// The tap runs in `.defaultTap` mode which lets the callback return `nil` to
/// consume the event. Consuming before the OS dispatches to `OSDUIHelper` is
/// what actually prevents the system HUD from drawing — simply killing the
/// helper after the fact is too late, because the overlay has already been
/// queued for display by the time any `CoreAudio` listener fires.
///
/// Requires Accessibility permission. If permission isn't granted when the
/// tap is requested, the interceptor keeps polling (and re-installs whenever
/// the app regains focus) so the tap activates as soon as the user flips the
/// switch in System Settings.
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var desiredEnabled = false
    private var retryTimer: Timer?

    /// Volume adjustment per keypress. Matches macOS's default step (1/16).
    private static let volumeStep: Float = 1.0 / 16.0
    /// Finer step used when Shift+Option is held, matching macOS behavior.
    private static let fineVolumeStep: Float = 1.0 / 64.0

    // HID key codes for media keys. Defined in <IOKit/hidsystem/ev_keymap.h>
    // but the symbols aren't bridged into Swift, so we define them here.
    private static let NX_KEYTYPE_SOUND_UP: Int = 0
    private static let NX_KEYTYPE_SOUND_DOWN: Int = 1
    private static let NX_KEYTYPE_MUTE: Int = 7
    private static let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8
    private static let NX_SYSDEFINED_EVENT_TYPE: UInt32 = 14

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// Install or remove the event tap based on the user preference.
    func apply(enabled: Bool) {
        desiredEnabled = enabled
        if enabled {
            install()
            if eventTap == nil {
                // Missing Accessibility permission, most likely. Keep retrying
                // until the user grants it so the setting "just starts working."
                scheduleRetry()
            }
        } else {
            uninstall()
            cancelRetry()
        }
    }

    /// `true` if the event tap is currently installed and active.
    var isInstalled: Bool { eventTap != nil }

    // MARK: - Install / Uninstall

    private func install() {
        guard eventTap == nil else { return }

        guard PermissionsManager.shared.checkAccessibility() else {
            NSLog("[MediaKeyInterceptor] Accessibility permission not granted — requesting.")
            PermissionsManager.shared.requestAccessibility()
            return
        }

        let eventMask: CGEventMask = CGEventMask(1) << CGEventMask(Self.NX_SYSDEFINED_EVENT_TYPE)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            MediaKeyInterceptor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        ) else {
            NSLog("[MediaKeyInterceptor] CGEvent.tapCreate returned nil (Accessibility likely denied for this build).")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        NSLog("[MediaKeyInterceptor] Event tap installed.")
    }

    private func uninstall() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Retry

    private func scheduleRetry() {
        cancelRetry()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.desiredEnabled else {
                self.cancelRetry()
                return
            }
            if self.eventTap == nil {
                self.install()
            }
            if self.eventTap != nil {
                self.cancelRetry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    @objc private func appDidBecomeActive() {
        // Coming back from System Settings is a strong signal the user may
        // have just granted Accessibility — try immediately.
        guard desiredEnabled, eventTap == nil else { return }
        install()
    }

    // MARK: - Callback

    private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS may disable the tap if it misbehaves or times out. Re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = MediaKeyInterceptor.shared.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == NX_SYSDEFINED_EVENT_TYPE,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        switch keyCode {
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN:
            if isKeyDown {
                let modifiers = nsEvent.modifierFlags
                let fine = modifiers.contains(.shift) && modifiers.contains(.option)
                let step = fine ? fineVolumeStep : volumeStep
                let delta: Float = keyCode == NX_KEYTYPE_SOUND_UP ? step : -step
                applyVolumeDelta(delta)
            }
            return nil
        case NX_KEYTYPE_MUTE:
            if isKeyDown {
                applyToggleMute()
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Volume application

    private static func applyVolumeDelta(_ delta: Float) {
        Task { @MainActor in
            let manager = VolumeManager.shared
            // If currently muted, a volume-up press should unmute first
            // (matches default macOS behavior).
            if manager.isMuted, delta > 0 {
                manager.toggleMute()
            }
            let current = manager.volume
            let next = max(0, min(1, current + delta))
            manager.setVolume(next)
        }
    }

    private static func applyToggleMute() {
        Task { @MainActor in
            VolumeManager.shared.toggleMute()
        }
    }
}
