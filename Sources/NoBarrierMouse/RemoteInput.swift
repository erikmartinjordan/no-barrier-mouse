import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class RemoteInput {
    var onReleaseRequested: (() -> Void)?
    var onReturnControlRequested: ((WireMessage) -> Void)?
    var onInputPostingBlocked: (() -> Void)?
    var suppressPermissionSideEffects = false

    private lazy var eventSource = CGEventSource(stateID: .hidSystemState)
    private let doubleClickInterval = NSEvent.doubleClickInterval
    private var lastClickTime: CFAbsoluteTime = 0
    private var lastClickCount: Int = 0
    private var pressedButton: Int?
    private enum RemoteInputMode: Equatable {
        case inactive
        case active
        case handoffPending(id: UInt64)
    }

    private var didRequestRelease = false
    private var mode: RemoteInputMode = .inactive
    private var isRemoteActive: Bool { mode != .inactive }
    private var nextHandoffID: UInt64 = 1
    private lazy var cursorPoint: CGPoint = currentMousePoint()
    private var lastMouseArrivalAt: UInt64?
    private var lastMouseApplyAt: UInt64?
    private var benchmarkRecorder: MouseBenchmarkRecorder?
    private var cachedTrust = AXIsProcessTrusted()
    private var nextTrustCheck = CFAbsoluteTime(0)
    private var keyEventsReceived = 0
    private var keyEventsPosted = 0
    private var lastKeyCode: UInt16?
    private var lastKeyDown = false
    private var lastKeyFlags: UInt64 = 0
    private var lastKeyWasRemoteActive = false
    private var lastKeyWasTrusted = false

    private var mainScreen: CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    func apply(_ message: WireMessage, receivedAt: UInt64 = InputMetrics.nowTicks()) {
        InputMetrics.shared.record(.receiverQueue, from: receivedAt)

        switch message {
        case .mouseDelta(let dx, let dy, _):
            recordMouseArrival(receivedAt)
            guard isRemoteActive else { return }
            _ = moveMouse(dx: dx, dy: dy)
        case .benchmarkStart(let id, let sampleRate, let sampleCount, let transport):
            startBenchmark(id: id, sampleRate: sampleRate, sampleCount: sampleCount, transport: transport)
        case .benchmarkDelta(_, let sequence, let sentMilliseconds, let dx, let dy):
            recordMouseArrival(receivedAt)
            guard isRemoteActive else { return }
            if let appliedAt = moveMouse(dx: dx, dy: dy) {
                benchmarkRecorder?.record(sequence: sequence, sentMilliseconds: sentMilliseconds, dx: dx, dy: dy, receivedAt: receivedAt, appliedAt: appliedAt, point: cursorPoint)
            }
        case .benchmarkEnd(let id):
            finishBenchmark(id: id, reason: "completed")
        case .mouseDown(let button):
            guard isRemoteActive, canPostInputEvents() else { return }
            postMouse(button: button, down: true)
        case .mouseUp(let button):
            guard isRemoteActive, canPostInputEvents() else { return }
            postMouse(button: button, down: false)
        case .scroll(let dx, let dy):
            guard isRemoteActive, canPostInputEvents() else { return }
            let postStartedAt = InputMetrics.nowTicks()
            let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            post(event, startedAt: postStartedAt)
        case .key(let code, let down, let flags):
            recordKeyEvent(code: code, down: down, flags: flags)
            guard isRemoteActive, canPostInputEvents() else { return }
            let postStartedAt = InputMetrics.nowTicks()
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down)
            event?.flags = CGEventFlags(wireValue: flags)
            post(event, startedAt: postStartedAt)
            keyEventsPosted += 1
        case .flags(let code, let flags):
            recordKeyEvent(code: code, down: flags != 0, flags: flags)
            guard isRemoteActive, canPostInputEvents() else { return }
            let postStartedAt = InputMetrics.nowTicks()
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: flags != 0)
            event?.flags = CGEventFlags(wireValue: flags)
            event?.type = .flagsChanged
            post(event, startedAt: postStartedAt)
            keyEventsPosted += 1
        case .activate:
            enterFromLeftEdge(at: mainScreen.midY)
        case .enter(let y):
            enterFromLeftEdge(at: y)
        case .release:
            leaveRemote()
        case .returnControl:
            break
        case .returnControlDelta:
            break
        case .returnControlAck(let handoffID):
            receiveReturnControlAck(handoffID: handoffID)
        case .hello,
             .ping,
             .pong,
             .benchmarkRequestNWConnection,
             .testClipboardPayload,
             .testClipboardPrepareCopy,
             .testClipboardResult:
            break
        }
    }

    func reset() {
        mode = .inactive
        pressedButton = nil
        didRequestRelease = false
        lastMouseArrivalAt = nil
        lastMouseApplyAt = nil
        _ = benchmarkRecorder?.finish(reason: "reset")
        benchmarkRecorder = nil
    }

    func diagnosticsSnapshot() -> [String: Any] {
        [
            "isRemoteActive": isRemoteActive,
            "remoteInputMode": "\(mode)",
            "cursorX": cursorPoint.x,
            "cursorY": cursorPoint.y,
            "pressedButton": pressedButton ?? NSNull(),
            "didRequestRelease": didRequestRelease,
            "lastMouseArrivalAt": lastMouseArrivalAt.map(String.init) ?? NSNull(),
            "lastMouseApplyAt": lastMouseApplyAt.map(String.init) ?? NSNull(),
            "accessibilityTrusted": AXIsProcessTrusted(),
            "suppressPermissionSideEffects": suppressPermissionSideEffects,
            "keyEventsReceived": keyEventsReceived,
            "keyEventsPosted": keyEventsPosted,
            "lastKeyCode": lastKeyCode.map { Int($0) } ?? NSNull(),
            "lastKeyDown": lastKeyDown,
            "lastKeyFlags": String(lastKeyFlags),
            "lastKeyWasRemoteActive": lastKeyWasRemoteActive,
            "lastKeyWasTrusted": lastKeyWasTrusted
        ]
    }

    private func recordKeyEvent(code: UInt16, down: Bool, flags: UInt64) {
        keyEventsReceived += 1
        lastKeyCode = code
        lastKeyDown = down
        lastKeyFlags = flags
        lastKeyWasRemoteActive = isRemoteActive
        lastKeyWasTrusted = canPostInputEvents()
    }

    private func recordMouseArrival(_ receivedAt: UInt64) {
        if let lastMouseArrivalAt {
            InputMetrics.shared.record(.mouseArrivalGap, from: lastMouseArrivalAt, to: receivedAt)
        }
        lastMouseArrivalAt = receivedAt
    }

    private func recordMouseApplyGap(_ startedAt: UInt64) {
        if let lastMouseApplyAt {
            InputMetrics.shared.record(.mouseApplyGap, from: lastMouseApplyAt, to: startedAt)
        }
        lastMouseApplyAt = startedAt
    }

    private func canPostInputEvents() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now >= nextTrustCheck {
            cachedTrust = AXIsProcessTrusted()
            nextTrustCheck = now + 1.0
        }
        if cachedTrust {
            return true
        }
        if !suppressPermissionSideEffects {
            onInputPostingBlocked?()
        }
        return false
    }

    private func currentMousePoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: mainScreen.midX, y: mainScreen.midY)
    }

    static func leftEdgeHandoff(
        start: CGPoint,
        dx: Double,
        dy: Double,
        boundaryX: CGFloat
    ) -> (yAtBoundary: Double, carryDx: Double, carryDy: Double) {
        let t = (Double(boundaryX) - Double(start.x)) / dx
        let clampedT = min(max(t, 0), 1)
        let yAtBoundary = Double(start.y) + clampedT * dy
        let carryDx = (1 - clampedT) * dx
        let carryDy = (1 - clampedT) * dy
        return (yAtBoundary, carryDx, carryDy)
    }

    private func moveMouse(dx: Double, dy: Double) -> UInt64? {
        switch mode {
        case .inactive:
            return nil
        case .handoffPending(let id):
            if dx != 0 || dy != 0 {
                log("late delta handoffID=\(id) dx=\(dx) dy=\(dy)")
                onReturnControlRequested?(.returnControlDelta(handoffID: id, dx: dx, dy: dy))
            }
            return nil
        case .active:
            break
        }

        let screen = mainScreen
        let start = cursorPoint
        let proposed = CGPoint(x: start.x + dx, y: start.y + dy)
        let boundaryX = screen.minX + 1

        if dx < 0, proposed.x <= boundaryX {
            let handoff = Self.leftEdgeHandoff(start: start, dx: dx, dy: dy, boundaryX: boundaryX)
            let yAtBoundary = min(max(CGFloat(handoff.yAtBoundary), screen.minY), screen.maxY - 2)
            cursorPoint = CGPoint(x: boundaryX, y: yAtBoundary)
            requestReturnControlIfNeeded(y: Double(yAtBoundary), carryDx: handoff.carryDx, carryDy: handoff.carryDy, start: start, proposed: proposed)
            return nil
        }

        cursorPoint.x = min(max(proposed.x, screen.minX), screen.maxX - 2)
        cursorPoint.y = min(max(proposed.y, screen.minY), screen.maxY - 2)

        didRequestRelease = false
        let postStartedAt = InputMetrics.nowTicks()
        recordMouseApplyGap(postStartedAt)
        postMove(at: cursorPoint, startedAt: postStartedAt)
        InputMetrics.shared.record(.mouseApplyTick, from: postStartedAt)
        return postStartedAt
    }

    private func requestReturnControlIfNeeded(y: Double, carryDx: Double, carryDy: Double, start: CGPoint, proposed: CGPoint) {
        guard case .active = mode, !didRequestRelease else { return }
        didRequestRelease = true
        let id = nextHandoffID
        nextHandoffID &+= 1
        mode = .handoffPending(id: id)
        log("left-edge handoffID=\(id) start=(\(start.x),\(start.y)) proposed=(\(proposed.x),\(proposed.y)) y=\(y) carry=(\(carryDx),\(carryDy))")
        onReturnControlRequested?(.returnControl(y: y, carryDx: carryDx, carryDy: carryDy, handoffID: id))
    }

    private func receiveReturnControlAck(handoffID: UInt64) {
        guard case .handoffPending(let id) = mode, id == handoffID else {
            log("stale ACK ignored handoffID=\(handoffID) mode=\(mode)")
            return
        }
        log("ACK received handoffID=\(handoffID)")
        leaveRemote()
    }

    private func requestReleaseIfNeeded() {
        guard !didRequestRelease else { return }
        didRequestRelease = true
        leaveRemote()
        onReleaseRequested?()
    }

    private func postMove(at point: CGPoint, startedAt: UInt64) {
        guard isRemoteActive else { return }

        let type: CGEventType
        let button: CGMouseButton

        switch pressedButton {
        case 1:
            type = .rightMouseDragged
            button = .right
        case 2:
            type = .otherMouseDragged
            button = .center
        default:
            type = pressedButton == nil ? .mouseMoved : .leftMouseDragged
            button = .left
        }

        let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        post(event, startedAt: startedAt)
    }

    private func enterFromLeftEdge(at y: Double) {
        let screen = mainScreen
        mode = .active
        pressedButton = nil
        didRequestRelease = false
        lastMouseArrivalAt = nil
        lastMouseApplyAt = nil
        cursorPoint = CGPoint(x: screen.minX + 2, y: min(max(y, screen.minY + 2), screen.maxY - 2))

        let postStartedAt = InputMetrics.nowTicks()
        CGWarpMouseCursorPosition(cursorPoint)
        postMove(at: cursorPoint, startedAt: postStartedAt)
    }

    private func leaveRemote() {
        mode = .inactive
        pressedButton = nil
        didRequestRelease = false
        lastMouseArrivalAt = nil
        lastMouseApplyAt = nil
    }

    private func startBenchmark(id: UInt32, sampleRate: UInt16, sampleCount: UInt16, transport: String) {
        _ = benchmarkRecorder?.finish(reason: "replaced")
        benchmarkRecorder = MouseBenchmarkRecorder(id: id, sampleRate: sampleRate, expectedSamples: sampleCount, transport: transport)

        let screen = mainScreen
        mode = .active
        pressedButton = nil
        didRequestRelease = false
        lastMouseArrivalAt = nil
        lastMouseApplyAt = nil
        cursorPoint = CGPoint(x: screen.midX, y: screen.midY)

        let postStartedAt = InputMetrics.nowTicks()
        CGWarpMouseCursorPosition(cursorPoint)
        postMove(at: cursorPoint, startedAt: postStartedAt)
    }

    private func finishBenchmark(id: UInt32, reason: String) {
        guard benchmarkRecorder != nil else { return }
        _ = benchmarkRecorder?.finish(reason: reason)
        benchmarkRecorder = nil
        lastMouseArrivalAt = nil
        lastMouseApplyAt = nil
    }

    private func postMouse(button: Int, down: Bool) {
        let point = cursorPoint
        let cgButton: CGMouseButton

        let type: CGEventType
        switch button {
        case 1:
            type = down ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        case 2:
            type = down ? .otherMouseDown : .otherMouseUp
            cgButton = .center
        default:
            type = down ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        }

        let postStartedAt = InputMetrics.nowTicks()
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) {
            pressedButton = down ? button : nil

            if button == 0 {
                if down {
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastClickTime < doubleClickInterval {
                        lastClickCount = min(lastClickCount + 1, 3)
                    } else {
                        lastClickCount = 1
                    }
                    lastClickTime = now
                }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(lastClickCount))
            }

            post(event, startedAt: postStartedAt)
        }
    }

    private func post(_ event: CGEvent?, startedAt: UInt64) {
        guard let event else { return }
        if isCursorEvent(event.type) {
            CGWarpMouseCursorPosition(event.location)
        }
        if !suppressPermissionSideEffects || AXIsProcessTrusted() {
            event.post(tap: .cghidEventTap)
        }
        InputMetrics.shared.record(.cgEventPost, from: startedAt)
    }

    private func log(_ message: String) {
        guard ProcessInfo.processInfo.environment["NO_BARRIER_MOUSE_EVENTTAP_DEBUG"] == "1" else { return }
        NSLog("[NoBarrierMouse.RemoteInput] %@", message)
    }

    private func isCursorEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .leftMouseDown,
             .leftMouseUp,
             .rightMouseDown,
             .rightMouseUp,
             .otherMouseDown,
             .otherMouseUp:
            return true
        default:
            return false
        }
    }
}
