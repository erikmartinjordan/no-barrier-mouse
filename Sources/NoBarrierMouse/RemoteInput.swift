import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class RemoteInput {
    var onReleaseRequested: (() -> Void)?
    var onInputPostingBlocked: (() -> Void)?

    private var lastClickTime: Date = .distantPast
    private var lastClickCount: Int = 0
    private var pressedButton: Int?
    private var didRequestRelease = false

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
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            event?.post(tap: .cghidEventTap)
        case .key(let code, let down, let flags):
            guard canPostInputEvents() else { return }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = CGEventFlags(wireValue: flags)
            event?.post(tap: .cghidEventTap)
        case .flags(let code, let flags):
            guard canPostInputEvents() else { return }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            event?.flags = CGEventFlags(wireValue: flags)
            event?.post(tap: .cghidEventTap)
        case .activate:
            enterFromLeftEdge()
        case .enter:
            enterFromLeftEdge()
        case .release:
            onReleaseRequested?()
        case .returnControl:
            onReleaseRequested?()
        case .hello:
            break
        }
    }

    private func canPostInputEvents() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        onInputPostingBlocked?()
        return false
    }

    private func currentMousePoint() -> CGPoint {
        let ns = NSEvent.mouseLocation
        let screen = NSScreen.main?.frame ?? .zero
        return CGPoint(x: ns.x, y: screen.height - ns.y)
    }

    private func moveMouse(dx: Double, dy: Double) {
        let old = currentMousePoint()
        let screen = NSScreenFrame.main
        let next = CGPoint(
            x: min(max(old.x + dx, screen.minX), screen.maxX - 2),
            y: min(max(old.y + dy, screen.minY), screen.maxY - 2)
        )

        if next.x <= screen.minX + 1 {
            requestReleaseIfNeeded()
            return
        }

        didRequestRelease = false
        CGWarpMouseCursorPosition(next)
        postMove(at: next)
    }

    private func requestReleaseIfNeeded() {
        guard !didRequestRelease else { return }
        didRequestRelease = true
        pressedButton = nil
        onReleaseRequested?()
    }

    private func postMove(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
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

        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func enterFromLeftEdge() {
        let screen = NSScreenFrame.main
        let point = CGPoint(x: screen.midX, y: screen.midY)
        didRequestRelease = false
        CGWarpMouseCursorPosition(point)
        postMove(at: point)
    }

    private func postMouse(button: Int, down: Bool) {
        let point = currentMousePoint()
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

        let source = CGEventSource(stateID: .hidSystemState)
        if let source, let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) {
            pressedButton = down ? button : nil

            if button == 0 {
                if down {
                    let now = Date()
                    if now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
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

enum NSScreenFrame {
    static var main: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
