import AppKit

final class StatsWindowController: NSWindowController {
    private let refreshInterval: TimeInterval = 2.0
    private var refreshTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    override func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        super.close()
    }

    private func refreshNow() {
        LatencyTracker.shared.snapshot { [weak self] snap in
            (self?.window?.contentView as? StatsView)?.snapshot = snap
            self?.window?.contentView?.needsDisplay = true
        }
    }
}

private final class StatsView: NSView {
    var snapshot: LatencyTracker.FullSnapshot?

    private let leftMargin: CGFloat = 110
    private let barHeight: CGFloat = 16
    private let barGap: CGFloat = 3
    private let sectionGap: CGFloat = 14
    private let percentileHeight: CGFloat = 16

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot else { return }

        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        var y = bounds.height - 20

        y = drawSection(label: "Capture → Send (C→S)", metric: snapshot.captureToSend, y: y)
        y = drawSection(label: "Receive → Apply (R→A)", metric: snapshot.receiveToApply, y: y)
    }

    private func drawSection(label: String, metric: LatencyTracker.MetricSnapshot?, y: CGFloat) -> CGFloat {
        var cy = y
        let left = leftMargin

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        label.draw(at: NSPoint(x: 10, y: cy - 14), withAttributes: labelAttrs)
        cy -= 18

        guard let metric else {
            let empty = "no samples"
            empty.draw(at: NSPoint(x: left, y: cy - 12), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            return cy - 14 - sectionGap
        }

        let maxCount = metric.buckets.map(\.count).max() ?? 1
        let barAreaWidth = bounds.width - left - 16

        for (idx, bucket) in metric.buckets.enumerated() {
            cy -= barHeight + barGap
            let pct = Double(bucket.count) / Double(max(metric.count, 1)) * 100

            let rangeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let rangeStr = "\(bucket.range)"
            rangeStr.draw(at: NSPoint(x: left - rangeStr.size(withAttributes: rangeAttrs).width - 6, y: cy + 1), withAttributes: rangeAttrs)

            let barWidth = maxCount > 0 ? CGFloat(bucket.count) / CGFloat(maxCount) * barAreaWidth : 0
            if barWidth > 0 {
                let bar = NSRect(x: left, y: cy, width: max(barWidth, 2), height: barHeight)
                let hue = CGFloat(idx) / CGFloat(metric.buckets.count)
                NSColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 0.8).setFill()
                bar.fill()
                NSColor(hue: hue, saturation: 0.7, brightness: 0.6, alpha: 1).setStroke()
                bar.frame(withWidth: 0.5, using: .sourceOver)
            }

            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
            let countStr = "\(bucket.count) (\(String(format: "%.0f", pct))%)"
            countStr.draw(at: NSPoint(x: left + barWidth + 4, y: cy + 1), withAttributes: countAttrs)
        }

        cy -= 4

        let pctileStr = String(
            format: "p50: %@  p90: %@  p99: %@  max: %@  n: %d",
            fmt(metric.p50), fmt(metric.p90), fmt(metric.p99), fmt(metric.max), metric.count
        )
        let pctileAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        pctileStr.draw(at: NSPoint(x: left, y: cy - 12), withAttributes: pctileAttrs)
        cy -= 14

        return cy - sectionGap
    }
}
