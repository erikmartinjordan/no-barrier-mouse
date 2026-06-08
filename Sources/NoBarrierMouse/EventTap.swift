import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class EventTap {
    var isForwarding = false
    var isConnected = false
    var send: ((WireMessage) -> Void)?
    var onForwardingChanged: ((Bool) -> Void)?
    var onEmergencyOff: (() -> Void)?
    var onCaptureFailed: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localCursorSuppressed = false

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let ref = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: ref
        )

        guard let tap else {
            onCaptureFailed?()
            return false
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isForwarding = false
        isConnected = false
        restoreLocalCursor()
    }

    func releaseLocalControl() {
        isForwarding = false
        flushDelta()
        restoreLocalCursor()
        onForwardingChanged?(false)
    }

    func reclaimLocalControlFromRemote() {
        isForwarding = false
        pendingDelta = .zero
        restoreLocalCursor()

        let screen = NSScreenFrame.main
        CGWarpMouseCursorPosition(CGPoint(x: screen.maxX - 24, y: screen.midY))
        onForwardingChanged?(false)
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if isEmergencyRelease(type: type, event: event) {
            send?(.release)
            releaseLocalControl()
            onEmergencyOff?()
            return nil
        }

        guard isConnected else {
            return Unmanaged.passRetained(event)
        }

        if !isForwarding, shouldEnterRemote(type: type, event: event) {
            enterRemoteControl()
            return nil
        }

        guard isForwarding else {
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            send?(.release)
            releaseLocalControl()
            let screen = NSScreenFrame.main
            CGWarpMouseCursorPosition(CGPoint(x: screen.midX, y: screen.midY))
            return nil
        }

        forward(type: type, event: event)
        return nil
    }

    private func crossesRightEdge(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged else {
            return false
        }
        return event.location.x >= NSScreenFrame.main.maxX - 12
    }

    private func shouldEnterRemote(type: CGEventType, event: CGEvent) -> Bool {
        return crossesRightEdge(event: event, type: type) || isKeyboardEnterRemote(type: type, event: event)
    }

    private func enterRemoteControl() {
        isForwarding = true
        suppressLocalCursor()
        send?(.enter)
        onForwardingChanged?(true)
        pinLocalCursor()
    }

    private func suppressLocalCursor() {
        guard !localCursorSuppressed else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
        localCursorSuppressed = true
    }

    private func restoreLocalCursor() {
        guard localCursorSuppressed else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        localCursorSuppressed = false
    }

    private func pinLocalCursor() {
        let screen = NSScreenFrame.main
        CGWarpMouseCursorPosition(CGPoint(x: screen.maxX - 8, y: screen.midY))
    }

    private func flushDelta() {
        if pendingDelta.x != 0 || pendingDelta.y != 0 {
            send?(.mouseDelta(dx: pendingDelta.x, dy: pendingDelta.y, button: nil))
            pendingDelta = .zero
        }
    }

    private func isKeyboardEnterRemote(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 124 else { return false }
        let flags = event.flags
        return flags.contains(.maskCommand) && flags.contains(.maskAlternate) && flags.contains(.maskControl)
    }

    private func isEmergencyRelease(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
        let flags = event.flags
        return flags.contains(.maskCommand) && flags.contains(.maskAlternate) && flags.contains(.maskControl)
    }

    private var pendingDelta = CGPoint.zero
    private var lastDeltaSend = Date.distantPast
    private let deltaThrottle: TimeInterval = 1.0 / 240.0

    private func forward(type: CGEventType, event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            pendingDelta.x += dx
            pendingDelta.y += dy
            let now = Date()
            if now.timeIntervalSince(lastDeltaSend) >= deltaThrottle {
                send?(.mouseDelta(dx: pendingDelta.x, dy: pendingDelta.y, button: nil))
                pendingDelta = .zero
                lastDeltaSend = now
            }
            pinLocalCursor()
        case .leftMouseDown:
            flushDelta()
            send?(.mouseDown(button: 0))
        case .leftMouseUp:
            flushDelta()
            send?(.mouseUp(button: 0))
        case .rightMouseDown:
            flushDelta()
            send?(.mouseDown(button: 1))
        case .rightMouseUp:
            flushDelta()
            send?(.mouseUp(button: 1))
        case .otherMouseDown:
            flushDelta()
            send?(.mouseDown(button: 2))
        case .otherMouseUp:
            flushDelta()
            send?(.mouseUp(button: 2))
        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            send?(.scroll(dx: dx, dy: dy))
        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            send?(.key(code: code, down: true, flags: event.flags.wireValue))
        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            send?(.key(code: code, down: false, flags: event.flags.wireValue))
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            send?(.flags(code: code, flags: event.flags.wireValue))
        default:
            break
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(proxy: proxy, type: type, event: event)
}
