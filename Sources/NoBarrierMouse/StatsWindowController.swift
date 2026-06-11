import AppKit

final class StatsWindowController: NSWindowController {
    private let refreshInterval: TimeInterval = 1.0
    private var refreshTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Latency Statistics"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = StatsView(frame: window.contentRect(forFrameRect: window.frame))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshNow()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    override func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        LatencyTracker.shared.resetCumulative()
        super.close()
    }

    private func refreshNow() {
        LatencyTracker.shared.snapshot { [weak self] snap in
            guard let view = self?.window?.contentView as? StatsView else { return }
            view.snapshot = snap
            view.needsDisplay = true
        }
    }
}

private final class StatsView: NSView {
    var snapshot: LatencyTracker.FullSnapshot?

    private let padding = CGFloat(24)
    private let panelGap = CGFloat(18)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        guard let snapshot else { return }

        let content = bounds.insetBy(dx: padding, dy: padding)
        let panelHeight = (content.height - panelGap) / 2
        let top = NSRect(x: content.minX, y: content.minY, width: content.width, height: panelHeight)
        let bottom = NSRect(x: content.minX, y: top.maxY + panelGap, width: content.width, height: panelHeight)

        drawPanel(
            in: top,
            title: "Capture → Send",
            subtitle: "Controller-side capture, batching, encoding and socket send",
            metric: snapshot.captureToSend,
            emptyText: "No controller samples yet on this Mac"
        )
        drawPanel(
            in: bottom,
            title: "Receive → Apply",
            subtitle: "Receiver-side socket read, decode and CGEvent application",
            metric: snapshot.receiveToApply,
            emptyText: "No receiver samples yet on this Mac"
        )
    }

    private func drawPanel(
        in rect: NSRect,
        title: String,
        subtitle: String,
        metric: LatencyTracker.MetricSnapshot?,
        emptyText: String
    ) {
        let radius = CGFloat(8)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.controlBackgroundColor.setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        title.draw(at: NSPoint(x: rect.minX + 18, y: rect.minY + 14), withAttributes: titleAttrs)

        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        subtitle.draw(at: NSPoint(x: rect.minX + 18, y: rect.minY + 38), withAttributes: subtitleAttrs)

        guard let metric else {
            drawEmpty(in: rect, text: emptyText)
            return
        }

        drawMetricStrip(in: rect, metric: metric)
        drawHistogram(in: rect.insetBy(dx: 18, dy: 0), metric: metric)
    }

    private func drawMetricStrip(in rect: NSRect, metric: LatencyTracker.MetricSnapshot) {
        let values = [
            ("p50", fmt(metric.p50)),
            ("p90", fmt(metric.p90)),
            ("p99", fmt(metric.p99)),
            ("max", fmt(metric.max)),
            ("n", "\(metric.count)")
        ]

        let top = rect.minY + 62
        let boxWidth = min((rect.width - 36 - CGFloat(values.count - 1) * 8) / CGFloat(values.count), 118)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        for (index, value) in values.enumerated() {
            let x = rect.minX + 18 + CGFloat(index) * (boxWidth + 8)
            let box = NSRect(x: x, y: top, width: boxWidth, height: 44)
            let boxPath = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            NSColor.textBackgroundColor.withAlphaComponent(0.65).setFill()
            boxPath.fill()
            value.0.uppercased().draw(at: NSPoint(x: box.minX + 10, y: box.minY + 6), withAttributes: labelAttrs)
            value.1.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 20), withAttributes: valueAttrs)
        }
    }

    private func drawHistogram(in rect: NSRect, metric: LatencyTracker.MetricSnapshot) {
        let top = rect.minY + 126
        let bottom = rect.maxY - 32
        let labelY = rect.maxY - 19
        let height = max(12, bottom - top)
        let buckets = metric.buckets
        let barGap = CGFloat(5)
        let barWidth = max(14, (rect.width - CGFloat(buckets.count - 1) * barGap) / CGFloat(buckets.count))
        let maxCount = max(1, buckets.map(\.count).max() ?? 1)

        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX, y: bottom))
        baseline.line(to: NSPoint(x: rect.maxX, y: bottom))
        NSColor.separatorColor.setStroke()
        baseline.lineWidth = 1
        baseline.stroke()

        for (index, bucket) in buckets.enumerated() {
            let x = rect.minX + CGFloat(index) * (barWidth + barGap)
            let normalized = CGFloat(bucket.count) / CGFloat(maxCount)
            let barHeight = bucket.count == 0 ? 0 : max(2, normalized * height)
            let barRect = NSRect(x: x, y: bottom - barHeight, width: barWidth, height: barHeight)

            if bucket.count > 0 {
                color(forBucketAt: index, total: buckets.count).setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()
                drawCount(bucket.count, centeredAtX: barRect.midX, y: max(top, barRect.minY - 17))
            }

            drawRange(bucket.range, centeredAtX: x + barWidth / 2, y: labelY, maxWidth: barWidth + 8)
        }
    }

    private func drawEmpty(in rect: NSRect, text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 12),
            withAttributes: attrs
        )
    }

    private func drawCount(_ value: Int, centeredAtX x: CGFloat, y: CGFloat) {
        let text = "\(value)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: x - size.width / 2, y: y), withAttributes: attrs)
    }

    private func drawRange(_ range: String, centeredAtX x: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let rect = NSRect(x: x - maxWidth / 2, y: y, width: maxWidth, height: 14)
        range.draw(in: rect, withAttributes: attrs)
    }

    private func color(forBucketAt index: Int, total: Int) -> NSColor {
        let progress = CGFloat(index) / CGFloat(max(1, total - 1))
        if progress < 0.35 {
            return NSColor.systemGreen.withAlphaComponent(0.82)
        }
        if progress < 0.65 {
            return NSColor.systemYellow.withAlphaComponent(0.82)
        }
        if progress < 0.85 {
            return NSColor.systemOrange.withAlphaComponent(0.82)
        }
        return NSColor.systemRed.withAlphaComponent(0.82)
    }
}
