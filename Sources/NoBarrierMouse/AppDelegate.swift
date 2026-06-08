import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let chooseRoleItem = NSMenuItem(title: "Choose Role...", action: #selector(chooseRole), keyEquivalent: "")
    private let turnOffItem = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    private let network = PeerNetwork()
    private let eventTap = EventTap()
    private let remoteInput = RemoteInput()
    private let roleSelectionController = RoleSelectionController()

    private var isOn = false
    private var role: AppRole?
    private var accessibilityProblem = false
    private var state: ConnectionState = .off {
        didSet { updateAppearance() }
    }
    private var accessibilityTimer: Timer?
    private let disconnectedIcon = MouseIcon.make()
    private let connectedIcon = MouseIcon.makeConnected()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        wireComponents()
        updateAppearance()

        roleSelectionController.show { [weak self] role in
            self?.turnOn(role: role)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        roleSelectionController.show { [weak self] role in
            self?.turnOn(role: role)
        }
        return true
    }

    private var accessibilityItem: NSMenuItem?

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)

        let button = statusItem.button
        button?.image = disconnectedIcon
        button?.toolTip = "No Barrier Mouse"
        #if DEBUG
        if button == nil { print("WARNING: statusItem.button is nil") }
        #endif

        statusLabel.isEnabled = false
        chooseRoleItem.target = self
        turnOffItem.target = self
        quitItem.target = self
        menu.addItem(statusLabel)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(chooseRoleItem)
        menu.addItem(turnOffItem)
        menu.addItem(NSMenuItem.separator())
        let accItem = NSMenuItem(title: "Grant Accessibility...", action: #selector(grantAccessibility), keyEquivalent: "")
        accItem.target = self
        menu.addItem(accItem)
        accessibilityItem = accItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func wireComponents() {
        network.onState = { [weak self] state in
            self?.state = state
            self?.eventTap.isConnected = state == .connected
            if state != .connected {
                self?.eventTap.releaseLocalControl()
            }
        }
        network.onMessage = { [weak self] message in
            self?.handleNetworkMessage(message)
        }
        remoteInput.onInputPostingBlocked = { [weak self] in
            self?.accessibilityProblem = true
            self?.startAccessibilityTimer()
            self?.updateAppearance()
        }
        eventTap.send = { [weak self] message in
            self?.network.send(message)
        }
        remoteInput.onReleaseRequested = { [weak self] in
            guard let self else { return }
            if self.role == .controller {
                self.eventTap.reclaimLocalControlFromRemote()
            } else {
                self.network.send(.returnControl)
            }
        }
        eventTap.onEmergencyOff = { [weak self] in
            self?.turnOff()
        }
        eventTap.onCaptureFailed = { [weak self] in
            self?.accessibilityProblem = true
            self?.updateAppearance()
        }
    }

    @objc private func chooseRole() {
        roleSelectionController.show { [weak self] role in
            self?.turnOn(role: role)
        }
    }

    private func handleNetworkMessage(_ message: WireMessage) {
        if (message == .release || message == .returnControl), role == .controller {
            eventTap.reclaimLocalControlFromRemote()
            return
        }

        remoteInput.apply(message)
    }

    private func turnOn(role: AppRole) {
        turnOff()
        self.role = role
        isOn = true
        accessibilityProblem = !requestAccessibilityIfNeeded(prompt: true)
        if role == .controller {
            if !eventTap.start() {
                accessibilityProblem = true
                startAccessibilityTimer()
            }
        }
        if accessibilityProblem {
            startAccessibilityTimer()
        }
        network.start(role: role)
        updateAppearance()
    }

    @objc private func turnOff() {
        stopAccessibilityTimer()
        eventTap.stop()
        network.stop()
        role = nil
        isOn = false
        accessibilityProblem = false
        state = .off
    }

    private func startAccessibilityTimer() {
        stopAccessibilityTimer()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.accessibilityProblem else { return }
            guard AXIsProcessTrusted() else { return }
            self.accessibilityProblem = false
            if self.role == .controller {
                self.eventTap.start()
            }
            self.updateAppearance()
            self.stopAccessibilityTimer()
        }
    }

    private func stopAccessibilityTimer() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    @objc private func grantAccessibility() {
        _ = requestAccessibilityIfNeeded(prompt: true)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        eventTap.stop()
        network.stop()
        NSApp.terminate(nil)
    }

    private func updateAppearance() {
        statusItem.button?.image = state == .connected ? connectedIcon : disconnectedIcon

        let label: String
        if accessibilityProblem {
            label = "Needs Accessibility Permission"
        } else {
            switch state {
            case .off:
                label = "Off"
            case .waiting:
                let r = role.map { " (\($0))" } ?? ""
                label = "Waiting for another device\(r)"
            case .connected:
                let r = role.map { " (\($0))" } ?? ""
                label = "Connected\(r)"
            }
        }
        statusLabel.title = label
        chooseRoleItem.title = isOn ? "Change Role..." : "Choose Role..."
        turnOffItem.isEnabled = isOn
        accessibilityItem?.isHidden = !accessibilityProblem

    }

    @discardableResult
    private func requestAccessibilityIfNeeded(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

}

enum MouseIcon {
    static func make() -> NSImage {
        draw(strokeColor: .labelColor, template: true)
    }

    static func makeConnected() -> NSImage {
        draw(strokeColor: .systemGreen, template: false)
    }

    private static func draw(strokeColor: NSColor, template: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22))
        image.lockFocus()

        strokeColor.setStroke()
        NSColor.clear.setFill()

        let body = NSBezierPath(roundedRect: NSRect(x: 6, y: 3, width: 10, height: 15), xRadius: 5, yRadius: 5)
        body.lineWidth = 1.6
        body.stroke()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: 11, y: 18))
        line.line(to: NSPoint(x: 11, y: 12))
        line.lineWidth = 1.2
        line.stroke()

        let leftLens = NSBezierPath(ovalIn: NSRect(x: 4, y: 8, width: 7, height: 5))
        let rightLens = NSBezierPath(ovalIn: NSRect(x: 11, y: 8, width: 7, height: 5))
        leftLens.lineWidth = 1.3
        rightLens.lineWidth = 1.3
        leftLens.stroke()
        rightLens.stroke()

        let bridge = NSBezierPath()
        bridge.move(to: NSPoint(x: 10, y: 10.5))
        bridge.line(to: NSPoint(x: 12, y: 10.5))
        bridge.lineWidth = 1.1
        bridge.stroke()

        image.unlockFocus()
        image.isTemplate = template
        return image
    }
}
