import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum EventTapLocalDecision: Equatable {
    case passLocal
    case enterRemoteAndConsume
}

struct EventTapEdgePolicy {
    let reclaimAbsorbWindow: CFAbsoluteTime = 0.5
    let remoteEntryInset: CGFloat = 12
    let remotePinInset: CGFloat = 32
    let reclaimWarpInset: CGFloat = 48

    func entryThreshold(maxX: CGFloat) -> CGFloat {
        maxX - remoteEntryInset
    }

    func remotePinX(maxX: CGFloat) -> CGFloat {
        maxX - remotePinInset
    }

    func reclaimWarpX(maxX: CGFloat) -> CGFloat {
        maxX - reclaimWarpInset
    }

    func shouldEnterRemote(
        now: CFAbsoluteTime,
        reclaimedAt: CFAbsoluteTime,
        x: CGFloat,
        dx: Double,
        isMouseMovement: Bool,
        keyboardShortcut: Bool,
        maxX: CGFloat
    ) -> Bool {
        if keyboardShortcut {
            return true
        }
        if isMouseMovement && now - reclaimedAt < reclaimAbsorbWindow {
            return false
        }
        return isMouseMovement && x >= entryThreshold(maxX: maxX) && dx > 0
    }

    func localDecision(
        now: CFAbsoluteTime,
        reclaimedAt: CFAbsoluteTime,
        x: CGFloat,
        dx: Double,
        isMouseMovement: Bool,
        keyboardShortcut: Bool,
        maxX: CGFloat
    ) -> EventTapLocalDecision {
        shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: x,
            dx: dx,
            isMouseMovement: isMouseMovement,
            keyboardShortcut: keyboardShortcut,
            maxX: maxX
        ) ? .enterRemoteAndConsume : .passLocal
    }
}

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
    var onDiagnosticsEvent: ((String, [String: Any]) -> Void)?
    var throttleRate: ThrottleRate = .hz1000

    var isForwarding: Bool { mode == .remote }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var mode: ControlMode = .local
    private var localCursorSuppressed = false
    private var currentEventStartedAt: UInt64?
    private var reclaimedAt: CFAbsoluteTime = 0
    private var modeChangedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastRecoveryReason: String?
    private var remoteSessionID: UInt64 = 0
    private var activeModifierKeyCodes = Set<UInt16>()
    private var activeMouseButtons = Set<Int>()
    private let edgePolicy = EventTapEdgePolicy()
    private let debugLogging = ProcessInfo.processInfo.environment["NO_BARRIER_MOUSE_EVENTTAP_DEBUG"] == "1"

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
        tapRunLoop = nil
        isConnected = false
        clearPendingDelta()
        restoreLocalCursor()
        setMode(.local, reason: "stop")
    }

    func releaseLocalControl() {
        performOnTapRunLoop {
            self.releaseOnTapThread()
        }
    }

    private func releaseOnTapThread() {
        flushDelta()
        restoreLocalCursor()
        setMode(.local, reason: "releaseLocalControl")
        onForwardingChanged?(false)
    }

    func reclaimLocalControlFromRemote() {
        performOnTapRunLoop {
            self.reclaimOnTapThread()
        }
    }

    func beginTestForwarding(y: Double) {
        performOnTapRunLoop {
            self.enterRemoteControl(at: y)
        }
    }

    private func reclaimOnTapThread() {
        hardResetToLocal(reason: "remote reclaim")
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
            emergencyRecoverOnTapThread(reason: "hotkey")
            onEmergencyOff?()
            return nil
        }

        guard isConnected else {
            return Unmanaged.passRetained(event)
        }

        switch mode {
        case .local:
            if shouldEnterRemote(type: type, event: event) {
                enterRemoteControl(at: event.location.y)
                log("consume event for remote entry type=\(type.rawValue) x=\(event.location.x)")
                return nil
            }

            return Unmanaged.passRetained(event)

        case .remote:
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                sendCaptured(.release)
                releaseOnTapThread()
                let screen = NSScreenFrame.main
                warpLocalCursor(to: CGPoint(x: screen.midX, y: screen.midY), reason: "escape release")
                return nil
            }

            forward(type: type, event: event)
            return nil

        case .reclaiming:
            if isMouseMovement(type) {
                log("consume movement while reclaiming x=\(event.location.x)")
                return nil
            }
            return Unmanaged.passRetained(event)
        }
    }

    private func crossesRightEdge(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged else {
            return false
        }
        return event.location.x >= edgePolicy.entryThreshold(maxX: NSScreenFrame.main.maxX)
    }

    private func shouldEnterRemote(type: CGEventType, event: CGEvent) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        let cooldownAge = now - reclaimedAt
        let threshold = edgePolicy.entryThreshold(maxX: NSScreenFrame.main.maxX)
        if cooldownAge < edgePolicy.reclaimAbsorbWindow {
            if isMouseMovement(type) {
                let dx = event.getDoubleValueField(.mouseEventDeltaX)
                log("shouldEnterRemote=false cooldown passLocal=true age=\(cooldownAge) window=\(edgePolicy.reclaimAbsorbWindow) x=\(event.location.x) dx=\(dx) threshold=\(threshold)")
            }
            return false
        }

        let isMovement = isMouseMovement(type)
        let keyboard = isKeyboardEnterRemote(type: type, event: event)
        let shouldEnter = edgePolicy.shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: event.location.x,
            dx: isMovement ? event.getDoubleValueField(.mouseEventDeltaX) : 0,
            isMouseMovement: isMovement,
            keyboardShortcut: keyboard,
            maxX: NSScreenFrame.main.maxX
        )
        if shouldEnter {
            let dx = isMouseMovement(type) ? event.getDoubleValueField(.mouseEventDeltaX) : 0
            log("shouldEnterRemote=true edge=\(crossesRightEdge(event: event, type: type)) keyboard=\(keyboard) x=\(event.location.x) dx=\(dx) threshold=\(threshold) cooldownAge=\(cooldownAge)")
        }
        return shouldEnter
    }

    private func enterRemoteControl(at y: Double) {
        remoteSessionID &+= 1
        activeModifierKeyCodes.removeAll()
        activeMouseButtons.removeAll()
        setMode(.remote, reason: "enter remote session=\(remoteSessionID)")
        suppressLocalCursor()
        sendCaptured(.enter(y: y))
        onForwardingChanged?(true)
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
        warpLocalCursor(to: CGPoint(x: edgePolicy.remotePinX(maxX: screen.maxX), y: y), reason: "pin at entry")
    }

    private func pinLocalCursor() {
        let screen = NSScreenFrame.main
        warpLocalCursor(to: CGPoint(x: edgePolicy.remotePinX(maxX: screen.maxX), y: pinnedY), reason: "pin while remote")
    }

    private func pinLocalCursorIfNeeded() {
        guard mode == .remote else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCursorPinAt >= cursorPinInterval else { return }
        lastCursorPinAt = now
        pinLocalCursor()
    }

    private func flushDelta() {
        log("flushDelta pending=(\(pendingDelta.x), \(pendingDelta.y))")
        scheduledDeltaFlush?.cancel()
        scheduledDeltaFlush = nil
        sendPendingDelta()
    }

    private func clearPendingDelta() {
        log("clearPendingDelta pending=(\(pendingDelta.x), \(pendingDelta.y))")
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

    private func isMouseMovement(_ type: CGEventType) -> Bool {
        type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
    }

    private func setMode(_ newMode: ControlMode, reason: String) {
        guard mode != newMode else {
            return
        }
        log("mode \(mode) -> \(newMode) reason=\(reason)")
        mode = newMode
        modeChangedAt = CFAbsoluteTimeGetCurrent()
        emitDiagnosticsEvent("modeChanged", extra: ["reason": reason])
    }

    private func warpLocalCursor(to point: CGPoint, reason: String) {
        log("warp reason=\(reason) x=\(point.x) y=\(point.y) entryThreshold=\(edgePolicy.entryThreshold(maxX: NSScreenFrame.main.maxX))")
        CGWarpMouseCursorPosition(point)
    }

    private func log(_ message: String) {
        guard debugLogging else {
            return
        }
        NSLog("[NoBarrierMouse.EventTap] %@", message)
    }

    func diagnosticsSnapshot() -> [String: Any] {
        let screen = NSScreenFrame.main
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let now = CFAbsoluteTimeGetCurrent()
        return [
            "mode": "\(mode)",
            "isForwarding": isForwarding,
            "isConnected": isConnected,
            "remoteSessionID": remoteSessionID,
            "localCursorSuppressed": localCursorSuppressed,
            "cursorX": cursor.x,
            "cursorY": cursor.y,
            "screenMaxX": screen.maxX,
            "entryThresholdX": edgePolicy.entryThreshold(maxX: screen.maxX),
            "remotePinX": edgePolicy.remotePinX(maxX: screen.maxX),
            "reclaimWarpX": edgePolicy.reclaimWarpX(maxX: screen.maxX),
            "pinnedY": pinnedY,
            "pendingDeltaX": pendingDelta.x,
            "pendingDeltaY": pendingDelta.y,
            "scheduledDeltaFlushExists": scheduledDeltaFlush != nil,
            "reclaimedAt": reclaimedAt,
            "reclaimedAgeSeconds": now - reclaimedAt,
            "activeModifierKeyCodes": activeModifierKeyCodes.sorted(),
            "activeMouseButtons": activeMouseButtons.sorted(),
            "modeAgeSeconds": now - modeChangedAt,
            "lastRecoveryReason": lastRecoveryReason ?? NSNull()
        ]
    }

    func emergencyRecover(reason: String) {
        performOnTapRunLoop {
            self.emergencyRecoverOnTapThread(reason: reason)
        }
    }

    private func emergencyRecoverOnTapThread(reason: String) {
        lastRecoveryReason = reason
        hardResetToLocal(reason: "emergency recovery: \(reason)", warpToCenter: true)
        emitDiagnosticsEvent("emergencyRecovery", extra: ["reason": reason])
    }

    private func hardResetToLocal(reason: String, warpToCenter: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        setMode(.reclaiming, reason: "hard reset start: \(reason)")
        scheduledDeltaFlush?.cancel()
        scheduledDeltaFlush = nil
        pendingDelta = .zero
        pendingDeltaStartedAt = nil
        lastDeltaSend = now
        lastCursorPinAt = 0
        activeModifierKeyCodes.removeAll()
        activeMouseButtons.removeAll()
        reclaimedAt = now
        restoreLocalCursor()

        let screen = NSScreenFrame.main
        let x = warpToCenter ? screen.midX : edgePolicy.reclaimWarpX(maxX: screen.maxX)
        let y = warpToCenter ? screen.midY : pinnedY
        warpLocalCursor(to: CGPoint(x: x, y: y), reason: reason)
        setMode(.local, reason: "hard reset complete: \(reason)")
        onForwardingChanged?(false)
        emitDiagnosticsEvent("hardReclaim", extra: ["reason": reason])
    }

    private func emitDiagnosticsEvent(_ name: String, extra: [String: Any] = [:]) {
        var payload = diagnosticsSnapshot()
        payload["event"] = name
        for (key, value) in extra {
            payload[key] = value
        }
        onDiagnosticsEvent?(name, payload)
    }

    private func forward(type: CGEventType, event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            log("consume remote movement x=\(event.location.x) dx=\(dx) dy=\(dy) mode=\(mode)")
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
            activeMouseButtons.insert(0)
            sendCaptured(.mouseDown(button: 0))
        case .leftMouseUp:
            flushDelta()
            activeMouseButtons.remove(0)
            sendCaptured(.mouseUp(button: 0))
        case .rightMouseDown:
            flushDelta()
            activeMouseButtons.insert(1)
            sendCaptured(.mouseDown(button: 1))
        case .rightMouseUp:
            flushDelta()
            activeMouseButtons.remove(1)
            sendCaptured(.mouseUp(button: 1))
        case .otherMouseDown:
            flushDelta()
            activeMouseButtons.insert(2)
            sendCaptured(.mouseDown(button: 2))
        case .otherMouseUp:
            flushDelta()
            activeMouseButtons.remove(2)
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
            updateTrackedModifiers(code: code, flags: event.flags)
            sendCaptured(.flags(code: code, flags: event.flags.wireValue))
        default:
            break
        }
    }

    private func updateTrackedModifiers(code: UInt16, flags: CGEventFlags) {
        let modifierKeys: [UInt16: CGEventFlags] = [
            54: .maskCommand,
            55: .maskCommand,
            58: .maskAlternate,
            61: .maskAlternate,
            59: .maskControl,
            62: .maskControl,
            56: .maskShift,
            60: .maskShift,
            63: .maskSecondaryFn
        ]
        guard let flag = modifierKeys[code] else { return }
        if flags.contains(flag) {
            activeModifierKeyCodes.insert(code)
        } else {
            activeModifierKeyCodes.remove(code)
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
