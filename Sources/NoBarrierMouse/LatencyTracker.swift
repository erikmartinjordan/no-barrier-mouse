import Foundation

private let latencyTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func absoluteTimeDiff(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(latencyTimebase.numer) / Double(latencyTimebase.denom) / 1000.0
}

final class LatencyTracker {
    static let shared = LatencyTracker()

    private let queue = DispatchQueue(label: "NoBarrierMouse.Latency", qos: .utility)
    private var captureToSend = RollingLatency(capacity: 2000)
    private var receiveToApply = RollingLatency(capacity: 2000)
    private var networkOneWay = RollingLatency(capacity: 2000)
    private var logTimer: DispatchSourceTimer?
    private var started = false

    var logInterval: TimeInterval = 5.0

    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !started else { return }
        started = true

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + logInterval, repeating: logInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.logStats()
        }
        timer.resume()
        logTimer = timer
    }

    func stop() {
        queue.async {
            self.logTimer?.cancel()
            self.logTimer = nil
            self.started = false
            self.captureToSend.reset()
            self.receiveToApply.reset()
            self.networkOneWay.reset()
        }
    }

    func recordCaptureToSend(_ microseconds: Double) {
        queue.async { self.captureToSend.add(microseconds) }
    }

    func recordReceiveToApply(_ microseconds: Double) {
        queue.async { self.receiveToApply.add(microseconds) }
    }

    func recordNetworkOneWay(_ microseconds: Double) {
        queue.async { self.networkOneWay.add(microseconds) }
    }

    private func logStats() {
        let c2s = captureToSend.report()
        let r2a = receiveToApply.report()
        let net = networkOneWay.report()

        guard c2s != nil || r2a != nil || net != nil else { return }

        var lines: [String] = ["[Latency]"]
        if let c = c2s {
            lines.append("C→S: p50=\(fmt(c.p50)) p90=\(fmt(c.p90)) p99=\(fmt(c.p99)) max=\(fmt(c.max)) n=\(c.count)")
            captureToSend.reset()
        }
        if let c = r2a {
            lines.append("R→A: p50=\(fmt(c.p50)) p90=\(fmt(c.p90)) p99=\(fmt(c.p99)) max=\(fmt(c.max)) n=\(c.count)")
            receiveToApply.reset()
        }
        if let c = net {
            lines.append("Net: p50=\(fmt(c.p50)) p90=\(fmt(c.p90)) p99=\(fmt(c.p99)) max=\(fmt(c.max)) n=\(c.count)")
            networkOneWay.reset()
        }

        print(lines.joined(separator: " | "))
    }
}

private func fmt(_ us: Double) -> String {
    if us < 1000 {
        return String(format: "%.0fµs", us)
    }
    return String(format: "%.1fms", us / 1000.0)
}

private struct RollingLatency {
    private var samples: [Double]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.samples = []
        self.samples.reserveCapacity(capacity)
    }

    mutating func add(_ value: Double) {
        if samples.count < capacity {
            samples.append(value)
        }
    }

    func report() -> (p50: Double, p90: Double, p99: Double, max: Double, count: Int)? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        return (
            p50: sorted[n / 2],
            p90: sorted[Int((Double(n) * 0.9).rounded(.up)) - 1],
            p99: sorted[Int((Double(n) * 0.99).rounded(.up)) - 1],
            max: sorted.last!,
            count: n
        )
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
