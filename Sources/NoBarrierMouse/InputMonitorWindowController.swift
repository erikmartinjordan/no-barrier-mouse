import AppKit
import Darwin

final class InputMonitorWindowController: NSWindowController, NSWindowDelegate {
    private let monitorView: InputMonitorView
    private var refreshTimer: Timer?
    private var didCenterWindow = false

    init() {
        let view = InputMonitorView(frame: NSRect(x: 0, y: 0, width: 1220, height: 760))
        let glassRoot = NSVisualEffectView(frame: view.bounds)
        glassRoot.autoresizingMask = [.width, .height]
        glassRoot.blendingMode = .behindWindow
        glassRoot.material = .popover
        glassRoot.state = .active
        glassRoot.wantsLayer = true
        glassRoot.layer?.cornerRadius = 26
        glassRoot.layer?.masksToBounds = true

        view.autoresizingMask = [.width, .height]
        glassRoot.addSubview(view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Input Quality Monitor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 980, height: 620)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = glassRoot

        monitorView = view
        super.init(window: window)
        window.delegate = self
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
        monitorView.needsDisplay = true
    }

    func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.monitorView.needsDisplay = true
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

private final class InputMonitorView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        MonitorPalette.isDark = effectiveAppearance.name == .darkAqua || effectiveAppearance.name == .vibrantDark

        super.draw(dirtyRect)

        let allSnapshots = InputMetrics.shared.snapshots()
        let snapshots = InputMetricID.visibleCases.compactMap { id in
            allSnapshots.first { $0.id == id }
        }
        let status = InputMetrics.shared.statusSnapshot()
        let activeSnapshots = snapshots.filter(\.hasSamples)
        let score = qualityScore(for: activeSnapshots)
        let worst = activeSnapshots.min { qualityScore(for: [$0]) < qualityScore(for: [$1]) }

        let shell = bounds.insetBy(dx: 6, dy: 6)
        let titlebar = NSRect(x: shell.minX, y: shell.minY, width: shell.width, height: 56)
        drawTitlebar(in: titlebar)

        let body = NSRect(x: shell.minX + 16, y: titlebar.maxY + 14, width: shell.width - 32, height: shell.maxY - titlebar.maxY - 66)
        let footer = NSRect(x: shell.minX + 16, y: body.maxY + 14, width: shell.width - 32, height: 28)

        let statusText = status.issue ?? "\(status.state) (\(status.role))"
        drawText(statusText, in: NSRect(x: footer.minX, y: footer.minY, width: 260, height: 20), font: .systemFont(ofSize: 11, weight: .medium), color: MonitorPalette.muted)
        drawText(status.transport, in: NSRect(x: footer.midX - 190, y: footer.minY, width: 380, height: 20), font: .systemFont(ofSize: 11, weight: .medium), color: transportColor(status.transport), alignment: .center)
        drawText("Quality \(Int(score.rounded()))", in: NSRect(x: footer.maxX - 120, y: footer.minY, width: 120, height: 20), font: .systemFont(ofSize: 11, weight: .medium), color: MonitorPalette.muted, alignment: .right)
        let sidebarWidth = min(230, max(190, body.width * 0.20))
        let detailWidth = min(360, max(300, body.width * 0.30))
        let gap: CGFloat = 14

        let sidebarRect = NSRect(x: body.minX, y: body.minY, width: sidebarWidth, height: body.height)
        let detailRect = NSRect(x: body.maxX - detailWidth, y: body.minY, width: detailWidth, height: body.height)
        let pipelineRect = NSRect(
            x: sidebarRect.maxX + gap,
            y: body.minY,
            width: max(320, detailRect.minX - sidebarRect.maxX - gap * 2),
            height: body.height
        )

        drawSidebar(in: sidebarRect, status: status, snapshots: snapshots)
        drawPipeline(in: pipelineRect, status: status, snapshots: snapshots)
        drawDetail(in: detailRect, snapshots: activeSnapshots, worst: worst, score: score)
    }

    private func drawTitlebar(in rect: NSRect) {
        drawText("Input Quality Monitor", in: NSRect(x: rect.midX - 130, y: rect.minY + 18, width: 260, height: 20), font: .systemFont(ofSize: 13, weight: .semibold), color: MonitorPalette.titleText, alignment: .center)
    }

    private func drawSidebar(in rect: NSRect, status: InputMonitorStatusSnapshot, snapshots: [InputMetricSnapshot]) {
        drawText("Signal", in: NSRect(x: rect.minX + 18, y: rect.minY + 20, width: rect.width - 36, height: 24), font: .systemFont(ofSize: 20, weight: .semibold), color: MonitorPalette.text)
        drawText(status.role, in: NSRect(x: rect.minX + 18, y: rect.minY + 48, width: rect.width - 36, height: 18), font: .systemFont(ofSize: 12, weight: .medium), color: MonitorPalette.muted)
        drawText(status.transport, in: NSRect(x: rect.minX + 18, y: rect.minY + 66, width: rect.width - 36, height: 16), font: .systemFont(ofSize: 10.5, weight: .medium), color: transportColor(status.transport))

        var y = rect.minY + 92
        for stage in InputMetricStage.allCases {
            let stageSnapshots = snapshots.filter { $0.id.stage == stage }
            let sampled = stageSnapshots.filter(\.hasSamples)
            let stageScore = qualityScore(for: sampled)

            drawText(stage.rawValue, in: NSRect(x: rect.minX + 18, y: y, width: rect.width - 36, height: 20), font: .systemFont(ofSize: 14, weight: .semibold), color: MonitorPalette.text)

            let subtitle = sampled.isEmpty ? "No local samples" : "\(sampled.reduce(0) { $0 + $1.count }) samples"
            drawText(subtitle, in: NSRect(x: rect.minX + 18, y: y + 22, width: rect.width - 36, height: 16), font: .systemFont(ofSize: 11, weight: .regular), color: MonitorPalette.muted)

            let bar = NSRect(x: rect.minX + 18, y: y + 46, width: rect.width - 36, height: 5)
            drawScoreBar(in: bar, score: sampled.isEmpty ? 0 : stageScore, empty: sampled.isEmpty)
            y += 70
        }
    }

    private func drawPipeline(in rect: NSRect, status: InputMonitorStatusSnapshot, snapshots: [InputMetricSnapshot]) {
        drawText("Pipeline Trace", in: NSRect(x: rect.minX + 20, y: rect.minY + 18, width: 240, height: 24), font: .systemFont(ofSize: 20, weight: .semibold), color: MonitorPalette.text)
        drawText("congestion timing, p95, live on this Mac", in: NSRect(x: rect.minX + 20, y: rect.minY + 45, width: 320, height: 18), font: .systemFont(ofSize: 12, weight: .medium), color: MonitorPalette.muted)

        let heroRect = NSRect(x: rect.minX + 16, y: rect.minY + 76, width: rect.width - 32, height: min(178, max(142, rect.height * 0.28)))
        drawTopologyHero(in: heroRect, status: status, snapshots: snapshots)

        let listTop = heroRect.maxY + 12
        let listHeight = rect.maxY - listTop - 16
        let rowHeight = min(50, listHeight / CGFloat(max(snapshots.count, 1)))
        var y = listTop

        for snapshot in snapshots {
            drawMetricRow(snapshot, in: NSRect(x: rect.minX + 16, y: y, width: rect.width - 32, height: rowHeight - 4))
            y += rowHeight
        }
    }

    private enum NodeIcon {
        case computer
        case router
    }

    private func drawTopologyHero(in rect: NSRect, status: InputMonitorStatusSnapshot, snapshots: [InputMetricSnapshot]) {
        drawText("LIVE PATH", in: NSRect(x: rect.minX + 18, y: rect.minY + 16, width: 120, height: 16), font: .systemFont(ofSize: 10, weight: .bold), color: MonitorPalette.faint)
        drawText("iMac -> \(status.transport) -> MacBook Air", in: NSRect(x: rect.minX + 18, y: rect.minY + 34, width: rect.width - 36, height: 20), font: .systemFont(ofSize: 12, weight: .medium), color: transportColor(status.transport))

        let nodeWidth = min(136, max(108, (rect.width - 110) / 3))
        let nodeHeight: CGFloat = 80
        let nodeY = rect.maxY - nodeHeight
        let controllerRect = NSRect(x: rect.minX + 28, y: nodeY, width: nodeWidth, height: nodeHeight)
        let networkRect = NSRect(x: rect.midX - nodeWidth / 2, y: nodeY, width: nodeWidth, height: nodeHeight)
        let receiverRect = NSRect(x: rect.maxX - nodeWidth - 28, y: nodeY, width: nodeWidth, height: nodeHeight)

        let controller = stageSummary(.controller, snapshots: snapshots)
        let network = snapshots.first { $0.id == .mouseArrivalGap && $0.hasSamples }?.p95
        let receiver = stageSummary(.receiver, snapshots: snapshots)

        drawFlow(from: NSPoint(x: controllerRect.maxX, y: controllerRect.midY), to: NSPoint(x: networkRect.minX, y: networkRect.midY))
        drawFlow(from: NSPoint(x: networkRect.maxX, y: networkRect.midY), to: NSPoint(x: receiverRect.minX, y: receiverRect.midY))

        drawStageNode(title: "Controller", value: controller, rect: controllerRect, icon: .computer)
        drawStageNode(title: "Packet gap", value: network, rect: networkRect, icon: .router)
        drawStageNode(title: "Receiver", value: receiver, rect: receiverRect, icon: .computer)
    }

    private func drawStageNode(title: String, value: Double?, rect: NSRect, icon: NodeIcon) {
        let iconRect = NSRect(x: rect.midX - 16, y: rect.minY + 4, width: 32, height: 28)
        switch icon {
        case .computer:
            drawComputerIcon(in: iconRect)
        case .router:
            drawRouterIcon(in: iconRect)
        }

        drawText(title, in: NSRect(x: rect.minX + 6, y: rect.minY + 34, width: rect.width - 12, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: MonitorPalette.muted, alignment: .center)
        drawText(value.map { format(milliseconds: $0) } ?? "-", in: NSRect(x: rect.minX + 6, y: rect.minY + 52, width: rect.width - 12, height: 24), font: .monospacedDigitSystemFont(ofSize: 19, weight: .semibold), color: MonitorPalette.text, alignment: .center)
    }

    private func drawComputerIcon(in rect: NSRect) {
        let c = MonitorPalette.faint
        let screenRect = NSRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2, height: rect.height - 12)
        let screen = NSBezierPath(roundedRect: screenRect, xRadius: 2.5, yRadius: 2.5)
        screen.lineWidth = 1.5
        c.setStroke()
        screen.stroke()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: rect.midX - 3, y: screenRect.maxY))
        stand.line(to: NSPoint(x: rect.midX + 3, y: screenRect.maxY))
        stand.line(to: NSPoint(x: rect.midX + 2, y: rect.maxY - 4))
        stand.line(to: NSPoint(x: rect.midX - 2, y: rect.maxY - 4))
        stand.close()
        c.withAlphaComponent(0.45).setFill()
        stand.fill()

        let base = NSBezierPath(roundedRect: NSRect(x: rect.midX - 9, y: rect.maxY - 3, width: 18, height: 2.5), xRadius: 1, yRadius: 1)
        c.withAlphaComponent(0.25).setFill()
        base.fill()
    }

    private func drawRouterIcon(in rect: NSRect) {
        let c = MonitorPalette.faint
        let bodyRect = NSRect(x: rect.minX + 3, y: rect.maxY - rect.height * 0.5 - 4, width: rect.width - 6, height: rect.height * 0.5)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 3.5, yRadius: 3.5)
        body.lineWidth = 1.5
        c.setStroke()
        body.stroke()

        let ant1 = NSBezierPath()
        ant1.move(to: NSPoint(x: rect.minX + rect.width * 0.3, y: bodyRect.minY))
        ant1.line(to: NSPoint(x: rect.minX + rect.width * 0.22, y: rect.minY))
        ant1.lineWidth = 1.5
        c.withAlphaComponent(0.45).setStroke()
        ant1.stroke()

        let ant2 = NSBezierPath()
        ant2.move(to: NSPoint(x: rect.minX + rect.width * 0.7, y: bodyRect.minY))
        ant2.line(to: NSPoint(x: rect.minX + rect.width * 0.78, y: rect.minY))
        ant2.lineWidth = 1.5
        c.withAlphaComponent(0.45).setStroke()
        ant2.stroke()
    }

    private func drawFlow(from start: NSPoint, to end: NSPoint) {
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: end)
        MonitorPalette.faint.setStroke()
        line.lineCapStyle = .round
        line.lineWidth = 1.5
        line.stroke()
    }

    private func drawDetail(in rect: NSRect, snapshots: [InputMetricSnapshot], worst: InputMetricSnapshot?, score: Double) {
        drawText("Session Detail", in: NSRect(x: rect.minX + 20, y: rect.minY + 18, width: rect.width - 40, height: 22), font: .systemFont(ofSize: 17, weight: .semibold), color: MonitorPalette.text)
        drawText("Input quality score", in: NSRect(x: rect.minX + 20, y: rect.minY + 45, width: rect.width - 40, height: 18), font: .systemFont(ofSize: 12, weight: .medium), color: MonitorPalette.muted)

        let scoreRect = NSRect(x: rect.minX + 24, y: rect.minY + 86, width: 128, height: 128)
        drawScoreRing(in: scoreRect, score: score)
        drawText("\(Int(score.rounded()))", in: NSRect(x: scoreRect.minX, y: scoreRect.minY + 42, width: scoreRect.width, height: 42), font: .monospacedDigitSystemFont(ofSize: 38, weight: .semibold), color: MonitorPalette.text, alignment: .center)
        drawText("/100", in: NSRect(x: scoreRect.minX, y: scoreRect.minY + 82, width: scoreRect.width, height: 18), font: .systemFont(ofSize: 12, weight: .medium), color: MonitorPalette.muted, alignment: .center)

        let status = qualityLabel(score)
        drawText(status.title, in: NSRect(x: rect.minX + 174, y: rect.minY + 100, width: rect.width - 198, height: 24), font: .systemFont(ofSize: 18, weight: .semibold), color: MonitorPalette.text)
        drawText(status.subtitle, in: NSRect(x: rect.minX + 174, y: rect.minY + 132, width: rect.width - 198, height: 54), font: .systemFont(ofSize: 12, weight: .regular), color: MonitorPalette.muted, lineBreak: .byWordWrapping)

        let metric = worst ?? snapshots.first
        let cardsTop = rect.minY + 242
        drawSummaryCards(for: metric, in: NSRect(x: rect.minX + 18, y: cardsTop, width: rect.width - 36, height: 82))

        let traceRect = NSRect(x: rect.minX + 18, y: cardsTop + 106, width: rect.width - 36, height: 150)
        drawText(metric?.id.title ?? "Waiting", in: NSRect(x: traceRect.minX + 16, y: traceRect.minY + 14, width: traceRect.width - 32, height: 20), font: .systemFont(ofSize: 14, weight: .semibold), color: MonitorPalette.text)
        drawText(metric?.id.detail ?? "No samples yet", in: NSRect(x: traceRect.minX + 16, y: traceRect.minY + 36, width: traceRect.width - 32, height: 18), font: .systemFont(ofSize: 11, weight: .regular), color: MonitorPalette.muted)
        drawBars(values: metric?.values ?? [], metric: metric?.id ?? .lanRTT, in: NSRect(x: traceRect.minX + 16, y: traceRect.minY + 50, width: traceRect.width - 32, height: 70), compact: false)

        if score > 0, let metric {
            drawText("P95 \(format(value: metric.p95, for: metric.id))", in: NSRect(x: traceRect.minX + 16, y: traceRect.maxY - 22, width: 120, height: 16), font: .systemFont(ofSize: 10, weight: .medium), color: MonitorPalette.faint)
        }

        drawText("Bottleneck", in: NSRect(x: rect.minX + 18, y: rect.maxY - 38, width: 100, height: 20), font: .systemFont(ofSize: 13, weight: .semibold), color: MonitorPalette.text)

        if let worst {
            let text = "\(worst.id.title) is currently the roughest stage at p95 \(format(value: worst.p95, for: worst.id))."
            drawText(text, in: NSRect(x: rect.minX + 110, y: rect.maxY - 38, width: rect.width - 130, height: 20), font: .systemFont(ofSize: 12, weight: .regular), color: MonitorPalette.muted, lineBreak: .byWordWrapping)
        } else {
            drawText("Move the mouse through the remote screen to start the trace.", in: NSRect(x: rect.minX + 18, y: rect.maxY - 38, width: rect.width - 36, height: 20), font: .systemFont(ofSize: 12, weight: .regular), color: MonitorPalette.muted, lineBreak: .byWordWrapping)
        }
    }

    private func drawMetricRow(_ snapshot: InputMetricSnapshot, in rect: NSRect) {
        drawText(snapshot.id.title, in: NSRect(x: rect.minX + 16, y: rect.minY + 10, width: 170, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: MonitorPalette.text)
        drawText(snapshot.id.detail, in: NSRect(x: rect.minX + 16, y: rect.minY + 28, width: 190, height: 16), font: .systemFont(ofSize: 10.5, weight: .regular), color: MonitorPalette.muted)

        let statsX = rect.maxX - 124
        if snapshot.hasSamples {
            drawText("P95", in: NSRect(x: statsX, y: rect.minY + 9, width: 42, height: 14), font: .systemFont(ofSize: 9, weight: .bold), color: MonitorPalette.faint)
            drawText(format(value: snapshot.p95, for: snapshot.id), in: NSRect(x: statsX, y: rect.minY + 23, width: 98, height: 24), font: .monospacedDigitSystemFont(ofSize: 18, weight: .semibold), color: MonitorPalette.text)
        } else {
            drawText("No samples", in: NSRect(x: statsX, y: rect.minY + 20, width: 100, height: 18), font: .systemFont(ofSize: 12, weight: .medium), color: MonitorPalette.faint)
        }

        let barRect = NSRect(x: rect.minX + 232, y: rect.minY + 14, width: max(80, rect.width - 380), height: rect.height - 26)
        drawBars(values: snapshot.values, metric: snapshot.id, in: barRect, compact: true)
    }

    private func drawSummaryCards(for snapshot: InputMetricSnapshot?, in rect: NSRect) {
        let gap: CGFloat = 8
        let cardWidth = (rect.width - gap * 3) / 4
        let items: [(String, String)] = {
            guard let snapshot else {
                return [("P50", "-"), ("P95", "-"), ("MAX", "-"), ("N", "0")]
            }
            return [
                ("P50", format(value: snapshot.p50, for: snapshot.id)),
                ("P95", format(value: snapshot.p95, for: snapshot.id)),
                ("MAX", format(value: snapshot.max, for: snapshot.id)),
                ("N", "\(snapshot.count)")
            ]
        }()

        for index in 0..<items.count {
            let card = NSRect(x: rect.minX + CGFloat(index) * (cardWidth + gap), y: rect.minY, width: cardWidth, height: rect.height)
            drawText(items[index].0, in: NSRect(x: card.minX, y: card.minY + 13, width: card.width, height: 14), font: .systemFont(ofSize: 9, weight: .bold), color: MonitorPalette.faint)
            drawText(items[index].1, in: NSRect(x: card.minX, y: card.minY + 30, width: card.width, height: 24), font: .monospacedDigitSystemFont(ofSize: 17, weight: .semibold), color: MonitorPalette.text)
        }
    }

    private func drawBars(values: [Double], metric: InputMetricID, in rect: NSRect, compact: Bool) {
        let barCount = min(compact ? 54 : 72, max(18, Int(rect.width / (compact ? 6 : 5))))
        let gap: CGFloat = compact ? 3 : 2.5
        let barWidth = max(2.4, min(compact ? 4.6 : 4.0, (rect.width - CGFloat(barCount - 1) * gap) / CGFloat(barCount)))
        let scaleMax = max(metric.fairMilliseconds * 1.7, values.max() ?? metric.fairMilliseconds, 0.1)

        if values.isEmpty {
            for index in 0..<barCount {
                let x = rect.minX + CGFloat(index) * (barWidth + gap)
                let h = CGFloat(4 + (index % 5)) * (compact ? 0.7 : 1.0)
                let bar = NSRect(x: x, y: rect.maxY - h, width: barWidth, height: h)
                drawRounded(bar, radius: barWidth / 2, fill: MonitorPalette.ghost)
            }
            return
        }

        let shownValues = Array(values.suffix(barCount))
        let missing = barCount - shownValues.count
        for index in 0..<barCount {
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            guard index >= missing else {
                let bar = NSRect(x: x, y: rect.maxY - 3, width: barWidth, height: 3)
                drawRounded(bar, radius: barWidth / 2, fill: MonitorPalette.ghost)
                continue
            }

            let value = shownValues[index - missing]
            let ratio = min(1, log1p(value) / log1p(scaleMax))
            let height = max(compact ? 5 : 7, CGFloat(ratio) * rect.height)
            let bar = NSRect(x: x, y: rect.maxY - height, width: barWidth, height: height)
            drawRounded(bar, radius: barWidth / 2, fill: valueColor(value, metric: metric).withAlphaComponent(0.88))
        }
    }

    private func drawScoreRing(in rect: NSRect, score: Double) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 10
        let base = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        base.lineWidth = 10
        (MonitorPalette.isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.40)).setStroke()
        base.stroke()

        let start: CGFloat = 90
        let end = start - CGFloat(max(0, min(100, score)) / 100.0) * 360
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        arc.lineCapStyle = .round
        arc.lineWidth = 10
        scoreColor(score).setStroke()
        arc.stroke()
    }

    private func drawScoreBar(in rect: NSRect, score: Double, empty: Bool) {
        drawRounded(rect, radius: rect.height / 2, fill: MonitorPalette.isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.30))
        guard !empty else { return }
        let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(max(0, min(100, score)) / 100.0), height: rect.height)
        drawRounded(fill, radius: fill.height / 2, fill: scoreColor(score))
    }

    private func drawRounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
    }

    private func drawGlass(_ rect: NSRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowColor = MonitorPalette.isDark ? NSColor.black.withAlphaComponent(0.30) : NSColor.black.withAlphaComponent(0.08)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        MonitorPalette.panel.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        MonitorPalette.panel.setFill()
        path.fill()

        let gradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(MonitorPalette.isDark ? 0.10 : 0.50),
            NSColor.white.withAlphaComponent(MonitorPalette.isDark ? 0.03 : 0.20),
            NSColor.white.withAlphaComponent(MonitorPalette.isDark ? 0.01 : 0.04)
        ])
        gradient?.draw(in: path, angle: 270)

        NSGraphicsContext.restoreGraphicsState()

        MonitorPalette.stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: rect.minX + radius * 0.6, y: rect.minY + 1))
        highlight.line(to: NSPoint(x: rect.maxX - radius * 0.6, y: rect.minY + 1))
        NSColor.white.withAlphaComponent(MonitorPalette.isDark ? 0.12 : 0.50).setStroke()
        highlight.lineCapStyle = .round
        highlight.lineWidth = 1
        highlight.stroke()
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineBreak: NSLineBreakMode = .byTruncatingTail
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

private enum MonitorPalette {
    static var isDark = false

    static var panel: NSColor {
        isDark ? NSColor(calibratedWhite: 0, alpha: 0.35) : NSColor(calibratedWhite: 1, alpha: 0.35)
    }
    static var panelRaised: NSColor {
        isDark ? NSColor(calibratedWhite: 0.12, alpha: 0.40) : NSColor(calibratedWhite: 1, alpha: 0.50)
    }
    static var stroke: NSColor {
        isDark ? NSColor(calibratedWhite: 1, alpha: 0.18) : NSColor(calibratedWhite: 1, alpha: 0.55)
    }
    static var softStroke: NSColor {
        isDark ? NSColor(calibratedWhite: 1, alpha: 0.08) : NSColor(calibratedWhite: 1, alpha: 0.30)
    }
    static var text: NSColor {
        isDark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.20, alpha: 1)
    }
    static var titleText: NSColor {
        isDark ? NSColor(calibratedWhite: 0.85, alpha: 1) : NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.17, alpha: 1)
    }
    static var muted: NSColor {
        isDark ? NSColor(calibratedWhite: 0.55, alpha: 1) : NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
    }
    static var faint: NSColor {
        isDark ? NSColor(calibratedWhite: 0.40, alpha: 1) : NSColor(calibratedRed: 0.52, green: 0.55, blue: 0.60, alpha: 1)
    }
    static var ghost: NSColor {
        isDark ? NSColor(calibratedWhite: 1, alpha: 0.08) : NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0.06)
    }
    static let green = NSColor(calibratedRed: 0.32, green: 0.78, blue: 0.45, alpha: 1)
    static let yellow = NSColor(calibratedRed: 0.92, green: 0.68, blue: 0.18, alpha: 1)
    static let red = NSColor(calibratedRed: 0.90, green: 0.30, blue: 0.34, alpha: 1)
    static let coral = NSColor(calibratedRed: 0.92, green: 0.42, blue: 0.48, alpha: 1)
    static let cyan = NSColor(calibratedRed: 0.25, green: 0.68, blue: 0.92, alpha: 1)
    static let purple = NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.96, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.92, alpha: 1)
}

private func format(milliseconds: Double) -> String {
    if milliseconds <= 0 {
        return "-"
    }
    if milliseconds < 1 {
        return "\(Int((milliseconds * 1000).rounded()))us"
    }
    if milliseconds < 10 {
        return String(format: "%.1fms", milliseconds)
    }
    if milliseconds < 100 {
        return String(format: "%.0fms", milliseconds)
    }
    return String(format: "%.0fms", milliseconds)
}

private func format(value: Double, for metric: InputMetricID) -> String {
    format(milliseconds: value)
}

private func stageSummary(_ stage: InputMetricStage, snapshots: [InputMetricSnapshot]) -> Double? {
    let stageSnapshots = snapshots.filter { $0.id.stage == stage && $0.hasSamples }
    return stageSnapshots.min { lhs, rhs in
        qualityScore(for: lhs) < qualityScore(for: rhs)
    }?.p95
}

private func transportColor(_ transport: String) -> NSColor {
    let value = transport.lowercased()
    if value.contains("direct") || value.contains("awdl") || value.contains("peer") {
        return MonitorPalette.green
    }
    if value.contains("ethernet") {
        return MonitorPalette.cyan
    }
    if value.contains("router") || value.contains("wifi") {
        return MonitorPalette.yellow
    }
    return MonitorPalette.muted
}

private func valueColor(_ value: Double, metric: InputMetricID) -> NSColor {
    if value <= metric.goodMilliseconds {
        return MonitorPalette.green
    }
    if value <= metric.fairMilliseconds {
        return MonitorPalette.yellow
    }
    return MonitorPalette.red
}

private func qualityScore(for snapshots: [InputMetricSnapshot]) -> Double {
    let active = snapshots.filter(\.hasSamples)
    guard !active.isEmpty else { return 0 }
    let total = active.reduce(0.0) { partial, snapshot in
        partial + qualityScore(for: snapshot)
    }
    return total / Double(active.count)
}

private func qualityScore(for snapshot: InputMetricSnapshot) -> Double {
    guard snapshot.hasSamples else { return 0 }
    let value = snapshot.p95
    let good = snapshot.id.goodMilliseconds
    let fair = snapshot.id.fairMilliseconds

    if value <= good {
        let ratio = good <= 0 ? 0 : value / good
        return max(90, 100 - ratio * 8)
    }
    if value <= fair {
        let ratio = (value - good) / max(fair - good, 0.001)
        return max(62, 90 - ratio * 28)
    }

    let overflow = min(12, value / max(fair, 0.001))
    return max(8, 62 - log2(overflow) * 18)
}

private func scoreColor(_ score: Double) -> NSColor {
    if score >= 80 {
        return MonitorPalette.green
    }
    if score >= 58 {
        return MonitorPalette.yellow
    }
    return MonitorPalette.red
}

private func qualityLabel(_ score: Double) -> (title: String, subtitle: String, color: NSColor) {
    if score >= 80 {
        return ("Smooth", "The current pipeline is inside the target range for pointer and keyboard.", MonitorPalette.green)
    }
    if score >= 58 {
        return ("Watch", "One or more stages are drifting. The detail trace below shows the most likely source.", MonitorPalette.yellow)
    }
    if score > 0 {
        return ("Rough", "Latency or jitter is high enough to feel uneven. Use the highlighted stage as the next target.", MonitorPalette.red)
    }
    return ("Waiting", "Start a remote input session and move through the secondary display to populate live samples.", MonitorPalette.faint)
}
