import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class RemoteInput {
    var onReleaseRequested: (() -> Void)?
    var onInputPostingBlocked: (() -> Void)?

    private let inputQueue = DispatchQueue(label: "NoBarrierMouse.RemoteInput", qos: .userInteractive)
    private lazy var eventSource = CGEventSource(stateID: .hidSystemState)
    private let doubleClickInterval = NSEvent.doubleClickInterval

    private var lastClickTime: CFAbsoluteTime = 0
    private var lastClickCount: Int = 0
    private var pressedButton: Int?
    private var didRequestRelease = false
    private var isRemoteActive = false
    private lazy var cursorPoint: CGPoint = currentMousePoint()
    private let mouseDeltaLock = NSLock()
    private var pendingMouseDelta = CGPoint.zero
    private var mouseTickTimer: DispatchSourceTimer?
    private var emptyMouseTicks = 0
    private var cachedTrust = AXIsProcessTrusted()
    private var nextTrustCheck = CFAbsoluteTime(0)
    private let mouseTickInterval = 1.0 / 240.0
    private let maxEmptyMouseTicks = 12

    private var mainScreen: CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    func apply(_ message: WireMessage) {
        if case .mouseDelta(let dx, let dy, _) = message {
            enqueueMouseDelta(dx: dx, dy: dy)
            return
        }

        switch message {
        case .activate, .enter, .release, .returnControl:
            clearPendingMouseDelta()
            inputQueue.async {
                self.applyOnInputQueue(message)
            }
        default:
            let pendingDelta = takePendingMouseDelta()
            inputQueue.async {
                if self.isRemoteActive {
                    self.applyMouseDelta(pendingDelta)
                }
                self.applyOnInputQueue(message)
            }
        }
    }

    func reset() {
        inputQueue.sync {
            self.isRemoteActive = false
            self.pressedButton = nil
            self.didRequestRelease = false
            self.emptyMouseTicks = 0
            self.stopMouseTickTimer()
        }
        clearPendingMouseDelta()
    }

    private func applyOnInputQueue(_ message: WireMessage) {
        switch message {
        case .mouseDelta(let dx, let dy, _):
            enqueueMouseDelta(dx: dx, dy: dy)
        case .mouseDown(let button):
            guard isRemoteActive, canPostInputEvents() else { return }
            postMouse(button: button, down: true)
        case .mouseUp(let button):
            guard isRemoteActive, canPostInputEvents() else { return }
            postMouse(button: button, down: false)
        case .scroll(let dx, let dy):
            guard isRemoteActive, canPostInputEvents() else { return }
            let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            event?.post(tap: .cghidEventTap)
        case .key(let code, let down, let flags):
            guard isRemoteActive, canPostInputEvents() else { return }
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down)
            event?.flags = CGEventFlags(wireValue: flags)
            event?.post(tap: .cghidEventTap)
        case .flags(let code, let flags):
            guard isRemoteActive, canPostInputEvents() else { return }
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true)
            event?.flags = CGEventFlags(wireValue: flags)
            event?.post(tap: .cghidEventTap)
        case .activate:
            enterFromLeftEdge(at: mainScreen.midY)
        case .enter(let y):
            enterFromLeftEdge(at: y)
        case .release:
            leaveRemote()
        case .returnControl:
            leaveRemote()
            onReleaseRequested?()
        case .hello:
            break
        }
    }

    private func enqueueMouseDelta(dx: Double, dy: Double) {
        mouseDeltaLock.lock()
        pendingMouseDelta.x += dx
        pendingMouseDelta.y += dy
        mouseDeltaLock.unlock()

        mouseDeltaSignal.add(data: 1)
    }

    private lazy var mouseDeltaSignal: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: inputQueue)
        source.setEventHandler { [weak self] in
            self?.ensureMouseTickTimer()
        }
        source.resume()
        return source
    }()

    private func takePendingMouseDelta() -> CGPoint {
        mouseDeltaLock.lock()
        let delta = pendingMouseDelta
        pendingMouseDelta = .zero
        mouseDeltaLock.unlock()
        return delta
    }

    private func clearPendingMouseDelta() {
        mouseDeltaLock.lock()
        pendingMouseDelta = .zero
        mouseDeltaLock.unlock()
    }

    private func ensureMouseTickTimer() {
        guard mouseTickTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: inputQueue)
        timer.schedule(deadline: .now(), repeating: mouseTickInterval, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            self?.drainMouseTick()
        }
        mouseTickTimer = timer
        timer.resume()
    }

    private func stopMouseTickTimer() {
        mouseTickTimer?.cancel()
        mouseTickTimer = nil
    }

    private func drainMouseTick() {
        let delta = takePendingMouseDelta()
        if !isRemoteActive {
            emptyMouseTicks += 1
            if emptyMouseTicks >= maxEmptyMouseTicks {
                stopMouseTickTimer()
                emptyMouseTicks = 0
            }
            return
        }

        if delta.x == 0 && delta.y == 0 {
            emptyMouseTicks += 1
            if emptyMouseTicks >= maxEmptyMouseTicks {
                stopMouseTickTimer()
                emptyMouseTicks = 0
            }
            return
        }

        emptyMouseTicks = 0
        moveMouse(dx: delta.x, dy: delta.y)
    }

    private func applyMouseDelta(_ delta: CGPoint) {
        guard delta.x != 0 || delta.y != 0 else { return }
        moveMouse(dx: delta.x, dy: delta.y)
    }

    private func leaveRemote() {
        isRemoteActive = false
        pressedButton = nil
        didRequestRelease = false
        emptyMouseTicks = 0
        stopMouseTickTimer()
        clearPendingMouseDelta()
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
        onInputPostingBlocked?()
        return false
    }

    private func currentMousePoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: mainScreen.midX, y: mainScreen.midY)
    }

    private func moveMouse(dx: Double, dy: Double) {
        let screen = mainScreen
        cursorPoint.x = min(max(cursorPoint.x + dx, screen.minX), screen.maxX - 2)
        cursorPoint.y = min(max(cursorPoint.y + dy, screen.minY), screen.maxY - 2)

        if cursorPoint.x <= screen.minX + 1 {
            requestReleaseIfNeeded()
            return
        }

        didRequestRelease = false
        movedEvent(at: cursorPoint, dx: dx, dy: dy)
    }

    private func requestReleaseIfNeeded() {
        guard !didRequestRelease else { return }
        didRequestRelease = true
        leaveRemote()
        onReleaseRequested?()
    }

    private func movedEvent(at point: CGPoint, dx: Double, dy: Double) {
        guard canPostInputEvents() else { return }
        let type: CGEventType
        let button: CGMouseButton

        switch pressedButton {
        case 0:
            type = .leftMouseDragged
            button = .left
        case 1:
            type = .rightMouseDragged
            button = .right
        case 2:
            type = .otherMouseDragged
            button = .center
        default:
            type = .mouseMoved
            button = .left
        }

        let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event?.post(tap: .cghidEventTap)
    }

    private func enterFromLeftEdge(at y: Double) {
        let screen = mainScreen
        clearPendingMouseDelta()
        emptyMouseTicks = 0
        isRemoteActive = true
        didRequestRelease = false
        cursorPoint = CGPoint(x: screen.minX + 5, y: min(max(y, screen.minY + 5), screen.maxY - 5))
        CGWarpMouseCursorPosition(cursorPoint)
        movedEvent(at: cursorPoint, dx: 0, dy: 0)
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

            event.post(tap: .cghidEventTap)
        }
    }
}
