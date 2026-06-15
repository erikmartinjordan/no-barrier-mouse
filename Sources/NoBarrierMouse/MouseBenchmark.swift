import CoreGraphics
import Darwin
import Foundation

final class MouseBenchmarkRecorder {
    private struct Sample {
        let sequence: UInt32
        let sentMilliseconds: Double
        let dx: Double
        let dy: Double
        let receivedMilliseconds: Double
        let appliedMilliseconds: Double
        let x: Double
        let y: Double
    }

    private let id: UInt32
    private let sampleRate: UInt16
    private let expectedSamples: UInt16
    private let transport: String
    private let startedAtTicks: UInt64
    private let startedAtDate = Date()
    private var samples: [Sample] = []

    init(id: UInt32, sampleRate: UInt16, expectedSamples: UInt16, transport: String, startedAtTicks: UInt64 = InputMetrics.nowTicks()) {
        self.id = id
        self.sampleRate = sampleRate
        self.expectedSamples = expectedSamples
        self.transport = transport
        self.startedAtTicks = startedAtTicks
    }

    func record(sequence: UInt32, sentMilliseconds: Double, dx: Double, dy: Double, receivedAt: UInt64, appliedAt: UInt64, point: CGPoint) {
        samples.append(Sample(
            sequence: sequence,
            sentMilliseconds: sentMilliseconds,
            dx: dx,
            dy: dy,
            receivedMilliseconds: InputMetrics.milliseconds(from: startedAtTicks, to: receivedAt),
            appliedMilliseconds: InputMetrics.milliseconds(from: startedAtTicks, to: appliedAt),
            x: point.x,
            y: point.y
        ))
    }

    @discardableResult
    func finish(reason: String) -> URL? {
        let receivedGaps = gaps(samples.map(\.receivedMilliseconds))
        let appliedGaps = gaps(samples.map(\.appliedMilliseconds))
        let sentGaps = gaps(samples.map(\.sentMilliseconds))
        let endToEndValues = samples.map { max(0, $0.appliedMilliseconds - $0.receivedMilliseconds) }
        let missing = max(0, Int(expectedSamples) - samples.count)
        InputMetrics.shared.setEndToEndLatency(values: endToEndValues)

        let payload: [String: Any] = [
            "id": id,
            "reason": reason,
            "transport": transport,
            "startedAt": ISO8601DateFormatter().string(from: startedAtDate),
            "sampleRateHz": Int(sampleRate),
            "expectedSamples": Int(expectedSamples),
            "receivedSamples": samples.count,
            "missingSamples": missing,
            "summary": [
                "receivedGapP50Ms": percentile(receivedGaps, 0.50),
                "receivedGapP95Ms": percentile(receivedGaps, 0.95),
                "receivedGapMaxMs": receivedGaps.max() ?? 0,
                "senderGapP50Ms": percentile(sentGaps, 0.50),
                "senderGapP95Ms": percentile(sentGaps, 0.95),
                "senderGapMaxMs": sentGaps.max() ?? 0,
                "appliedGapP50Ms": percentile(appliedGaps, 0.50),
                "appliedGapP95Ms": percentile(appliedGaps, 0.95),
                "appliedGapMaxMs": appliedGaps.max() ?? 0,
                "endToEndP50Ms": percentile(endToEndValues, 0.50),
                "endToEndP90Ms": percentile(endToEndValues, 0.90),
                "endToEndP99Ms": percentile(endToEndValues, 0.99)
            ],
            "samples": samples.map { sample in
                [
                    "sequence": Int(sample.sequence),
                    "sentMs": sample.sentMilliseconds,
                    "dx": sample.dx,
                    "dy": sample.dy,
                    "receivedMs": sample.receivedMilliseconds,
                    "appliedMs": sample.appliedMilliseconds,
                    "x": sample.x,
                    "y": sample.y
                ]
            }
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
            let url = desktop.appendingPathComponent("no-barrier-mouse-\(slug(transport))-benchmark-\(id).json")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func gaps(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return [] }
        return zip(values.dropFirst(), values).map { max(0, $0 - $1) }
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * min(max(percentile, 0), 1)).rounded())
        return sorted[index]
    }

    private func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars).split(separator: "-").joined(separator: "-")
    }
}
