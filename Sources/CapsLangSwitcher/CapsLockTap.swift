import Cocoa
import CoreGraphics
import LangSwitchCore

enum CapsLockTapError: LocalizedError {
    case eventTapUnavailable
    case eventTapStopped

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "macOS refused to create the keyboard event tap. Confirm Accessibility access and relaunch LangSwitch."
        case .eventTapStopped:
            return "The keyboard event tap became unavailable. LangSwitch restored the previous Caps Lock mapping."
        }
    }
}

/// Captures only key-down/key-up events, forwards every key except F18 unchanged,
/// and delegates reversible Caps Lock remapping to HIDMappingManager.
final class CapsLockTap {
    private let f18VirtualKeyCode: Int64 = 79
    private let mappingManager = HIDMappingManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    var onTap: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var isRunning: Bool { eventTap != nil }

    func start() throws {
        guard eventTap == nil else { return }

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tapSelf = Unmanaged<CapsLockTap>.fromOpaque(refcon).takeUnretainedValue()
                return tapSelf.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            throw CapsLockTapError.eventTapUnavailable
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        do {
            // Create the event tap first. The global remap is applied only after we know
            // that macOS granted the ability to receive the remapped F18 events.
            try mappingManager.activate()
            CGEvent.tapEnable(tap: tap, enable: true)
            startWakeObserver()
            healthTimer = Timer.scheduledTimer(
                withTimeInterval: 2,
                repeats: true
            ) { [weak self] _ in
                guard let self else { return }
                self.verifyEventTap()
                if self.isRunning {
                    self.mappingManager.reapplyActiveIfNeeded()
                }
            }
        } catch {
            removeEventTap()
            throw error
        }
    }

    func stop() {
        removeEventTap()
        mappingManager.restoreOriginal()
    }

    private func removeEventTap() {
        stopWakeObserver()
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func startWakeObserver() {
        stopWakeObserver()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, self.isRunning else { return }
                self.mappingManager.reapplyActive()
            }
        }
    }

    private func stopWakeObserver() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func verifyEventTap() {
        guard let tap = eventTap else { return }

        if CFMachPortIsValid(tap), !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        guard CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            onFailure?(CapsLockTapError.eventTapStopped)
            return
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.keyboardEventKeycode) == f18VirtualKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            // Called directly (not dispatched) — the tap already runs on the main
            // run loop, so this is the fastest path from key press to switch.
            onTap?()
        }

        // Swallow only F18. Every other key is returned unchanged above.
        return nil
    }
}
