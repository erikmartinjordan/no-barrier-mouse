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
    case mouseArrivalGap
    case mouseApplyGap
    case tcpReceiveDecode
    case receiverQueue
    case mouseApplyTick
    case cgEventPost
    case cgWarp
    case receiveCallback

    static let visibleCases: [InputMetricID] = [
        .hidCapture,
        .tcpSerializeSend,
        .mouseArrivalGap,
        .receiverQueue,
        .mouseApplyGap,
        .cgEventPost,
        .cgWarp,
        .receiveCallback
    ]

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
            return "Transport RTT"
        case .mouseArrivalGap:
            return "Mouse packet gap"
        case .mouseApplyGap:
            return "Cursor update gap"
        case .tcpReceiveDecode:
            return "Receive + decode"
        case .receiverQueue:
            return "Receiver queue"
        case .mouseApplyTick:
            return "Mouse apply tick"
        case .cgEventPost:
            return "CGEvent post"
        case .cgWarp:
            return "CGWarp"
        case .receiveCallback:
            return "Receive callback"
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
            return "App ping/pong over active path"
        case .mouseArrivalGap:
            return "Gap between movement packets"
        case .mouseApplyGap:
            return "Gap between posted cursor updates"
        case .tcpReceiveDecode:
            return "Socket read buffer and wire decode"
        case .receiverQueue:
            return "Message arrival to input execution"
        case .mouseApplyTick:
            return "Buffered delta drain and cursor update"
        case .cgEventPost:
            return "CGEvent creation and HID post"
        case .cgWarp:
            return "CGWarpMouseCursorPosition"
        case .receiveCallback:
            return "Total time in receive callback on serial queue"
        }
    }

    var stage: InputMetricStage {
        switch self {
        case .hidCapture, .tcpQueue, .tcpSerializeSend:
            return .controller
        case .tcpSendCompletion, .lanRTT, .mouseArrivalGap:
            return .network
        case .mouseApplyGap, .tcpReceiveDecode, .receiverQueue, .mouseApplyTick, .cgEventPost, .cgWarp, .receiveCallback:
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
        case .mouseArrivalGap:
            return 8.5
        case .mouseApplyGap:
            return 8.5
        case .tcpReceiveDecode:
            return 0.35
        case .receiverQueue:
            return 2.0
        case .mouseApplyTick:
            return 2.0
        case .cgEventPost:
            return 0.75
        case .cgWarp:
            return 0.20
        case .receiveCallback:
            return 1.0
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
        case .mouseArrivalGap:
            return 16.7
        case .mouseApplyGap:
            return 16.7
        case .tcpReceiveDecode:
            return 1.5
        case .receiverQueue:
            return 8.0
        case .mouseApplyTick:
            return 6.0
        case .cgEventPost:
            return 3.0
        case .cgWarp:
            return 1.0
        case .receiveCallback:
            return 4.0
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
    let transport: String
    let issue: String?
}

struct EndToEndLatencySnapshot {
    let values: [Double]
    let count: Int
    let p50: Double
    let p90: Double
    let p99: Double
    let last: Double
    let updatedAt: Date?

    var hasSamples: Bool {
        count > 0
    }

    static let empty = EndToEndLatencySnapshot(values: [], count: 0, p50: 0, p90: 0, p99: 0, last: 0, updatedAt: nil)
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
    private var status = InputMonitorStatusSnapshot(state: "Off", role: "No role", connected: false, transport: "No transport", issue: nil)
    private var endToEndLatency = EndToEndLatencySnapshot.empty

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
        status = InputMonitorStatusSnapshot(state: state, role: role, connected: connected, transport: status.transport, issue: issue)
        lock.unlock()
    }

    func setTransport(_ transport: String) {
        lock.lock()
        status = InputMonitorStatusSnapshot(
            state: status.state,
            role: status.role,
            connected: status.connected,
            transport: transport,
            issue: status.issue
        )
        lock.unlock()
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        endToEndLatency = .empty
        lock.unlock()
    }

    func setEndToEndLatency(values: [Double]) {
        let bounded = values.filter { $0.isFinite && $0 >= 0 }.map { min($0, 60_000) }
        let sorted = bounded.sorted()
        let total = bounded.count

        lock.lock()
        if bounded.isEmpty {
            endToEndLatency = .empty
        } else {
            endToEndLatency = EndToEndLatencySnapshot(
                values: Array(bounded.suffix(maxSamples)),
                count: total,
                p50: percentile(sorted, 0.50),
                p90: percentile(sorted, 0.90),
                p99: percentile(sorted, 0.99),
                last: bounded.last ?? 0,
                updatedAt: Date()
            )
        }
        lock.unlock()
    }

    func statusSnapshot() -> InputMonitorStatusSnapshot {
        lock.lock()
        let snapshot = status
        lock.unlock()
        return snapshot
    }

    func endToEndLatencySnapshot() -> EndToEndLatencySnapshot {
        lock.lock()
        let snapshot = endToEndLatency
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

    func diagnosticReport() -> String {
        let status = statusSnapshot()
        let all = snapshots()
        let visible = InputMetricID.visibleCases.compactMap { id in
            all.first { $0.id == id }
        }
        let active = visible.filter(\.hasSamples)
        let worst = active.max { lhs, rhs in
            normalizedSeverity(lhs) < normalizedSeverity(rhs)
        }

        var lines: [String] = []
        lines.append("No Barrier Mouse diagnostic")
        lines.append("State: \(status.state)")
        lines.append("Role: \(status.role)")
        lines.append("Transport: \(status.transport)")
        if let issue = status.issue {
            lines.append("Issue: \(issue)")
        }
        lines.append("")
        lines.append("Visible metrics:")

        for snapshot in visible {
            if snapshot.hasSamples {
                lines.append("- \(snapshot.id.title): p50 \(formatDiagnostic(snapshot.p50)), p95 \(formatDiagnostic(snapshot.p95)), max \(formatDiagnostic(snapshot.max)), n \(snapshot.count)")
            } else {
                lines.append("- \(snapshot.id.title): no samples")
            }
        }

        lines.append("")
        if let worst {
            lines.append("Most likely bottleneck: \(worst.id.title) at p95 \(formatDiagnostic(worst.p95))")
            lines.append("Interpretation: \(diagnosticHint(for: worst.id))")
        } else {
            lines.append("Most likely bottleneck: no movement samples yet")
        }

        return lines.joined(separator: "\n")
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}

private func normalizedSeverity(_ snapshot: InputMetricSnapshot) -> Double {
    guard snapshot.hasSamples else { return 0 }
    return snapshot.p95 / max(snapshot.id.goodMilliseconds, 0.001)
}

private func formatDiagnostic(_ milliseconds: Double) -> String {
    if milliseconds <= 0 {
        return "-"
    }
    if milliseconds < 1 {
        return "\(Int((milliseconds * 1000).rounded()))us"
    }
    if milliseconds < 10 {
        return String(format: "%.1fms", milliseconds)
    }
    return String(format: "%.0fms", milliseconds)
}

private func diagnosticHint(for id: InputMetricID) -> String {
    switch id {
    case .hidCapture:
        return "The controller is slow to capture HID events."
    case .tcpQueue:
        return "Input is waiting behind other TCP sends."
    case .tcpSerializeSend:
        return "The controller is slow to encode or submit network packets."
    case .tcpSendCompletion:
        return "TCP completion callbacks are delayed; this is usually less important than packet cadence."
    case .lanRTT:
        return "Round-trip transport latency is high, but this is not the main mouse smoothness metric."
    case .mouseArrivalGap:
        return "Movement packets are arriving unevenly; this usually feels like network or sender cadence jitter."
    case .mouseApplyGap:
        return "Cursor updates are not being posted evenly on the receiver."
    case .tcpReceiveDecode:
        return "The receiver is slow to read or decode packets."
    case .receiverQueue:
        return "The receiver is waiting too long before executing input work."
    case .mouseApplyTick:
        return "The receiver cursor update itself is slow."
    case .cgEventPost:
        return "macOS event posting is slow on the receiver."
    case .cgWarp:
        return "The CGWarpMouseCursorPosition call is slow on the receiver."
    case .receiveCallback:
        return "The total receive callback execution is too long."
    }
}

private func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
    guard !sortedValues.isEmpty else { return 0 }
    let clamped = min(max(percentile, 0), 1)
    let index = Int((Double(sortedValues.count - 1) * clamped).rounded())
    return sortedValues[index]
}
