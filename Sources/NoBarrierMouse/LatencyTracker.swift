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

final class LatencyTracker {
    static let shared = LatencyTracker()

    private let queue = DispatchQueue(label: "NoBarrierMouse.Latency", qos: .utility)
    private var rollingC2S = RollingLatency(capacity: 2000)
    private var rollingInputQueue = RollingLatency(capacity: 2000)
    private var rollingR2A = RollingLatency(capacity: 2000)
    private var cumulativeC2S = CumulativeHistogram()
    private var cumulativeInputQueue = CumulativeHistogram()
    private var cumulativeR2A = CumulativeHistogram()
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
            self.rollingC2S.reset()
            self.rollingInputQueue.reset()
            self.rollingR2A.reset()
        }
    }

    // Reset cumulative data (called when stats window closes)
    func resetCumulative() {
        queue.async {
            self.cumulativeC2S.reset()
            self.cumulativeInputQueue.reset()
            self.cumulativeR2A.reset()
        }
    }

    func recordCaptureToSend(_ microseconds: Double) {
        queue.async {
            self.rollingC2S.add(microseconds)
            self.cumulativeC2S.add(microseconds)
        }
    }

    func recordInputQueueDelay(_ microseconds: Double) {
        queue.async {
            self.rollingInputQueue.add(microseconds)
            self.cumulativeInputQueue.add(microseconds)
        }
    }

    func recordReceiveToApply(_ microseconds: Double) {
        queue.async {
            self.rollingR2A.add(microseconds)
            self.cumulativeR2A.add(microseconds)
        }
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
        let inputQueue: MetricSnapshot?
        let receiveToApply: MetricSnapshot?
    }

    func snapshot(completion: @escaping (FullSnapshot) -> Void) {
        queue.async {
            let snap = FullSnapshot(
                captureToSend: self.cumulativeC2S.snapshot(),
                inputQueue: self.cumulativeInputQueue.snapshot(),
                receiveToApply: self.cumulativeR2A.snapshot()
            )
            DispatchQueue.main.async { completion(snap) }
        }
    }

    private func logStats() {
        let c2s = rollingC2S.report()
        let iq = rollingInputQueue.report()
        let r2a = rollingR2A.report()

        guard c2s != nil || iq != nil || r2a != nil else { return }

        var lines: [String] = ["[Latency]"]
        if let c = c2s {
            lines.append("C→S: p50=\(fmt(c.p50)) p90=\(fmt(c.p90)) p99=\(fmt(c.p99)) max=\(fmt(c.max)) n=\(c.count)")
            rollingC2S.reset()
        }
        if let c = iq {
            lines.append("IQ: p50=\(fmt(c.p50)) p90=\(fmt(c.p90)) p99=\(fmt(c.p99)) max=\(fmt(c.max)) n=\(c.count)")
            rollingInputQueue.reset()
        }
        if let c = r2a {
            lines.append("R→A: p50=\(fmt(c.p50)) p90=\(fmt(c.p90)) p99=\(fmt(c.p99)) max=\(fmt(c.max)) n=\(c.count)")
            rollingR2A.reset()
        }

        os_log("%{public}@", log: latencyLog, type: .info, lines.joined(separator: " | "))
    }
}

// Rolling latency with precise percentiles from sorted samples. Resets every log interval.
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

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        histogram = [Int](repeating: 0, count: histogramBucketBounds.count - 1)
    }
}

// Cumulative histogram that grows forever. Uses bucket midpoints for approximate percentiles.
private struct CumulativeHistogram {
    private var buckets: [Int]
    private var totalCount: Int = 0
    private var currentMax: Double = 0

    init() {
        buckets = [Int](repeating: 0, count: histogramBucketBounds.count - 1)
    }

    mutating func add(_ value: Double) {
        totalCount += 1
        if value > currentMax { currentMax = value }
        for i in 0..<(histogramBucketBounds.count - 1) {
            if value >= histogramBucketBounds[i] && value < histogramBucketBounds[i + 1] {
                buckets[i] += 1
                return
            }
        }
    }

    func snapshot() -> LatencyTracker.MetricSnapshot? {
        guard totalCount > 0 else { return nil }
        var bucketList: [(range: String, count: Int)] = []
        for i in 0..<buckets.count {
            bucketList.append((histogramBucketRange(i), buckets[i]))
        }
        return LatencyTracker.MetricSnapshot(
            p50: percentile(0.50),
            p90: percentile(0.90),
            p99: percentile(0.99),
            max: currentMax,
            count: totalCount,
            buckets: bucketList
        )
    }

    private func percentile(_ p: Double) -> Double {
        let target = max(1, Int((Double(totalCount) * p).rounded(.up)))
        var accumulated = 0
        for i in 0..<buckets.count {
            accumulated += buckets[i]
            if accumulated >= target {
                let lo = histogramBucketBounds[i]
                let hi = histogramBucketBounds[i + 1]
                let mid = hi == Double.infinity ? lo : (lo + hi) / 2
                return mid
            }
        }
        return currentMax
    }

    mutating func reset() {
        buckets = [Int](repeating: 0, count: histogramBucketBounds.count - 1)
        totalCount = 0
        currentMax = 0
    }
}
