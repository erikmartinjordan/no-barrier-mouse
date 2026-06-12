import Darwin
import Foundation

enum InputMetricStage: String, CaseIterable {
    case controller = "Controller"
    case network = "Network"
    case receiver = "Receiver"
}

enum InputMetricID: CaseIterable, Hashable {
    case hidCapture
    case tcpQueue
    case tcpSerializeSend
    case tcpSendCompletion
    case lanRTT
    case tcpReceiveDecode
    case receiverQueue
    case mouseApplyTick
    case cgEventPost

    var title: String {
        switch self {
        case .hidCapture:
            return "HID capture"
        case .tcpQueue:
            return "TCP priority queue"
        case .tcpSerializeSend:
            return "Serialize + send"
        case .tcpSendCompletion:
            return "TCP completion"
        case .lanRTT:
            return "WiFi LAN RTT"
        case .tcpReceiveDecode:
            return "Receive + decode"
        case .receiverQueue:
            return "Receiver queue"
        case .mouseApplyTick:
            return "Mouse apply tick"
        case .cgEventPost:
            return "CGEvent post"
        }
    }

    var detail: String {
        switch self {
        case .hidCapture:
            return "Event tap callback to network enqueue"
        case .tcpQueue:
            return "Time waiting behind priority traffic"
        case .tcpSerializeSend:
            return "Wire encoding and NWConnection send call"
        case .tcpSendCompletion:
            return "NWConnection contentProcessed callback"
        case .lanRTT:
            return "App ping/pong round trip"
        case .tcpReceiveDecode:
            return "Socket read buffer and wire decode"
        case .receiverQueue:
            return "Message arrival to input execution"
        case .mouseApplyTick:
            return "Buffered delta drain and cursor update"
        case .cgEventPost:
            return "CGEvent creation and HID post"
        }
    }

    var stage: InputMetricStage {
        switch self {
        case .hidCapture, .tcpQueue, .tcpSerializeSend:
            return .controller
        case .tcpSendCompletion, .lanRTT:
            return .network
        case .tcpReceiveDecode, .receiverQueue, .mouseApplyTick, .cgEventPost:
            return .receiver
        }
    }

    var goodMilliseconds: Double {
        switch self {
        case .hidCapture:
            return 0.20
        case .tcpQueue:
            return 1.0
        case .tcpSerializeSend:
            return 0.35
        case .tcpSendCompletion:
            return 2.0
        case .lanRTT:
            return 10.0
        case .tcpReceiveDecode:
            return 0.35
        case .receiverQueue:
            return 2.0
        case .mouseApplyTick:
            return 2.0
        case .cgEventPost:
            return 0.75
        }
    }

    var fairMilliseconds: Double {
        switch self {
        case .hidCapture:
            return 0.8
        case .tcpQueue:
            return 5.0
        case .tcpSerializeSend:
            return 1.5
        case .tcpSendCompletion:
            return 8.0
        case .lanRTT:
            return 30.0
        case .tcpReceiveDecode:
            return 1.5
        case .receiverQueue:
            return 8.0
        case .mouseApplyTick:
            return 6.0
        case .cgEventPost:
            return 3.0
        }
    }
}

struct InputMetricSnapshot {
    let id: InputMetricID
    let values: [Double]
    let count: Int
    let p50: Double
    let p95: Double
    let p99: Double
    let average: Double
    let max: Double
    let last: Double
    let lastSampleAge: TimeInterval?

    var hasSamples: Bool {
        count > 0
    }
}

struct InputMonitorStatusSnapshot {
    let state: String
    let role: String
    let connected: Bool
    let issue: String?
}

final class InputMetrics {
    static let shared = InputMetrics()

    private struct Sample {
        let value: Double
        let timestamp: TimeInterval
    }

    private let lock = NSLock()
    private let maxSamples = 720
    private var samples: [InputMetricID: [Sample]] = [:]
    private var status = InputMonitorStatusSnapshot(state: "Off", role: "No role", connected: false, issue: nil)

    private init() {}

    static func nowTicks() -> UInt64 {
        mach_absolute_time()
    }

    static func milliseconds(from start: UInt64, to end: UInt64 = mach_absolute_time()) -> Double {
        guard end >= start else { return 0 }
        let elapsed = end - start
        let nanos = Double(elapsed) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000.0
    }

    func record(_ id: InputMetricID, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let bounded = min(milliseconds, 60_000)
        let sample = Sample(value: bounded, timestamp: CFAbsoluteTimeGetCurrent())

        lock.lock()
        var bucket = samples[id, default: []]
        bucket.append(sample)
        if bucket.count > maxSamples {
            bucket.removeFirst(bucket.count - maxSamples)
        }
        samples[id] = bucket
        lock.unlock()
    }

    func record(_ id: InputMetricID, from start: UInt64, to end: UInt64 = mach_absolute_time()) {
        record(id, milliseconds: Self.milliseconds(from: start, to: end))
    }

    func setStatus(state: String, role: String, connected: Bool, issue: String?) {
        lock.lock()
        status = InputMonitorStatusSnapshot(state: state, role: role, connected: connected, issue: issue)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    func statusSnapshot() -> InputMonitorStatusSnapshot {
        lock.lock()
        let snapshot = status
        lock.unlock()
        return snapshot
    }

    func snapshots() -> [InputMetricSnapshot] {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let copied = samples
        lock.unlock()

        return InputMetricID.allCases.map { id in
            let bucket = copied[id] ?? []
            let values = bucket.map(\.value)
            guard !values.isEmpty else {
                return InputMetricSnapshot(
                    id: id,
                    values: [],
                    count: 0,
                    p50: 0,
                    p95: 0,
                    p99: 0,
                    average: 0,
                    max: 0,
                    last: 0,
                    lastSampleAge: nil
                )
            }

            let sorted = values.sorted()
            let total = values.reduce(0, +)
            let lastAge = bucket.last.map { now - $0.timestamp }

            return InputMetricSnapshot(
                id: id,
                values: values,
                count: values.count,
                p50: percentile(sorted, 0.50),
                p95: percentile(sorted, 0.95),
                p99: percentile(sorted, 0.99),
                average: total / Double(values.count),
                max: sorted.last ?? 0,
                last: values.last ?? 0,
                lastSampleAge: lastAge
            )
        }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}

private func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
    guard !sortedValues.isEmpty else { return 0 }
    let clamped = min(max(percentile, 0), 1)
    let index = Int((Double(sortedValues.count - 1) * clamped).rounded())
    return sortedValues[index]
}
