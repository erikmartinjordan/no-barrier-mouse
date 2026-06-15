import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum ThrottleRate: Double, CaseIterable {
    case immediate = 0
    case hz1000 = 0.001
    case hz500 = 0.002
    case hz250 = 0.004
}

private enum ControlMode {
    case local
    case remote
    case reclaiming
}

final class EventTap {
    var isConnected = false
    var send: ((WireMessage) -> Void)?
    var onForwardingChanged: ((Bool) -> Void)?
    var onEmergencyOff: (() -> Void)?
    var onCaptureFailed: (() -> Void)?
    var throttleRate: ThrottleRate = .hz1000

    var isForwarding: Bool { mode == .remote }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var mode: ControlMode = .local
    private var currentEventStartedAt: UInt64?
    private var reclaimedAt: CFAbsoluteTime = 0
    private let reclaimAbsorbWindow: CFAbsoluteTime = 0.2

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = Self.eventMask(for: [
            .keyDown,
            .keyUp,
            .flagsChanged,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel
        ])

        let ref = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: ref
        )

        guard let tap else {
            onCaptureFailed?()
            return false
        }
        tapRunLoop = CFRunLoopGetCurrent()
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }

    func stop() {
        performOnTapRunLoop {
            self.stopOnTapThread()
        }
    }

    private func stopOnTapThread() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isConnected = false
        clearPendingDelta()
        restoreLocalCursor()
        mode = .local
    }

    func releaseLocalControl() {
        performOnTapRunLoop {
            self.releaseOnTapThread()
        }
    }

    private func releaseOnTapThread() {
        flushDelta()
        restoreLocalCursor()
        mode = .local
        onForwardingChanged?(false)
    }

    func reclaimLocalControlFromRemote() {
        performOnTapRunLoop {
            self.reclaimOnTapThread()
        }
    }

    private func reclaimOnTapThread() {
        clearPendingDelta()
        mode = .reclaiming
        reclaimedAt = CFAbsoluteTimeGetCurrent()

        let screen = NSScreenFrame.main
        CGWarpMouseCursorPosition(CGPoint(x: screen.maxX - 24, y: pinnedY))
        restoreLocalCursor()

        mode = .local
        onForwardingChanged?(false)
    }

    private func performOnTapRunLoop(_ block: @escaping () -> Void) {
        if let tapRunLoop {
            CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(tapRunLoop)
        } else {
            block()
        }
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        currentEventStartedAt = InputMetrics.nowTicks()
        defer { currentEventStartedAt = nil }

        if isEmergencyRelease(type: type, event: event) {
            sendCaptured(.release)
            releaseOnTapThread()
            onEmergencyOff?()
            return nil
        }

        guard isConnected else {
            return Unmanaged.passRetained(event)
        }

        switch mode {
        case .local:
            if CFAbsoluteTimeGetCurrent() - reclaimedAt < reclaimAbsorbWindow {
                let isMouseMovement = type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
                if isMouseMovement, event.location.x > NSScreenFrame.main.maxX - 20 {
                    return nil
                }
            }

            if shouldEnterRemote(type: type, event: event) {
                enterRemoteControl(at: event.location.y)
                return nil
            }

            return Unmanaged.passRetained(event)

        case .remote:
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                sendCaptured(.release)
                releaseOnTapThread()
                let screen = NSScreenFrame.main
                CGWarpMouseCursorPosition(CGPoint(x: screen.midX, y: screen.midY))
                return nil
            }

            forward(type: type, event: event)
            return nil

        case .reclaiming:
            let isMouseMovement = type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
            if isMouseMovement {
                return nil
            }
            return Unmanaged.passRetained(event)
        }
    }

    private func crossesRightEdge(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged else {
            return false
        }
        return event.location.x >= NSScreenFrame.main.maxX - 12
    }

    private func shouldEnterRemote(type: CGEventType, event: CGEvent) -> Bool {
        if CFAbsoluteTimeGetCurrent() - reclaimedAt < reclaimAbsorbWindow {
            return false
        }
        return crossesRightEdge(event: event, type: type) || isKeyboardEnterRemote(type: type, event: event)
    }

    private func enterRemoteControl(at y: Double) {
        suppressLocalCursor()
        sendCaptured(.enter(y: y))
        onForwardingChanged?(true)
        mode = .remote
        pinLocalCursor(at: y)
    }

    private func suppressLocalCursor() {
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func restoreLocalCursor() {
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
    }

    private func pinLocalCursor(at y: Double) {
        pinnedY = y
        let screen = NSScreenFrame.main
        CGWarpMouseCursorPosition(CGPoint(x: screen.maxX - 8, y: y))
    }

    private func pinLocalCursor() {
        let screen = NSScreenFrame.main
        CGWarpMouseCursorPosition(CGPoint(x: screen.maxX - 8, y: pinnedY))
    }

    private func pinLocalCursorIfNeeded() {
        guard mode == .remote else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCursorPinAt >= cursorPinInterval else { return }
        lastCursorPinAt = now
        pinLocalCursor()
    }

    private func flushDelta() {
        scheduledDeltaFlush?.cancel()
        scheduledDeltaFlush = nil
        sendPendingDelta()
    }

    private func clearPendingDelta() {
        scheduledDeltaFlush?.cancel()
        scheduledDeltaFlush = nil
        pendingDelta = .zero
        pendingDeltaStartedAt = nil
    }

    private func sendPendingDelta() {
        guard pendingDelta.x != 0 || pendingDelta.y != 0 else { return }
        if let startedAt = pendingDeltaStartedAt {
            InputMetrics.shared.record(.hidCapture, from: startedAt)
        }
        send?(.mouseDelta(dx: pendingDelta.x, dy: pendingDelta.y, button: nil))
        pendingDelta = .zero
        pendingDeltaStartedAt = nil
        lastDeltaSend = CFAbsoluteTimeGetCurrent()
    }

    private func scheduleDeltaFlush(after delay: TimeInterval) {
        guard scheduledDeltaFlush == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduledDeltaFlush = nil
            self?.sendPendingDelta()
        }
        scheduledDeltaFlush = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
    private var pendingDeltaStartedAt: UInt64?
    private var lastDeltaSend = CFAbsoluteTime(0)
    private var scheduledDeltaFlush: DispatchWorkItem?
    private var deltaThrottle: TimeInterval { throttleRate.rawValue }
    private var pinnedY: Double = 0
    private var lastCursorPinAt = CFAbsoluteTime(0)
    private let cursorPinInterval = 1.0 / 120.0

    private func sendCaptured(_ message: WireMessage) {
        if let startedAt = currentEventStartedAt {
            InputMetrics.shared.record(.hidCapture, from: startedAt)
        }
        send?(message)
    }

    private func forward(type: CGEventType, event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if dx != 0 || dy != 0 {
                if pendingDelta.x == 0 && pendingDelta.y == 0 {
                    pendingDeltaStartedAt = currentEventStartedAt
                }
                pendingDelta.x += dx
                pendingDelta.y += dy

                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastDeltaSend
                if elapsed >= deltaThrottle {
                    scheduledDeltaFlush?.cancel()
                    scheduledDeltaFlush = nil
                    sendPendingDelta()
                } else {
                    scheduleDeltaFlush(after: deltaThrottle - elapsed)
                }
            }
            pinLocalCursorIfNeeded()
        case .leftMouseDown:
            flushDelta()
            sendCaptured(.mouseDown(button: 0))
        case .leftMouseUp:
            flushDelta()
            sendCaptured(.mouseUp(button: 0))
        case .rightMouseDown:
            flushDelta()
            sendCaptured(.mouseDown(button: 1))
        case .rightMouseUp:
            flushDelta()
            sendCaptured(.mouseUp(button: 1))
        case .otherMouseDown:
            flushDelta()
            sendCaptured(.mouseDown(button: 2))
        case .otherMouseUp:
            flushDelta()
            sendCaptured(.mouseUp(button: 2))
        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            sendCaptured(.scroll(dx: dx, dy: dy))
        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            sendCaptured(.key(code: code, down: true, flags: event.flags.wireValue))
        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            sendCaptured(.key(code: code, down: false, flags: event.flags.wireValue))
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            sendCaptured(.flags(code: code, flags: event.flags.wireValue))
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

enum NSScreenFrame {
    static var main: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
