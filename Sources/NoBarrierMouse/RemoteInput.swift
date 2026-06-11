import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class RemoteInput {
    var onReleaseRequested: (() -> Void)?
    var onInputPostingBlocked: (() -> Void)?

    private lazy var eventSource = CGEventSource(stateID: .hidSystemState)
    private let doubleClickInterval = NSEvent.doubleClickInterval
    private var lastClickTime: CFAbsoluteTime = 0
    private var lastClickCount: Int = 0
    private var pressedButton: Int?
    private var didRequestRelease = false
    private lazy var cursorPoint: CGPoint = currentMousePoint()
    private var cachedTrust = AXIsProcessTrusted()
    private var nextTrustCheck = CFAbsoluteTime(0)
    private var mainScreen: CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    func apply(_ message: WireMessage) {
        switch message {
        case .mouseDelta(let dx, let dy, _):
            moveMouse(dx: dx, dy: dy)
        case .mouseDown(let button):
            guard canPostInputEvents() else { return }
            postMouse(button: button, down: true)
        case .mouseUp(let button):
            guard canPostInputEvents() else { return }
            postMouse(button: button, down: false)
        case .scroll(let dx, let dy):
            guard canPostInputEvents() else { return }
            let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            event?.post(tap: CGEventTapLocation.cghidEventTap)
        case .key(let code, let down, let flags):
            guard canPostInputEvents() else { return }
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down)
            event?.flags = CGEventFlags(wireValue: flags)
            event?.post(tap: CGEventTapLocation.cghidEventTap)
        case .flags(let code, let flags):
            guard canPostInputEvents() else { return }
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true)
            event?.flags = CGEventFlags(wireValue: flags)
            event?.post(tap: CGEventTapLocation.cghidEventTap)
        case .activate:
            enterFromLeftEdge(at: mainScreen.midY)
        case .enter(let y):
            enterFromLeftEdge(at: y)
        case .release:
            onReleaseRequested?()
        case .returnControl:
            onReleaseRequested?()
        case .hello:
            break
        }
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
        CGWarpMouseCursorPosition(cursorPoint)
        postMove(at: cursorPoint)
    }

    private func requestReleaseIfNeeded() {
        guard !didRequestRelease else { return }
        didRequestRelease = true
        pressedButton = nil
        onReleaseRequested?()
    }

    private func postMove(at point: CGPoint) {
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

        CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: CGEventTapLocation.cghidEventTap)
    }

    private func enterFromLeftEdge(at y: Double) {
        let screen = mainScreen
        cursorPoint = CGPoint(x: screen.minX + 5, y: min(max(y, screen.minY + 5), screen.maxY - 5))
        didRequestRelease = false
        CGWarpMouseCursorPosition(cursorPoint)
        postMove(at: cursorPoint)
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

            event.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }
}
