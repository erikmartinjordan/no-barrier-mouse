import AppKit

struct SettingsPanelState {
    let role: AppRole?
    let isOn: Bool
    let connectionState: ConnectionState
    let airDropLatencyModeEnabled: Bool
    let airDropIsOff: Bool
    let previewLatency: EndToEndLatencySnapshot?

    init(
        role: AppRole?,
        isOn: Bool,
        connectionState: ConnectionState,
        airDropLatencyModeEnabled: Bool,
        airDropIsOff: Bool,
        previewLatency: EndToEndLatencySnapshot? = nil
    ) {
        self.role = role
        self.isOn = isOn
        self.connectionState = connectionState
        self.airDropLatencyModeEnabled = airDropLatencyModeEnabled
        self.airDropIsOff = airDropIsOff
        self.previewLatency = previewLatency
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let rowWidth: CGFloat = 560
        static let labelWidth: CGFloat = 138
        static let rowGap: CGFloat = 22
        static let contentWidth = rowWidth - labelWidth - rowGap
        static let controllerHeight: CGFloat = 300
        static let receiverHeight: CGFloat = 580
        static let controllerTopInset: CGFloat = 44
        static let receiverTopInset: CGFloat = 72
    }

    var onRoleSelected: ((AppRole) -> Void)?
    var onAirDropLatencyModeChanged: ((Bool) -> Void)?
    var onRunBenchmark: (() -> Void)?

    private let roleControl = NSSegmentedControl(labels: ["Controller", "Receiver"], trackingMode: .selectOne, target: nil, action: nil)
    private let applyRoleButton = NSButton(title: "Apply", target: nil, action: nil)
    private let airDropSwitch = NSSwitch()
    private let airDropStatusLabel = NSTextField(labelWithString: "AirDrop On")
    private let benchmarkButton = NSButton(title: "Run", target: nil, action: nil)
    private let latencyChart = LatencyStatusChartView(frame: .zero)
    private let latencyValueLabel = NSTextField(labelWithString: "-")
    private let latencyStatusLabel = NSTextField(labelWithString: "Waiting")
    private let p50Label = NSTextField(labelWithString: "-")
    private let p90Label = NSTextField(labelWithString: "-")
    private let p99Label = NSTextField(labelWithString: "-")
    private let transportLabel = NSTextField(labelWithString: "No transport")
    private let subtitleLabel = NSTextField(labelWithString: "No role · Off")
    private var receiverOnlyRows: [NSView] = []
    private var latencyRow: NSView?
    private var stackTopConstraint: NSLayoutConstraint?
    private var refreshTimer: Timer?
    private var didCenterWindow = false
    private var state = SettingsPanelState(role: nil, isOn: false, connectionState: .off, airDropLatencyModeEnabled: false, airDropIsOff: false)

    init() {
        let content = NSVisualEffectView()
        content.blendingMode = .behindWindow
        content.material = .windowBackground
        content.state = .active

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: Layout.receiverHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "No Barrier Mouse Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 380)
        window.contentView = content

        super.init(window: window)
        window.delegate = self

        buildInterface(in: content)
        configureActions()
        refreshLatency()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        if !didCenterWindow {
            window?.center()
            didCenterWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startRefreshTimer()
        refreshLatency()
    }

    func update(state: SettingsPanelState) {
        self.state = state
        roleControl.selectedSegment = {
            switch state.role {
            case .controller:
                return 0
            case .receiver:
                return 1
            case nil:
                return -1
            }
        }()
        airDropSwitch.state = state.airDropLatencyModeEnabled ? .on : .off
        benchmarkButton.isEnabled = state.connectionState == .connected && state.role == .receiver
        subtitleLabel.stringValue = subtitle(for: state)
        updateAirDropStatus()
        refreshLatency()
        updateVisibleRows()
    }

    func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }

    private func buildInterface(in content: NSView) {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let title = NSTextField(labelWithString: "No Barrier Mouse")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.alignment = .left
        title.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left

        let header = NSStackView(views: [title, subtitleLabel])
        header.orientation = .vertical
        header.spacing = 5
        header.alignment = .leading
        header.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 30, right: 0)

        let airDropRow = makeAirDropRow()
        let benchmarkRow = makeBenchmarkRow()
        let latencyRow = makeLatencyRow()
        receiverOnlyRows = [airDropRow, benchmarkRow]
        self.latencyRow = latencyRow

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(makeRow(label: "Role", content: makeRoleControls()))
        stack.addArrangedSubview(airDropRow)
        stack.addArrangedSubview(benchmarkRow)
        stack.addArrangedSubview(latencyRow)
        stack.addArrangedSubview(NSView())

        let topConstraint = stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Layout.receiverTopInset)
        stackTopConstraint = topConstraint

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.widthAnchor.constraint(equalToConstant: Layout.rowWidth),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            topConstraint,
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -42)
        ])
    }

    private func makeRoleControls() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        roleControl.segmentStyle = .rounded
        roleControl.controlSize = .small
        roleControl.translatesAutoresizingMaskIntoConstraints = false
        roleControl.heightAnchor.constraint(equalToConstant: 24).isActive = true
        applyRoleButton.bezelStyle = .rounded
        applyRoleButton.controlSize = .small
        applyRoleButton.translatesAutoresizingMaskIntoConstraints = false
        applyRoleButton.widthAnchor.constraint(equalToConstant: 54).isActive = true

        container.addSubview(roleControl)
        container.addSubview(applyRoleButton)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            container.heightAnchor.constraint(equalToConstant: 24),
            roleControl.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            roleControl.trailingAnchor.constraint(equalTo: applyRoleButton.leadingAnchor, constant: -14),
            roleControl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            applyRoleButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            applyRoleButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func makeAirDropRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        airDropStatusLabel.font = .systemFont(ofSize: 12, weight: .bold)
        airDropStatusLabel.alignment = .right
        airDropStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        airDropStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
        airDropSwitch.controlSize = .small
        airDropSwitch.translatesAutoresizingMaskIntoConstraints = false
        airDropSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let description = makeDescription(
            title: "Disable AirDrop while receiving",
            subtitle: "Restores the previous AirDrop mode when turned off."
        )
        description.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(description)
        container.addSubview(airDropStatusLabel)
        container.addSubview(airDropSwitch)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            description.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            description.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            description.trailingAnchor.constraint(lessThanOrEqualTo: airDropStatusLabel.leadingAnchor, constant: -14),
            airDropStatusLabel.trailingAnchor.constraint(equalTo: airDropSwitch.leadingAnchor, constant: -14),
            airDropStatusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            airDropSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            airDropSwitch.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return makeRow(label: "Low Latency", content: container)
    }

    private func makeBenchmarkRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        benchmarkButton.bezelStyle = .rounded
        benchmarkButton.controlSize = .small
        benchmarkButton.translatesAutoresizingMaskIntoConstraints = false
        benchmarkButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let description = makeDescription(
            title: "End-to-end movement test",
            subtitle: "Run from the receiver, then show the summary below."
        )
        description.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(description)
        container.addSubview(benchmarkButton)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            description.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            description.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            description.trailingAnchor.constraint(lessThanOrEqualTo: benchmarkButton.leadingAnchor, constant: -14),
            benchmarkButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            benchmarkButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return makeRow(label: "Benchmark", content: container)
    }

    private func makeLatencyRow() -> NSView {
        latencyValueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        latencyValueLabel.alignment = .right
        latencyStatusLabel.font = .systemFont(ofSize: 11, weight: .bold)
        latencyStatusLabel.alignment = .right

        let valueStack = NSStackView(views: [latencyValueLabel, latencyStatusLabel])
        valueStack.orientation = .vertical
        valueStack.spacing = 4
        valueStack.alignment = .trailing
        valueStack.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [
            makeDescription(title: "Latest benchmark", subtitle: "Controller capture to receiver cursor application."),
            valueStack
        ])
        header.orientation = .horizontal
        header.spacing = 18
        header.alignment = .top
        header.arrangedSubviews.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)

        latencyChart.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let stats = NSStackView(views: [
            makeStatBlock(title: "p50", valueLabel: p50Label),
            makeStatBlock(title: "p90", valueLabel: p90Label),
            makeStatBlock(title: "p99", valueLabel: p99Label)
        ])
        stats.orientation = .horizontal
        stats.spacing = 18
        stats.distribution = .fillEqually
        stats.widthAnchor.constraint(equalToConstant: 300).isActive = true

        transportLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        transportLabel.textColor = .secondaryLabelColor
        transportLabel.alignment = .center

        let content = NSStackView(views: [header, latencyChart, stats, transportLabel])
        content.orientation = .vertical
        content.spacing = 18
        content.alignment = .centerX
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        latencyChart.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return makeRow(label: "Latency", content: content, topAligned: true)
    }

    private func makeRow(label: String, content: NSView, topAligned: Bool = false, verticalPadding: CGFloat = 20) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 22
        row.alignment = topAligned ? .top : .centerY
        row.edgeInsets = NSEdgeInsets(top: topAligned ? 22 : verticalPadding, left: 0, bottom: topAligned ? 24 : verticalPadding, right: 0)
        row.wantsLayer = true
        row.widthAnchor.constraint(equalToConstant: Layout.rowWidth).isActive = true

        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 13, weight: .semibold)
        labelView.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true
        labelView.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(labelView)
        row.addArrangedSubview(content)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.topAnchor.constraint(equalTo: row.topAnchor)
        ])

        return row
    }

    private func makeDescription(title: String, subtitle: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        return stack
    }

    private func makeStatBlock(title: String, valueLabel: NSTextField) -> NSView {
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        valueLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .centerX
        return stack
    }

    private func configureActions() {
        applyRoleButton.target = self
        applyRoleButton.action = #selector(applyRole)
        benchmarkButton.target = self
        benchmarkButton.action = #selector(runBenchmark)
        airDropSwitch.target = self
        airDropSwitch.action = #selector(toggleAirDropLatencyMode)
    }

    @objc private func applyRole() {
        switch roleControl.selectedSegment {
        case 0:
            onRoleSelected?(.controller)
        case 1:
            onRoleSelected?(.receiver)
        default:
            break
        }
    }

    @objc private func runBenchmark() {
        onRunBenchmark?()
    }

    @objc private func toggleAirDropLatencyMode() {
        onAirDropLatencyModeChanged?(airDropSwitch.state == .on)
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshLatency()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func currentLatencySnapshot() -> EndToEndLatencySnapshot {
        state.previewLatency ?? InputMetrics.shared.endToEndLatencySnapshot()
    }

    private func refreshLatency() {
        let snapshot = currentLatencySnapshot()
        latencyChart.snapshot = snapshot
        if snapshot.hasSamples {
            latencyValueLabel.stringValue = formatSettingsMilliseconds(snapshot.last)
            p50Label.stringValue = formatSettingsMilliseconds(snapshot.p50)
            p90Label.stringValue = formatSettingsMilliseconds(snapshot.p90)
            p99Label.stringValue = formatSettingsMilliseconds(snapshot.p99)
            let status = latencyStatus(for: snapshot.last)
            latencyStatusLabel.stringValue = status.title
            latencyStatusLabel.textColor = status.color
        } else {
            latencyValueLabel.stringValue = "-"
            p50Label.stringValue = "-"
            p90Label.stringValue = "-"
            p99Label.stringValue = "-"
            latencyStatusLabel.stringValue = "Waiting"
            latencyStatusLabel.textColor = .secondaryLabelColor
        }
        transportLabel.stringValue = InputMetrics.shared.statusSnapshot().transport
        updateVisibleRows()
    }

    private func updateVisibleRows() {
        let showReceiverControls = state.role == .receiver
        for row in receiverOnlyRows {
            row.isHidden = !showReceiverControls
        }
        latencyRow?.isHidden = !showReceiverControls || !currentLatencySnapshot().hasSamples
        stackTopConstraint?.constant = showReceiverControls ? Layout.receiverTopInset : Layout.controllerTopInset
        resizeWindowIfNeeded(height: showReceiverControls ? Layout.receiverHeight : Layout.controllerHeight)
    }

    private func resizeWindowIfNeeded(height: CGFloat) {
        guard let window else {
            return
        }
        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        guard abs(currentContentSize.height - height) > 1 else {
            return
        }

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: currentContentSize.width, height: height)))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    private func updateAirDropStatus() {
        let isOff = state.role == .receiver && state.airDropIsOff
        airDropStatusLabel.stringValue = isOff ? "AirDrop Off" : "AirDrop On"
        airDropStatusLabel.textColor = isOff ? .systemGreen : .secondaryLabelColor
    }

    private func subtitle(for state: SettingsPanelState) -> String {
        let role = state.role?.description ?? "No role"
        switch state.connectionState {
        case .off:
            return "\(role) · Off"
        case .waiting:
            return "\(role) · Waiting"
        case .connecting:
            return "\(role) · Handshaking"
        case .connected:
            return "\(role) · Connected"
        }
    }
}

private final class LatencyStatusChartView: NSView {
    var snapshot = EndToEndLatencySnapshot.empty {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let values = Array(snapshot.values.suffix(32))
        let count = 32
        let gap: CGFloat = 3
        let labelHeight: CGFloat = 15
        let barHeight: CGFloat = 25
        let chartRect = bounds.insetBy(dx: 2, dy: 0)
        let barWidth = max(3, (chartRect.width - CGFloat(count - 1) * gap) / CGFloat(count))
        let barY = chartRect.minY + labelHeight + 7

        drawChartLabels(in: NSRect(x: chartRect.minX, y: chartRect.minY, width: chartRect.width, height: labelHeight), count: count, barWidth: barWidth, gap: gap)

        let missing = count - values.count
        for index in 0..<count {
            let x = chartRect.minX + CGFloat(index) * (barWidth + gap)
            let rect = NSRect(x: x, y: barY, width: barWidth, height: barHeight)
            let color: NSColor
            if snapshot.hasSamples, index >= missing {
                color = latencyStatus(for: values[index - missing]).color
            } else {
                color = NSColor.tertiaryLabelColor.withAlphaComponent(0.22)
            }
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            color.withAlphaComponent(0.92).setFill()
            path.fill()
        }

        drawScaleLabels(in: NSRect(x: chartRect.minX, y: barY + barHeight + 9, width: chartRect.width, height: 14))
    }

    private func drawChartLabels(in rect: NSRect, count: Int, barWidth: CGFloat, gap: CGFloat) {
        for index in stride(from: 2, to: count, by: 2) {
            let x = rect.minX + CGFloat(index) * (barWidth + gap) - 5
            drawText(
                "\(index + 2)",
                in: NSRect(x: x, y: rect.minY + 3, width: 16, height: 10),
                font: .monospacedDigitSystemFont(ofSize: 8, weight: .bold),
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    private func drawScaleLabels(in rect: NSRect) {
        let width = rect.width / 4
        let labels = ["Smooth", "Noticeable", "Laggy", "Spike"]
        for (index, label) in labels.enumerated() {
            drawText(
                label,
                in: NSRect(x: rect.minX + CGFloat(index) * width, y: rect.minY, width: width, height: rect.height),
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private func latencyStatus(for milliseconds: Double) -> (title: String, color: NSColor) {
    if milliseconds <= 10 {
        return ("Smooth", .systemGreen)
    }
    if milliseconds <= 20 {
        return ("Noticeable", .systemYellow)
    }
    if milliseconds <= 35 {
        return ("Laggy", .systemOrange)
    }
    return ("Spike", .systemRed)
}

private func formatSettingsMilliseconds(_ milliseconds: Double) -> String {
    if milliseconds < 0 {
        return "-"
    }
    if milliseconds < 0.1 {
        return String(format: "%.0f us", milliseconds * 1000)
    }
    if milliseconds < 10 {
        return String(format: "%.1f ms", milliseconds)
    }
    return String(format: "%.0f ms", milliseconds)
}
