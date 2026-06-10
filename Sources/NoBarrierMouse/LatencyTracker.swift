import Foundation
import OSLog

private let latencyLog = OSLog(subsystem: "com.nobarriermouse", category: "latency")

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

    struct MetricSnapshot {
        let p50: Double
        let p90: Double
        let p99: Double
        let max: Double
        let count: Int
        let buckets: [(range: String, count: Int)]
    }

    struct FullSnapshot {
        let captureToSend: MetricSnapshot?
        let receiveToApply: MetricSnapshot?
        let networkOneWay: MetricSnapshot?
    }

    func snapshot(completion: @escaping (FullSnapshot) -> Void) {
        queue.async {
            let snap = FullSnapshot(
                captureToSend: self.captureToSend.snapshot(),
                receiveToApply: self.receiveToApply.snapshot(),
                networkOneWay: self.networkOneWay.snapshot()
            )
            DispatchQueue.main.async { completion(snap) }
        }
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

        os_log("%{public}@", log: latencyLog, type: .info, lines.joined(separator: " | "))
    }
}

let histogramBucketBounds: [Double] = [0, 100, 250, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000, Double.infinity]

func histogramBucketRange(_ index: Int) -> String {
    let lo = histogramBucketBounds[index]
    let hi = histogramBucketBounds[index + 1]
    let loStr = lo == 0 ? "0" : lo >= 1000 ? "\(Int(lo / 1000))ms" : "\(Int(lo))µs"
    let hiStr = hi == Double.infinity ? "+" : hi >= 1000 ? "\(Int(hi / 1000))ms" : "\(Int(hi))µs"
    return "\(loStr)-\(hiStr)"
}

func fmt(_ us: Double) -> String {
    if us < 1000 {
        return String(format: "%.0fµs", us)
    }
    return String(format: "%.1fms", us / 1000.0)
}

private struct RollingLatency {
    private var samples: [Double]
    private var histogram: [Int]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.samples = []
        self.samples.reserveCapacity(capacity)
        self.histogram = [Int](repeating: 0, count: histogramBucketBounds.count - 1)
    }

    mutating func add(_ value: Double) {
        if samples.count < capacity {
            samples.append(value)
        }
        for i in 0..<(histogramBucketBounds.count - 1) {
            if value >= histogramBucketBounds[i] && value < histogramBucketBounds[i + 1] {
                histogram[i] += 1
                return
            }
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

    func snapshot() -> LatencyTracker.MetricSnapshot? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        var buckets: [(range: String, count: Int)] = []
        for i in 0..<histogram.count {
            buckets.append((histogramBucketRange(i), histogram[i]))
        }
        return LatencyTracker.MetricSnapshot(
            p50: sorted[n / 2],
            p90: sorted[Int((Double(n) * 0.9).rounded(.up)) - 1],
            p99: sorted[Int((Double(n) * 0.99).rounded(.up)) - 1],
            max: sorted.last!,
            count: n,
            buckets: buckets
        )
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        histogram = [Int](repeating: 0, count: histogramBucketBounds.count - 1)
    }
}
