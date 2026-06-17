import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum EventTapLocalDecision: Equatable {
    case passLocal
    case enterRemoteAndConsume
}

struct EventTapEdgePolicy {
    let reclaimAbsorbWindow: CFAbsoluteTime = 0.0 // DELIVERY FIX: no post-reclaim event absorption
    let remoteEntryInset: CGFloat = 12
    let remotePinInset: CGFloat = 2
    let reclaimWarpInset: CGFloat = 24 // normal seam inset

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
        isMouseMovement: Bool,
        keyboardShortcut: Bool,
        maxX: CGFloat
    ) -> Bool {
        if now - reclaimedAt < reclaimAbsorbWindow {
            return false
        }
        return (isMouseMovement && x >= entryThreshold(maxX: maxX)) || keyboardShortcut
    }

    func localDecision(
        now: CFAbsoluteTime,
        reclaimedAt: CFAbsoluteTime,
        x: CGFloat,
        isMouseMovement: Bool,
        keyboardShortcut: Bool,
        maxX: CGFloat
    ) -> EventTapLocalDecision {
        shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: x,
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
    case reclaimingLocal
    case localCooldown
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
    private var activeHandoffID: UInt64?
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

    func reclaimLocalControlFromRemote(y: Double? = nil, carryDx: Double = 0, carryDy: Double = 0, handoffID: UInt64? = nil, completion: (() -> Void)? = nil) {
        performOnTapRunLoop {
            self.reclaimOnTapThread(y: y, carryDx: carryDx, carryDy: carryDy, handoffID: handoffID)
            completion?()
        }
    }

    func applyReturnControlDelta(handoffID: UInt64, dx: Double, dy: Double) {
        performOnTapRunLoop {
            guard self.activeHandoffID == handoffID else {
                self.log("stale returnControlDelta ignored handoffID=\(handoffID) active=\(String(describing: self.activeHandoffID))")
                return
            }
            let current = CGEvent(source: nil)?.location ?? CGPoint(x: NSScreenFrame.main.midX, y: NSScreenFrame.main.midY)
            let final = self.clampLocalPoint(CGPoint(x: current.x + dx, y: current.y + dy))
            self.log("apply late delta handoffID=\(handoffID) dx=\(dx) dy=\(dy) final=(\(final.x),\(final.y))")
            self.warpLocalCursor(to: final, reason: "returnControlDelta")
        }
    }

    func beginTestForwarding(y: Double) {
        performOnTapRunLoop {
            self.enterRemoteControl(at: y)
        }
    }

    private func reclaimOnTapThread(y: Double?, carryDx: Double, carryDy: Double, handoffID: UInt64?) {
        // Do not flush these deltas back to the receiver during return handoff.
        // At this point the receiver has already crossed the seam, so pending physical
        // mouse movement belongs on the controller side.
        let pendingCarryX = pendingDelta.x
        let pendingCarryY = pendingDelta.y
        clearPendingDelta()

        setMode(.reclaimingLocal, reason: "reclaim start")
        activeHandoffID = handoffID
        reclaimedAt = CFAbsoluteTimeGetCurrent()

        let screen = NSScreenFrame.main
        let restoreY = y ?? pinnedY

        // DELIVERY FIX: restore cursor after warp, not before.

        // Normal return should anchor at the iMac right seam, not 180 px inside.
        // Re-entry prevention is handled by localCooldown/shouldEnterRemote, not geometry.
        let seamStart = CGPoint(x: edgePolicy.reclaimWarpX(maxX: screen.maxX), y: restoreY)
        let final = clampLocalPoint(CGPoint(
            x: seamStart.x + CGFloat(carryDx) + pendingCarryX,
            y: seamStart.y + CGFloat(carryDy) + pendingCarryY
        ))

        log("returnControl received handoffID=\(String(describing: handoffID)) y=\(restoreY) carry=(\(carryDx),\(carryDy)) pendingCarry=(\(pendingCarryX),\(pendingCarryY)) final=(\(final.x),\(final.y))")
        warpLocalCursor(to: final, reason: "reclaim seam carry")

        // DELIVERY FIX:
        // We land far inside the iMac, so we do not need localCooldown here.
        // localCooldown creates a visible pause after reclaim.
        setMode(.local, reason: "reclaim complete")
        restoreLocalCursor()
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
            emergencyRecoverOnTapThread(reason: "hotkey")
            onEmergencyOff?()
            return nil
        }

        guard isConnected else {
            return Unmanaged.passRetained(event)
        }

        switch mode {
        case .local, .localCooldown:
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

        case .reclaimingLocal:
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
        if mode == .localCooldown {
            return false
        }
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

        if isMovement {
            let dx = event.getDoubleValueField(.mouseEventDeltaX)

            // Being near the hot edge is not enough.
            // Only enter the receiver when the user is actually moving right.
            // This prevents the "bounce back into MacBook" when returning to the iMac
            // and then continuing to move left.
            if dx <= 0 {
                log("shouldEnterRemote=false moving-away-from-edge x=\(event.location.x) dx=\(dx) threshold=\(threshold)")
                return false
            }
        }

        let shouldEnter = edgePolicy.shouldEnterRemote(
            now: now,
            reclaimedAt: reclaimedAt,
            x: event.location.x,
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
        setMode(.remote, reason: "enter remote")
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

    private func clampLocalPoint(_ point: CGPoint) -> CGPoint {
        let screen = NSScreenFrame.main
        return CGPoint(
            x: min(max(point.x, screen.minX + 1), screen.maxX - 2),
            y: min(max(point.y, screen.minY + 1), screen.maxY - 2)
        )
    }

    private func scheduleCooldownExit() {
        let handoffID = activeHandoffID
        DispatchQueue.main.asyncAfter(deadline: .now() + edgePolicy.reclaimAbsorbWindow) { [weak self] in
            self?.performOnTapRunLoop {
                guard let self, self.mode == .localCooldown, self.activeHandoffID == handoffID else { return }
                self.log("exiting localCooldown handoffID=\(String(describing: handoffID))")
                self.activeHandoffID = nil
                self.setMode(.local, reason: "localCooldown expired")
            }
        }
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
            "reclaimedAgeSeconds": now - reclaimedAt,
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
        clearPendingDelta()
        activeHandoffID = nil
        restoreLocalCursor()
        setMode(.local, reason: "emergency recovery: \(reason)")
        let screen = NSScreenFrame.main
        warpLocalCursor(to: CGPoint(x: screen.midX, y: screen.midY), reason: "emergency recovery")
        emitDiagnosticsEvent("emergencyRecovery", extra: ["reason": reason])
        onForwardingChanged?(false)
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
