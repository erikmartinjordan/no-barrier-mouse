import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let powerItem = NSMenuItem(title: "Enabled", action: #selector(togglePower), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    private let network = PeerNetwork()
    private let eventTap = EventTap()
    private let remoteInput = RemoteInput()
    private let roleSelectionController = RoleSelectionController()
    private lazy var settingsController = SettingsWindowController()

    private var isOn = false
    private var role: AppRole?
    private var accessibilityProblem = false
    private var inputMonitoringProblem = false
    private var state: ConnectionState = .off {
        didSet { updateAppearance() }
    }
    private var accessibilityTimer: Timer?
    private var benchmarkTimer: DispatchSourceTimer?
    private var automationTimer: Timer?
    private var lastAutomationCommandID: String?
    private let disconnectedIcon = MouseIcon.make()
    private let connectedIcon = MouseIcon.makeConnected()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        wireComponents()
        registerBenchmarkAutomation()
        startAutomationCommandPoller()
        updateAppearance()

        if let previewRole = settingsPreviewRoleFromArguments() {
            NSApp.setActivationPolicy(.regular)
            InputMetrics.shared.setTransport("Router WiFi")
            settingsController.present()
            settingsController.update(state: SettingsPanelState(
                role: previewRole,
                isOn: true,
                connectionState: .connected,
                airDropLatencyModeEnabled: previewRole == .receiver,
                airDropIsOff: previewRole == .receiver,
                previewLatency: previewRole == .receiver ? previewLatencySnapshot() : nil
            ))
            return
        }

        if let launchRole = launchRoleFromArguments() {
            turnOn(role: launchRole)
        } else {
            showRoleSelection()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isOn {
            showSettings()
        } else {
            showRoleSelection()
        }
        return true
    }

    private var accessibilityItem: NSMenuItem?
    private var inputMonitoringItem: NSMenuItem?

    private func launchRoleFromArguments() -> AppRole? {
        let arguments = CommandLine.arguments.map { $0.lowercased() }
        guard let index = arguments.firstIndex(of: "--role"), arguments.indices.contains(index + 1) else {
            return nil
        }
        switch arguments[index + 1] {
        case "controller":
            return .controller
        case "receiver":
            return .receiver
        default:
            return nil
        }
    }

    private func settingsPreviewRoleFromArguments() -> AppRole? {
        let arguments = CommandLine.arguments.map { $0.lowercased() }
        guard let index = arguments.firstIndex(of: "--settings-preview"), arguments.indices.contains(index + 1) else {
            return nil
        }
        switch arguments[index + 1] {
        case "controller":
            return .controller
        case "receiver":
            return .receiver
        default:
            return nil
        }
    }

    private func previewLatencySnapshot() -> EndToEndLatencySnapshot {
        let values: [Double] = [
            6.1, 6.5, 6.7, 6.9, 7.2, 7.5, 7.8, 8.0,
            8.1, 8.4, 8.6, 9.0, 11.2, 8.7, 8.2, 7.9,
            8.3, 8.8, 12.6, 9.1, 8.6, 8.0, 7.6, 7.8,
            8.4, 22.0, 9.3, 8.6, 36.0, 8.7, 8.1, 8.4
        ]
        return EndToEndLatencySnapshot(
            values: values,
            count: values.count,
            p50: 8.4,
            p90: 11.2,
            p99: 18.6,
            last: 8.4,
            updatedAt: Date()
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)

        let button = statusItem.button
        button?.image = disconnectedIcon
        button?.toolTip = "No Barrier Mouse"
        #if DEBUG
        if button == nil { print("WARNING: statusItem.button is nil") }
        #endif

        statusLabel.isEnabled = false
        powerItem.target = self
        settingsItem.target = self
        quitItem.target = self
        menu.addItem(statusLabel)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(powerItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let accItem = NSMenuItem(title: "Grant Accessibility...", action: #selector(grantAccessibility), keyEquivalent: "")
        accItem.target = self
        menu.addItem(accItem)
        accessibilityItem = accItem
        let inputItem = NSMenuItem(title: "Grant Input Monitoring...", action: #selector(grantInputMonitoring), keyEquivalent: "")
        inputItem.target = self
        menu.addItem(inputItem)
        inputMonitoringItem = inputItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func wireComponents() {
        network.onState = { [weak self] state in
            self?.state = state
            self?.eventTap.isConnected = state == .connected
            if state != .connected, state != .connecting {
                self?.eventTap.releaseLocalControl()
            }
        }
        network.onMessage = { [weak self] message, receivedAt in
            self?.handleNetworkMessage(message, receivedAt: receivedAt)
        }
        remoteInput.onInputPostingBlocked = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.role == .receiver {
                    self.network.send(.returnControl)
                }
                self.accessibilityProblem = true
                self.startAccessibilityTimer()
                self.updateAppearance()
            }
        }
        eventTap.send = { [weak self] message in
            self?.network.send(message)
        }
        remoteInput.onReleaseRequested = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.role == .controller {
                    self.eventTap.reclaimLocalControlFromRemote()
                } else {
                    self.network.send(.returnControl)
                }
            }
        }
        eventTap.onEmergencyOff = { [weak self] in
            self?.turnOff()
        }
        eventTap.onCaptureFailed = { [weak self] in
            self?.accessibilityProblem = true
            self?.updateAppearance()
        }
        settingsController.onRoleSelected = { [weak self] role in
            self?.turnOn(role: role)
        }
        settingsController.onAirDropLatencyModeChanged = { [weak self] enabled in
            self?.setAirDropLatencyMode(enabled)
        }
        settingsController.onRunBenchmark = { [weak self] in
            guard self?.role == .receiver else { return }
            self?.runMouseBenchmark()
        }
    }

    @objc private func chooseRole() {
        showRoleSelection()
    }

    private func showRoleSelection() {
        roleSelectionController.show { [weak self] role in
            self?.turnOn(role: role)
        }
    }

    @objc private func togglePower() {
        if isOn {
            turnOff()
        } else {
            chooseRole()
        }
    }

    @objc private func showSettings() {
        settingsController.present()
        updateSettingsPanel()
    }

    @objc private func runMouseBenchmark() {
        guard state == .connected else {
            writeAutomationStatus(reason: "nw-benchmark-skipped-not-connected")
            return
        }
        guard role == .controller else {
            network.send(.benchmarkRequestNWConnection)
            writeAutomationStatus(reason: "nw-benchmark-requested-from-receiver")
            return
        }

        writeAutomationStatus(reason: "nw-benchmark-started-on-controller")
        benchmarkTimer?.cancel()

        let id = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: Double(UInt32.max)))
        let sampleRate: UInt16 = 120
        let sampleCount: UInt16 = 960
        let radius = 120.0
        let cycles = 4.0
        let queue = DispatchQueue(label: "NoBarrierMouse.MouseBenchmark", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let startedAt = InputMetrics.nowTicks()
        var sequence: UInt32 = 0
        var previous = CGPoint(x: radius, y: 0)

        network.send(.benchmarkStart(id: id, sampleRate: sampleRate, sampleCount: sampleCount, transport: "NWConnection"))

        timer.schedule(deadline: .now() + .milliseconds(100), repeating: 1.0 / Double(sampleRate), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard sequence < UInt32(sampleCount) else {
                self.network.send(.benchmarkEnd(id: id))
                timer.cancel()
                return
            }

            let progress = Double(sequence + 1) / Double(sampleCount)
            let angle = progress * cycles * Double.pi * 2
            let current = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            previous = current

            let sentMilliseconds = InputMetrics.milliseconds(from: startedAt)
            self.network.send(.benchmarkDelta(id: id, sequence: sequence, sentMilliseconds: sentMilliseconds, dx: dx, dy: dy))
            sequence += 1
        }
        benchmarkTimer = timer
        timer.resume()
    }

    private func handleNetworkMessage(_ message: WireMessage, receivedAt: UInt64) {
        if (message == .release || message == .returnControl), role == .controller {
            DispatchQueue.main.async { [eventTap] in
                eventTap.reclaimLocalControlFromRemote()
            }
            return
        }

        if message == .benchmarkRequestNWConnection, role == .controller {
            DispatchQueue.main.async { [weak self] in
                self?.runMouseBenchmark()
            }
            return
        }

        remoteInput.apply(message, receivedAt: receivedAt)
    }

    private func registerBenchmarkAutomation() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(runMouseBenchmark),
            name: Notification.Name("NoBarrierMouseRunBenchmark"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(dumpAutomationStatus),
            name: Notification.Name("NoBarrierMouseDumpStatus"),
            object: nil
        )
    }

    private func startAutomationCommandPoller() {
        automationTimer?.invalidate()
        automationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollAutomationCommand()
        }
    }

    private func pollAutomationCommand() {
        let url = URL(fileURLWithPath: "/tmp/no-barrier-mouse-command.json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = payload["id"] as? String,
              id != lastAutomationCommandID,
              let command = payload["command"] as? String else {
            return
        }

        lastAutomationCommandID = id
        switch command {
        case "status":
            writeAutomationStatus(reason: "file-command-status")
        case "nwBenchmark":
            runMouseBenchmark()
        default:
            writeAutomationStatus(reason: "unknown-file-command-\(command)")
        }
    }

    @objc private func dumpAutomationStatus() {
        writeAutomationStatus(reason: "manual-status-dump")
    }

    private func writeAutomationStatus(reason: String) {
        let status = InputMetrics.shared.statusSnapshot()
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
            "role": role?.description ?? "none",
            "state": "\(state)",
            "isOn": isOn,
            "statusLabel": status.state,
            "statusRole": status.role,
            "connected": status.connected,
            "transport": status.transport,
            "issue": status.issue as Any
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("no-barrier-mouse-status.json")
        try? data.write(to: url, options: .atomic)
    }

    private func turnOn(role: AppRole) {
        turnOff()
        self.role = role
        isOn = true
        InputMetrics.shared.reset()
        accessibilityProblem = !requestAccessibilityIfNeeded(prompt: true)
        if role == .controller {
            if #available(macOS 11, *) {
                inputMonitoringProblem = !requestInputMonitoringIfNeeded(prompt: true)
            }
            if !eventTap.start() {
                accessibilityProblem = true
                startAccessibilityTimer()
            }
        }
        if accessibilityProblem || inputMonitoringProblem {
            startAccessibilityTimer()
        }
        network.start(role: role)
        AirDropLatencyMode.apply(disabled: AirDropLatencyMode.isEnabled && role == .receiver)
        updateAppearance()
    }

    @objc private func turnOff() {
        stopAccessibilityTimer()
        benchmarkTimer?.cancel()
        benchmarkTimer = nil
        AirDropLatencyMode.apply(disabled: false)
        eventTap.stop()
        remoteInput.reset()
        network.stop()
        role = nil
        isOn = false
        accessibilityProblem = false
        inputMonitoringProblem = false
        state = .off
        updateSettingsPanel()
    }

    private func startAccessibilityTimer() {
        stopAccessibilityTimer()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.accessibilityProblem || self.inputMonitoringProblem else { return }
            if self.accessibilityProblem, AXIsProcessTrusted() {
                self.accessibilityProblem = false
            }
            if self.inputMonitoringProblem, #available(macOS 11, *), CGPreflightListenEventAccess() {
                self.inputMonitoringProblem = false
            }
            if self.role == .controller {
                self.eventTap.start()
            }
            self.updateAppearance()
            if !self.accessibilityProblem && !self.inputMonitoringProblem {
                self.stopAccessibilityTimer()
            }
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

    @objc private func grantInputMonitoring() {
        guard #available(macOS 11, *) else { return }
        _ = requestInputMonitoringIfNeeded(prompt: true)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
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
        } else if inputMonitoringProblem {
            label = "Needs Input Monitoring Permission"
        } else {
            switch state {
            case .off:
                label = "Off"
            case .waiting:
                let r = role.map { " (\($0))" } ?? ""
                label = "Waiting for another device\(r)"
            case .connecting:
                let r = role.map { " (\($0))" } ?? ""
                label = "Handshaking\(r)"
            case .connected:
                let r = role.map { " (\($0))" } ?? ""
                label = "Connected\(r)"
            }
        }
        statusLabel.title = label
        let issue = accessibilityProblem ? "Needs Accessibility Permission" : (inputMonitoringProblem ? "Needs Input Monitoring Permission" : nil)
        InputMetrics.shared.setStatus(
            state: label,
            role: role.map { $0.description } ?? "No role",
            connected: state == .connected,
            issue: issue
        )
        powerItem.state = isOn ? .on : .off
        accessibilityItem?.isHidden = !accessibilityProblem
        inputMonitoringItem?.isHidden = !inputMonitoringProblem
        updateSettingsPanel()

    }

    private func setAirDropLatencyMode(_ enabled: Bool) {
        AirDropLatencyMode.isEnabled = enabled
        AirDropLatencyMode.apply(disabled: enabled && role == .receiver)
        updateSettingsPanel()
    }

    private func updateSettingsPanel() {
        settingsController.update(state: SettingsPanelState(
            role: role,
            isOn: isOn,
            connectionState: state,
            airDropLatencyModeEnabled: AirDropLatencyMode.isEnabled,
            airDropIsOff: AirDropLatencyMode.isAirDropOff
        ))
    }

    @discardableResult
    private func requestAccessibilityIfNeeded(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    private func requestInputMonitoringIfNeeded(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }
        if prompt {
            return CGRequestListenEventAccess()
        }
        return false
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
        strokeColor.withAlphaComponent(0.22).setFill()

        let body = NSBezierPath(roundedRect: NSRect(x: 6, y: 3, width: 10, height: 15), xRadius: 5, yRadius: 5)
        body.lineWidth = 1.6
        body.fill()
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
        leftLens.fill()
        rightLens.fill()
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
