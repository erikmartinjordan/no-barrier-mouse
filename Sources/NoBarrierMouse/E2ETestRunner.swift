import AppKit
import ApplicationServices

final class E2ETestRunner {
    private let config = TestModeConfig.fromArguments()
    private let eventTap: EventTap
    private let remoteInput: RemoteInput
    private let send: (WireMessage) -> Void
    private let role: () -> AppRole?
    private let state: () -> ConnectionState
    private let isOn: () -> Bool
    private let accessibilityProblem: () -> Bool
    private let inputMonitoringProblem: () -> Bool
    private let turnOff: () -> Void

    private var watchdogTimer: Timer?
    private var started = false
    private var completed = false
    private var cycle = 0
    private var lastProgressAt = CFAbsoluteTimeGetCurrent()
    private var recoveries = 0
    private var clipboardResults = 0
    private var clipboardFailures = 0
    private var clipboardLastResultCycle = 0
    private lazy var clipboardWindowController = E2EClipboardWindowController()

    init(
        eventTap: EventTap,
        remoteInput: RemoteInput,
        send: @escaping (WireMessage) -> Void,
        role: @escaping () -> AppRole?,
        state: @escaping () -> ConnectionState,
        isOn: @escaping () -> Bool,
        accessibilityProblem: @escaping () -> Bool,
        inputMonitoringProblem: @escaping () -> Bool,
        turnOff: @escaping () -> Void
    ) {
        self.eventTap = eventTap
        self.remoteInput = remoteInput
        self.send = send
        self.role = role
        self.state = state
        self.isOn = isOn
        self.accessibilityProblem = accessibilityProblem
        self.inputMonitoringProblem = inputMonitoringProblem
        self.turnOff = turnOff
    }

    var isEnabled: Bool {
        config.enabled
    }

    func startIfNeeded() {
        guard config.enabled else { return }
        createLogDirectory()
        writeDiagnostics(reason: "test-mode-started")
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.runWatchdog()
        }
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    func startTortureIfNeeded(trigger: String) {
        guard config.enabled,
              config.autoStart,
              role() == .controller,
              state() == .connected,
              !started,
              !completed else {
            return
        }
        started = true
        cycle = 0
        lastProgressAt = CFAbsoluteTimeGetCurrent()
        writeDiagnostics(reason: "e2e-torture-start", extra: ["trigger": trigger, "cycles": config.cycles])
        runNextCycle()
    }

    func handleClipboardMessage(_ message: WireMessage) -> Bool {
        guard config.enabled else { return false }

        switch message {
        case .testClipboardPayload(let cycle, let text):
            DispatchQueue.main.async { [weak self] in
                guard let self, self.role() == .receiver else { return }
                self.clipboardWindowController.preparePaste(cycle: Int(cycle), text: text)
                self.writeDiagnostics(reason: "clipboard-paste-target-ready", extra: ["cycle": Int(cycle)])
            }
            return true
        case .testClipboardPrepareCopy(let cycle):
            DispatchQueue.main.async { [weak self] in
                guard let self, self.role() == .receiver else { return }
                let pasteSucceeded = self.clipboardWindowController.prepareCopy(cycle: Int(cycle))
                self.writeDiagnostics(reason: "clipboard-copy-target-ready", extra: [
                    "cycle": Int(cycle),
                    "pasteSucceeded": pasteSucceeded
                ])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let result = self.clipboardWindowController.validateCopy(cycle: Int(cycle))
                    self.send(.testClipboardResult(
                        cycle: cycle,
                        pasteSucceeded: result.pasteSucceeded,
                        copySucceeded: result.copySucceeded,
                        observedLength: UInt16(min(result.observedLength, Int(UInt16.max)))
                    ))
                    self.writeDiagnostics(reason: "clipboard-result-sent", extra: [
                        "cycle": Int(cycle),
                        "pasteSucceeded": result.pasteSucceeded,
                        "copySucceeded": result.copySucceeded,
                        "observedLength": result.observedLength
                    ])
                }
            }
            return true
        case .testClipboardResult(let cycle, let pasteSucceeded, let copySucceeded, let observedLength):
            DispatchQueue.main.async { [weak self] in
                guard let self, self.role() == .controller else { return }
                self.clipboardResults += 1
                self.clipboardLastResultCycle = Int(cycle)
                if !pasteSucceeded || !copySucceeded {
                    self.clipboardFailures += 1
                }
                self.writeDiagnostics(reason: "clipboard-result-received", extra: [
                    "cycle": Int(cycle),
                    "pasteSucceeded": pasteSucceeded,
                    "copySucceeded": copySucceeded,
                    "observedLength": Int(observedLength)
                ])
            }
            return true
        default:
            return false
        }
    }

    func recoverFromTrap(reason: String, turnOffAfterRecovery: Bool) {
        recoveries += 1
        writeDiagnostics(reason: "recovery-before-\(reason)")
        eventTap.emergencyRecover(reason: reason)
        remoteInput.reset()
        send(.release)
        writeDiagnostics(reason: "recovery-after-\(reason)", extra: ["turnOffAfterRecovery": turnOffAfterRecovery])
        if turnOffAfterRecovery {
            turnOff()
        }
    }

    func writeDiagnostics(reason: String, extra: [String: Any] = [:]) {
        guard config.enabled else { return }
        createLogDirectory()
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
            "role": role()?.description ?? "none",
            "connectionState": "\(state())",
            "isOn": isOn(),
            "accessibilityProblem": accessibilityProblem(),
            "inputMonitoringProblem": inputMonitoringProblem(),
            "testStarted": started,
            "testCompleted": completed,
            "testCycle": cycle,
            "testCycles": config.cycles,
            "testRecoveries": recoveries,
            "clipboardResults": clipboardResults,
            "clipboardFailures": clipboardFailures,
            "clipboardLastResultCycle": clipboardLastResultCycle,
            "eventTap": eventTap.diagnosticsSnapshot(),
            "remoteInput": remoteInput.diagnosticsSnapshot()
        ]
        for (key, value) in extra {
            payload[key] = value
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        let latest = config.logDirectoryURL.appendingPathComponent("latest-diagnostics.json")
        try? data.write(to: latest, options: .atomic)

        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        let jsonl = config.logDirectoryURL.appendingPathComponent("events.jsonl")
        if let lineData = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: jsonl.path),
               let handle = try? FileHandle(forWritingTo: jsonl) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                handle.closeFile()
            } else {
                try? lineData.write(to: jsonl, options: .atomic)
            }
        }

        if reason.contains("recovery") || reason.contains("trap") {
            let safeReason = reason.replacingOccurrences(of: "/", with: "-")
            let file = config.logDirectoryURL.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(safeReason).json")
            try? data.write(to: file, options: .atomic)
        }
    }

    private func runNextCycle() {
        guard config.enabled, role() == .controller, state() == .connected else {
            recoverFromTrap(reason: "e2e-aborted-not-connected", turnOffAfterRecovery: false)
            return
        }
        guard cycle < config.cycles else {
            completed = true
            writeDiagnostics(reason: "e2e-torture-complete", extra: [
                "cycles": cycle,
                "recoveries": recoveries,
                "clipboardResults": clipboardResults,
                "clipboardFailures": clipboardFailures
            ])
            cleanup(reason: "e2e-complete")
            return
        }

        let currentCycle = cycle + 1
        cycle = currentCycle
        lastProgressAt = CFAbsoluteTimeGetCurrent()
        let payload = testPayload(for: currentCycle)
        writeLocalClipboard(payload)
        send(.testClipboardPayload(cycle: UInt16(currentCycle), text: payload))
        writeDiagnostics(reason: "e2e-cycle-start", extra: [
            "cycle": currentCycle,
            "payloadBytes": payload.utf8.count
        ])

        animateControllerCursorToRightEdge(cycle: currentCycle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, self.config.enabled else { return }
            self.eventTap.beginTestForwarding(y: NSScreenFrame.main.midY)
            self.sendSmoothRemoteMotion(
                cycle: currentCycle,
                steps: 36,
                interval: 0.012,
                delta: CGPoint(x: 10, y: currentCycle.isMultiple(of: 2) ? 1 : -1)
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.73) { [weak self] in
            guard let self, self.config.enabled else { return }
            self.send(.mouseDown(button: 0))
            self.send(.mouseUp(button: 0))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.88) { [weak self] in
            guard let self, self.config.enabled else { return }
            self.sendCommandKey(code: 9)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.12) { [weak self] in
            guard let self, self.config.enabled else { return }
            self.send(.testClipboardPrepareCopy(cycle: UInt16(currentCycle)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.28) { [weak self] in
            guard let self, self.config.enabled else { return }
            self.sendCommandKey(code: 8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.36) { [weak self] in
            guard let self, self.config.enabled else { return }
            self.sendSmoothRemoteMotion(
                cycle: currentCycle,
                steps: 44,
                interval: 0.012,
                delta: CGPoint(x: -14, y: 0)
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
            guard let self else { return }
            if self.eventTap.isForwarding {
                self.writeDiagnostics(reason: "e2e-cycle-forced-reclaim", extra: ["cycle": currentCycle])
                self.eventTap.reclaimLocalControlFromRemote()
            }
            self.writeDiagnostics(reason: "e2e-cycle-end", extra: ["cycle": currentCycle])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.runNextCycle()
            }
        }
    }

    private func animateControllerCursorToRightEdge(cycle: Int) {
        let screen = NSScreenFrame.main
        let start = CGEvent(source: nil)?.location ?? CGPoint(x: screen.midX, y: screen.midY)
        let policy = EventTapEdgePolicy()
        let end = CGPoint(
            x: policy.remotePinX(maxX: screen.maxX),
            y: min(max(screen.midY + (cycle.isMultiple(of: 2) ? 18 : -18), screen.minY + 24), screen.maxY - 24)
        )
        let steps = 22
        for step in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.010 * Double(step)) {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
                CGWarpMouseCursorPosition(point)
            }
        }
    }

    private func sendSmoothRemoteMotion(cycle: Int, steps: Int, interval: TimeInterval, delta: CGPoint) {
        for step in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(step)) { [weak self] in
                guard let self,
                      self.config.enabled,
                      self.role() == .controller,
                      self.state() == .connected else {
                    return
                }
                self.send(.mouseDelta(dx: delta.x, dy: delta.y, button: nil))
                if step == steps - 1 {
                    self.writeDiagnostics(reason: "e2e-smooth-motion-end", extra: [
                        "cycle": cycle,
                        "steps": steps,
                        "dx": delta.x,
                        "dy": delta.y
                    ])
                }
            }
        }
    }

    private func sendCommandKey(code: UInt16) {
        let commandFlags = CGEventFlags.maskCommand.rawValue
        let commandKeyCode: UInt16 = 55
        send(.flags(code: commandKeyCode, flags: commandFlags))
        send(.key(code: code, down: true, flags: commandFlags))
        send(.key(code: code, down: false, flags: commandFlags))
        send(.flags(code: commandKeyCode, flags: 0))
    }

    private func testPayload(for cycle: Int) -> String {
        let base = (try? String(contentsOfFile: config.payloadFile, encoding: .utf8)) ?? "NoBarrierMouse E2E payload"
        return "\(base)\ncycle=\(cycle)\ntimestamp=\(ISO8601DateFormatter().string(from: Date()))\n"
    }

    private func writeLocalClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runWatchdog() {
        guard config.enabled else { return }
        writeDiagnostics(reason: "watchdog")
        guard role() == .controller else { return }

        let diagnostics = eventTap.diagnosticsSnapshot()
        let mode = diagnostics["mode"] as? String ?? ""
        let modeAge = diagnostics["modeAgeSeconds"] as? Double ?? 0
        let cursorX = diagnostics["cursorX"] as? CGFloat ?? 0
        let threshold = diagnostics["entryThresholdX"] as? CGFloat ?? .greatestFiniteMagnitude

        if mode.contains("remote"), modeAge > 4.0 {
            recoverFromTrap(reason: "watchdog-remote-timeout", turnOffAfterRecovery: false)
            return
        }
        if mode.contains("local"), cursorX >= threshold, started, !completed {
            recoverFromTrap(reason: "watchdog-local-edge-trap", turnOffAfterRecovery: false)
            return
        }
        if started, !completed, CFAbsoluteTimeGetCurrent() - lastProgressAt > 10 {
            recoverFromTrap(reason: "watchdog-no-progress", turnOffAfterRecovery: false)
        }
    }

    private func cleanup(reason: String) {
        writeDiagnostics(reason: "cleanup-before-\(reason)")
        eventTap.emergencyRecover(reason: reason)
        remoteInput.reset()
        send(.release)
        writeDiagnostics(reason: "cleanup-after-\(reason)")
    }

    private func createLogDirectory() {
        try? FileManager.default.createDirectory(at: config.logDirectoryURL, withIntermediateDirectories: true)
    }
}

private final class E2EClipboardWindowController: NSWindowController {
    private let textView = NSTextView(frame: .zero)
    private var expectedByCycle: [Int: String] = [:]
    private var pasteSucceededByCycle: [Int: Bool] = [:]

    init() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NoBarrierMouse E2E Clipboard Target"
        window.contentView = scrollView
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.minX + 180, y: screen.midY - 160))
        } else {
            window.center()
        }

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func preparePaste(cycle: Int, text: String) {
        expectedByCycle[cycle] = text
        pasteSucceededByCycle[cycle] = false

        showAndFocus()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func prepareCopy(cycle: Int) -> Bool {
        showAndFocus()
        let expected = expectedByCycle[cycle] ?? ""
        let pasteSucceeded = textView.string == expected
        pasteSucceededByCycle[cycle] = pasteSucceeded

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("NoBarrierMouse copy pending \(cycle)", forType: .string)
        textView.selectAll(nil)
        return pasteSucceeded
    }

    func validateCopy(cycle: Int) -> (pasteSucceeded: Bool, copySucceeded: Bool, observedLength: Int) {
        let expected = expectedByCycle[cycle] ?? ""
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let pasteSucceeded = pasteSucceededByCycle[cycle] ?? (textView.string == expected)
        let copySucceeded = clipboard == expected
        return (pasteSucceeded, copySucceeded, textView.string.utf8.count)
    }

    private func showAndFocus() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(textView)
    }
}

struct TestModeConfig {
    let enabled: Bool
    let cycles: Int
    let payloadFile: String
    let logDirectoryURL: URL
    let autoStart: Bool

    static func fromArguments() -> TestModeConfig {
        let args = CommandLine.arguments
        let enabled = args.contains("--test-mode")
        let cycles = max(1, intValue(after: "--test-cycles", in: args) ?? 50)
        let payloadFile = stringValue(after: "--test-payload-file", in: args) ?? "/tmp/no-barrier-mouse-e2e-payload.txt"
        let logDirectory = stringValue(after: "--test-log-dir", in: args) ?? "\(NSHomeDirectory())/Desktop/no-barrier-mouse-test-logs"
        let autoStart = !args.contains("--test-no-autostart")
        return TestModeConfig(
            enabled: enabled,
            cycles: cycles,
            payloadFile: payloadFile,
            logDirectoryURL: URL(fileURLWithPath: logDirectory),
            autoStart: autoStart
        )
    }

    private static func stringValue(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func intValue(after flag: String, in args: [String]) -> Int? {
        stringValue(after: flag, in: args).flatMap(Int.init)
    }
}
