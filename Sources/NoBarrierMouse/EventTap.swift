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
    case localSyntheticHandoff
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
    private var associateSuppressed = false
    private var cursorHidden = false
    private var currentEventStartedAt: UInt64?
    private var reclaimedAt: CFAbsoluteTime = 0
    private var modeChangedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastRecoveryReason: String?
    private var activeHandoffID: UInt64?
    private let edgePolicy = EventTapEdgePolicy()
    private let debugLogging = ProcessInfo.processInfo.environment["NO_BARRIER_MOUSE_EVENTTAP_DEBUG"] == "1"

    // Synthetic handoff constants
    private let syntheticHandoffGain: CGFloat = 0.45
    private let syntheticHandoffMaxDelta: CGFloat = 80
    private let syntheticHandoffMaxDuration: TimeInterval = 0.20
    private let syntheticHandoffQuietDuration: TimeInterval = 0.05
    private let syntheticHandoffQuietDelta: CGFloat = 8
    private let syntheticHandoffMaxEvents: Int = 25

    private var syntheticHandoffPoint: CGPoint?
    private var syntheticHandoffStartedAt: CFAbsoluteTime = 0
    private var syntheticHandoffLastMovementAt: CFAbsoluteTime = 0
    private var syntheticHandoffEventCount: Int = 0
    private var syntheticHandoffQuietCount: Int = 0
    private var syntheticHandoffTimer: DispatchWorkItem?
    private var localEventLogCount: Int = 0

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
        clearSyntheticHandoffState(reason: "stop")
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
        clearSyntheticHandoffState(reason: "releaseLocalControl")
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
        let tStart = CFAbsoluteTimeGetCurrent()
        NSLog("[NoBarrierMouse.Reclaim] reclaimStart handoffID=\(handoffID ?? 0)")

        // Do not flush these deltas back to the receiver during return handoff.
        // At this point the receiver has already crossed the seam, so pending physical
        // mouse movement belongs on the controller side.
        let pendingCarryX = pendingDelta.x
        let pendingCarryY = pendingDelta.y
        clearPendingDelta()

        let t1 = CFAbsoluteTimeGetCurrent()
        NSLog("[NoBarrierMouse.Reclaim] pendingDelta dur=\((t1-tStart)*1000)")

        setMode(.reclaimingLocal, reason: "reclaim start")
        activeHandoffID = handoffID
        reclaimedAt = CFAbsoluteTimeGetCurrent()

        let t2 = CFAbsoluteTimeGetCurrent()
        NSLog("[NoBarrierMouse.Reclaim] setModeReclaiming dur=\((t2-t1)*1000)")

        let screen = NSScreenFrame.main
        let restoreY = y ?? pinnedY

        let seamStart = CGPoint(x: edgePolicy.reclaimWarpX(maxX: screen.maxX), y: restoreY)
        let final = clampLocalPoint(CGPoint(
            x: seamStart.x + CGFloat(carryDx) + pendingCarryX,
            y: seamStart.y + CGFloat(carryDy) + pendingCarryY
        ))

        let t3 = CFAbsoluteTimeGetCurrent()
        NSLog("[NoBarrierMouse.Reclaim] calcPoints dur=\((t3-t2)*1000)")

        log("returnControl received handoffID=\(String(describing: handoffID)) y=\(restoreY) carry=(\(carryDx),\(carryDy)) pendingCarry=(\(pendingCarryX),\(pendingCarryY)) final=(\(final.x),\(final.y))")
        warpLocalCursor(to: final, reason: "reclaim seam carry")

        let t4 = CFAbsoluteTimeGetCurrent()
        NSLog("[NoBarrierMouse.Reclaim] warp dur=\((t4-t3)*1000)")

        // Enter synthetic handoff: cursor hidden+disassociated from .remote mode.
        // Show cursor so user can see it, but keep CGAssociate(0) active.
        setMode(.localSyntheticHandoff, reason: "reclaim complete")
        showCursorIfNeeded()
        localEventLogCount = 0
        let now = CFAbsoluteTimeGetCurrent()
        syntheticHandoffPoint = final
        syntheticHandoffStartedAt = now
        syntheticHandoffLastMovementAt = now
        syntheticHandoffEventCount = 0
        syntheticHandoffQuietCount = 0

        // Schedule forced exit timer so we never get stuck in handoff.
        let timer = DispatchWorkItem { [weak self] in
            self?.performOnTapRunLoop {
                self?.exitSyntheticHandoff(reason: "timerMaxTime")
            }
        }
        syntheticHandoffTimer?.cancel()
        syntheticHandoffTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + syntheticHandoffMaxDuration, execute: timer)

        NSLog("[NoBarrierMouse.Handoff] entry point=(\(final.x),\(final.y)) maxDuration=\(syntheticHandoffMaxDuration)")

        onForwardingChanged?(false)

        let t5 = CFAbsoluteTimeGetCurrent()
        NSLog("[NoBarrierMouse.Reclaim] onForwardingChanged dur=\((t5-t4)*1000)")
        NSLog("[NoBarrierMouse.Reclaim] reclaimTotal ms=\((t5-tStart)*1000)")
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
        case .localSyntheticHandoff:
            if handleSyntheticHandoff(type: type, event: event) {
                return nil
            }
            if mode == .localSyntheticHandoff {
                exitSyntheticHandoff(reason: "interrupted by \(type)")
            }
            if mode == .local, shouldEnterRemote(type: type, event: event) {
                enterRemoteControl(at: event.location.y)
                log("consume event for remote entry type=\(type.rawValue) x=\(event.location.x)")
                return nil
            }
            return Unmanaged.passRetained(event)

        case .local, .localCooldown:
            if shouldEnterRemote(type: type, event: event) {
                enterRemoteControl(at: event.location.y)
                log("consume event for remote entry type=\(type.rawValue) x=\(event.location.x)")
                return nil
            }

            if isMouseMovement(type) && localEventLogCount < 10 {
                localEventLogCount += 1
                let cursor = CGEvent(source: nil)?.location ?? .zero
                NSLog("[NoBarrierMouse.LocalEvent] localEvent_\(localEventLogCount) type=\(type.rawValue) eventX=\(event.location.x) eventY=\(event.location.y) dx=\(event.getDoubleValueField(.mouseEventDeltaX)) dy=\(event.getDoubleValueField(.mouseEventDeltaY)) cursorX=\(cursor.x) cursorY=\(cursor.y)")
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
        guard !associateSuppressed else { return }
        log("CGAssociateMouseAndMouseCursorPosition(0)")
        hideCursorIfNeeded()
        CGAssociateMouseAndMouseCursorPosition(0)
        associateSuppressed = true
    }

    private func restoreLocalCursor() {
        guard associateSuppressed else { return }
        log("CGAssociateMouseAndMouseCursorPosition(1)")
        CGAssociateMouseAndMouseCursorPosition(1)
        showCursorIfNeeded()
        associateSuppressed = false
    }

    private func showCursorIfNeeded() {
        guard cursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        cursorHidden = false
    }

    private func hideCursorIfNeeded() {
        guard !cursorHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHidden = true
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

    private func handleSyntheticHandoff(type: CGEventType, event: CGEvent) -> Bool {
        // Only bridge .mouseMoved; drag/click exit handoff cleanly.
        guard type == .mouseMoved else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        let age = now - syntheticHandoffStartedAt

        if age > syntheticHandoffMaxDuration {
            exitSyntheticHandoff(reason: "maxTime", age: age)
            return false
        }

        let rawDx = event.getDoubleValueField(.mouseEventDeltaX)
        let rawDy = event.getDoubleValueField(.mouseEventDeltaY)
        guard let point = syntheticHandoffPoint else {
            exitSyntheticHandoff(reason: "noPoint", age: age)
            return false
        }

        syntheticHandoffEventCount += 1

        if syntheticHandoffEventCount > syntheticHandoffMaxEvents {
            exitSyntheticHandoff(reason: "maxEvents", age: age)
            return false
        }

        if rawDx == 0 && rawDy == 0 {
            let quietDuration = now - syntheticHandoffLastMovementAt
            if quietDuration > syntheticHandoffQuietDuration {
                exitSyntheticHandoff(reason: "timeQuiet", age: age)
                return false
            }
            return true
        }

        syntheticHandoffLastMovementAt = now

        if abs(rawDx) < syntheticHandoffQuietDelta && abs(rawDy) < syntheticHandoffQuietDelta {
            syntheticHandoffQuietCount += 1
            if syntheticHandoffQuietCount >= 2 {
                exitSyntheticHandoff(reason: "quiet", age: age)
                return false
            }
        } else {
            syntheticHandoffQuietCount = 0
        }

        var dx = CGFloat(rawDx) * syntheticHandoffGain
        var dy = CGFloat(rawDy) * syntheticHandoffGain
        dx = max(-syntheticHandoffMaxDelta, min(syntheticHandoffMaxDelta, dx))
        dy = max(-syntheticHandoffMaxDelta, min(syntheticHandoffMaxDelta, dy))
        let next = clampLocalPoint(CGPoint(x: point.x + dx, y: point.y + dy))
        let realCursor = CGEvent(source: nil)?.location ?? .zero
        NSLog("[NoBarrierMouse.Handoff] move count=\(syntheticHandoffEventCount) rawDx=\(rawDx) rawDy=\(rawDy) dx=\(dx) dy=\(dy) from=(\(point.x),\(point.y)) to=(\(next.x),\(next.y)) event=(\(event.location.x),\(event.location.y)) realCursor=(\(realCursor.x),\(realCursor.y))")
        warpLocalCursor(to: next, reason: "local synthetic handoff")
        syntheticHandoffPoint = next
        return true
    }

    private func exitSyntheticHandoff(reason: String, age: CFAbsoluteTime? = nil) {
        guard mode == .localSyntheticHandoff else { return }
        syntheticHandoffTimer?.cancel()
        syntheticHandoffTimer = nil
        let point = syntheticHandoffPoint ?? CGPoint(x: NSScreenFrame.main.midX, y: NSScreenFrame.main.midY)
        let realBefore = CGEvent(source: nil)?.location ?? .zero
        NSLog("[NoBarrierMouse.Handoff] exit reason=\(reason) age=\(age ?? 0) point=(\(point.x),\(point.y)) realCursorBeforeRestore=(\(realBefore.x),\(realBefore.y))")
        warpLocalCursor(to: point, reason: "synthetic handoff final anchor before restore")
        restoreLocalCursor()
        let realAfter = CGEvent(source: nil)?.location ?? .zero
        NSLog("[NoBarrierMouse.Handoff] afterRestore realCursor=(\(realAfter.x),\(realAfter.y))")
        warpLocalCursor(to: point, reason: "synthetic handoff final anchor after restore")
        setMode(.local, reason: "synthetic handoff complete: \(reason)")
        activeHandoffID = nil
        syntheticHandoffPoint = nil
        syntheticHandoffEventCount = 0
        syntheticHandoffQuietCount = 0
    }

    private func clearSyntheticHandoffState(reason: String) {
        guard mode == .localSyntheticHandoff else { return }
        syntheticHandoffTimer?.cancel()
        syntheticHandoffTimer = nil
        let point = syntheticHandoffPoint ?? CGPoint(x: NSScreenFrame.main.midX, y: NSScreenFrame.main.midY)
        NSLog("[NoBarrierMouse.Handoff] clearState reason=\(reason) point=(\(point.x),\(point.y))")
        activeHandoffID = nil
        syntheticHandoffPoint = nil
        syntheticHandoffEventCount = 0
        syntheticHandoffQuietCount = 0
        // Caller must still call restoreLocalCursor + setMode(.local)
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
            "localCursorSuppressed": associateSuppressed,
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
        clearSyntheticHandoffState(reason: "emergency recovery")
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
