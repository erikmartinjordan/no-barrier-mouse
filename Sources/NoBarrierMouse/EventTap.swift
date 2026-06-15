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

final class EventTap {
    var isForwarding: Bool { mode == .remote }
    var isConnected = false
    var send: ((WireMessage) -> Void)?
    var onForwardingChanged: ((Bool) -> Void)?
    var onEmergencyOff: (() -> Void)?
    var onCaptureFailed: (() -> Void)?
    var throttleRate: ThrottleRate = .hz1000

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var localCursorSuppressed = false
    private var currentEventStartedAt: UInt64?
    private var handlingTapEvent = false

    private enum ControlMode: String {
        case local
        case remote
        case reclaiming
    }

    private var mode: ControlMode = .local {
        didSet {
            guard oldValue != mode else { return }
            log("mode \(oldValue.rawValue) -> \(mode.rawValue)")
        }
    }

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

        guard let tap = tap else {
            onCaptureFailed?()
            return false
        }
        let runLoop = CFRunLoopGetCurrent()
        tapRunLoop = runLoop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        mode = .local
        isConnected = false
        clearPendingDelta()
        restoreLocalCursor()
    }

    func releaseLocalControl() {
        performOnTapRunLoop { [weak self] in
            self?.releaseLocalControlOnTapThread()
        }
    }

    private func releaseLocalControlOnTapThread() {
        mode = .local
        flushDelta()
        restoreLocalCursor()
        notifyForwardingChanged(false)
    }

    func reclaimLocalControlFromRemote() {
        performOnTapRunLoop { [weak self] in
            self?.reclaimOnTapThread()
        }
    }

    private func reclaimOnTapThread() {
        log("reclaim begin pending=(\(pendingDelta.x),\(pendingDelta.y))")
        clearPendingDelta()
        mode = .reclaiming

        let screen = NSScreenFrame.main
        let point = CGPoint(x: screen.maxX - reclaimInset, y: screen.midY)
        log("warp reclaim x=\(point.x) maxX=\(screen.maxX) inset=\(reclaimInset)")
        CGWarpMouseCursorPosition(point)
        restoreLocalCursor()
        reclaimedAt = CFAbsoluteTimeGetCurrent()
        mode = .local
        notifyForwardingChanged(false)
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        handlingTapEvent = true
        defer { handlingTapEvent = false }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        currentEventStartedAt = InputMetrics.nowTicks()
        defer { currentEventStartedAt = nil }

        if isEmergencyRelease(type: type, event: event) {
            sendCaptured(.release)
            releaseLocalControlOnTapThread()
            onEmergencyOff?()
            logNil(type: type, event: event, reason: "emergency release")
            return nil
        }

        guard isConnected else {
            return Unmanaged.passRetained(event)
        }

        if mode == .local, shouldEnterRemote(type: type, event: event) {
            enterRemoteControl(at: Double(event.location.y))
            logNil(type: type, event: event, reason: "enter remote")
            return nil
        }

        guard mode == .remote else {
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            sendCaptured(.release)
            releaseLocalControlOnTapThread()
            let screen = NSScreenFrame.main
            let point = CGPoint(x: screen.midX, y: screen.midY)
            log("warp escape x=\(point.x) y=\(point.y)")
            CGWarpMouseCursorPosition(point)
            logNil(type: type, event: event, reason: "remote escape")
            return nil
        }

        forward(type: type, event: event)
        logNil(type: type, event: event, reason: "forward remote")
        return nil
    }

    private func crossesRightEdge(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged else {
            return false
        }
        return event.location.x >= NSScreenFrame.main.maxX - remoteEntryInset
    }

    private func shouldEnterRemote(type: CGEventType, event: CGEvent) -> Bool {
        let edgeThreshold = NSScreenFrame.main.maxX - remoteEntryInset
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let sinceReclaim = reclaimedAt.map { CFAbsoluteTimeGetCurrent() - $0 }
        let crossesEdge = crossesRightEdge(event: event, type: type)
        let keyboardEnter = isKeyboardEnterRemote(type: type, event: event)
        let inCooldown = sinceReclaim.map { $0 < reclaimAbsorbWindow } ?? false
        let shouldEnter = (crossesEdge || keyboardEnter) && !inCooldown

        if crossesEdge || keyboardEnter || inCooldown {
            let deltaDescription = sinceReclaim.map { String(format: "%.4f", $0) } ?? "nil"
            log("shouldEnterRemote=\(shouldEnter) mode=\(mode.rawValue) x=\(event.location.x) dx=\(dx) threshold=\(edgeThreshold) sinceReclaim=\(deltaDescription) cooldown=\(reclaimAbsorbWindow) crossesEdge=\(crossesEdge) keyboard=\(keyboardEnter)")
        }

        return shouldEnter
    }

    private func enterRemoteControl(at y: Double) {
        mode = .remote
        suppressLocalCursor()
        sendCaptured(.enter(y: y))
        notifyForwardingChanged(true)
        pinLocalCursor(at: y)
    }

    private func suppressLocalCursor() {
        guard !localCursorSuppressed else { return }
        log("CGAssociateMouseAndMouseCursorPosition(0)")
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)
        localCursorSuppressed = true
    }

    private func restoreLocalCursor() {
        guard localCursorSuppressed else { return }
        log("CGAssociateMouseAndMouseCursorPosition(1)")
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        localCursorSuppressed = false
    }

    private func pinLocalCursor(at y: Double) {
        pinnedY = y
        let screen = NSScreenFrame.main
        let point = CGPoint(x: screen.maxX - remotePinInset, y: CGFloat(y))
        log("warp pin x=\(point.x) y=\(point.y) maxX=\(screen.maxX) pinInset=\(remotePinInset) entryInset=\(remoteEntryInset)")
        CGWarpMouseCursorPosition(point)
    }

    private func pinLocalCursor() {
        let screen = NSScreenFrame.main
        let point = CGPoint(x: screen.maxX - remotePinInset, y: CGFloat(pinnedY))
        log("warp re-pin x=\(point.x) y=\(point.y) maxX=\(screen.maxX) pinInset=\(remotePinInset) entryInset=\(remoteEntryInset)")
        CGWarpMouseCursorPosition(point)
    }

    private func pinLocalCursorIfNeeded() {
        guard localCursorSuppressed else { return }
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
        send?(.mouseDelta(dx: Double(pendingDelta.x), dy: Double(pendingDelta.y), button: nil))
        pendingDelta = .zero
        pendingDeltaStartedAt = nil
        lastDeltaSend = CFAbsoluteTimeGetCurrent()
    }

    private func scheduleDeltaFlush(after delay: TimeInterval) {
        guard scheduledDeltaFlush == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.performOnTapRunLoop {
                self?.scheduledDeltaFlush = nil
                self?.sendPendingDelta()
            }
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
    private let remoteEntryInset: CGFloat = 12
    private let remotePinInset: CGFloat = 32
    private let reclaimInset: CGFloat = 48
    private let reclaimAbsorbWindow: TimeInterval = 0.25
    private var reclaimedAt: CFAbsoluteTime?

    private func sendCaptured(_ message: WireMessage) {
        if let startedAt = currentEventStartedAt {
            InputMetrics.shared.record(.hidCapture, from: startedAt)
        }
        send?(message)
    }

    private func forward(type: CGEventType, event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
            let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
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

    private func performOnTapRunLoop(_ block: @escaping () -> Void) {
        if handlingTapEvent {
            block()
            return
        }

        guard let tapRunLoop = tapRunLoop else {
            block()
            return
        }

        CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(tapRunLoop)
    }

    private func notifyForwardingChanged(_ forwarding: Bool) {
        DispatchQueue.main.async { [onForwardingChanged] in
            onForwardingChanged?(forwarding)
        }
    }

    private func logNil(type: CGEventType, event: CGEvent, reason: String) {
        guard type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged || type == .keyDown else { return }
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let sinceReclaim = reclaimedAt.map { String(format: "%.4f", CFAbsoluteTimeGetCurrent() - $0) } ?? "nil"
        log("return nil reason=\(reason) type=\(type.rawValue) x=\(event.location.x) dx=\(dx) mode=\(mode.rawValue) sinceReclaim=\(sinceReclaim) entryThreshold=\(NSScreenFrame.main.maxX - remoteEntryInset)")
    }

    private func log(_ message: String) {
        NSLog("[NoBarrierMouse EventTap] \(message)")
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(proxy: proxy, type: type, event: event)
}

enum NSScreenFrame {
    static var main: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
