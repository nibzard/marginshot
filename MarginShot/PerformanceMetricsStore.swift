import Combine
import Foundation
import os

enum PerformanceUnit: String, Codable {
    case milliseconds
    case scansPerMinute
}

enum PerformanceTargetKind: String, Codable {
    case maximum
    case minimum
}

struct PerformanceTarget: Codable {
    let value: Double
    let kind: PerformanceTargetKind
    let unit: PerformanceUnit
}

enum PerformanceTargets {
    static let captureShutterLatencyMs: Double = 300
    static let processingThroughputScansPerMinute: Double = 60
    static let chatRetrievalLatencyMs: Double = 300
}

enum PerformanceMetric: String, CaseIterable, Codable, Identifiable {
    case captureShutterLatency
    case capturePreprocessDuration
    case processingThroughput
    case processingScanDuration
    case processingBatchDuration
    case chatRetrievalLatency

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .captureShutterLatency:
            return "Capture shutter latency"
        case .capturePreprocessDuration:
            return "Capture preprocessing"
        case .processingThroughput:
            return "Processing throughput"
        case .processingScanDuration:
            return "Processing scan duration"
        case .processingBatchDuration:
            return "Processing batch duration"
        case .chatRetrievalLatency:
            return "Chat retrieval latency"
        }
    }

    var unit: PerformanceUnit {
        switch self {
        case .processingThroughput:
            return .scansPerMinute
        default:
            return .milliseconds
        }
    }

    var target: PerformanceTarget? {
        switch self {
        case .captureShutterLatency:
            return PerformanceTarget(
                value: PerformanceTargets.captureShutterLatencyMs,
                kind: .maximum,
                unit: .milliseconds
            )
        case .processingThroughput:
            return PerformanceTarget(
                value: PerformanceTargets.processingThroughputScansPerMinute,
                kind: .minimum,
                unit: .scansPerMinute
            )
        case .chatRetrievalLatency:
            return PerformanceTarget(
                value: PerformanceTargets.chatRetrievalLatencyMs,
                kind: .maximum,
                unit: .milliseconds
            )
        default:
            return nil
        }
    }

    static var primaryMetrics: [PerformanceMetric] {
        [.captureShutterLatency, .processingThroughput, .chatRetrievalLatency]
    }
}

struct PerformanceSample: Codable, Identifiable {
    let id: UUID
    let metric: PerformanceMetric
    let value: Double
    let recordedAt: Date
}

enum PerformanceStatus {
    case withinTarget
    case outsideTarget
}

@MainActor
final class PerformanceMetricsStore: ObservableObject {
    static let shared = PerformanceMetricsStore()

    @Published private(set) var latestSamples: [PerformanceMetric: PerformanceSample] = [:]
    @Published private(set) var historyByMetric: [PerformanceMetric: [PerformanceSample]] = [:]

    private let defaultsKey = "performanceMetricsSamples"
    private let maxSamplesPerMetric = 12
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MarginShot", category: "performance")
        load()
    }

    func recordDuration(_ metric: PerformanceMetric, seconds: Double) {
        record(metric, value: seconds * 1000.0)
    }

    func record(_ metric: PerformanceMetric, value: Double) {
        let sample = PerformanceSample(id: UUID(), metric: metric, value: value, recordedAt: Date())
        var samples = historyByMetric[metric] ?? []
        samples.append(sample)
        if samples.count > maxSamplesPerMetric {
            samples.removeFirst(samples.count - maxSamplesPerMetric)
        }
        historyByMetric[metric] = samples
        latestSamples[metric] = sample
        persist()
        logSample(sample)
    }

    func latestSample(for metric: PerformanceMetric) -> PerformanceSample? {
        latestSamples[metric]
    }

    func formattedValue(for metric: PerformanceMetric) -> String {
        guard let sample = latestSamples[metric] else {
            return "Not recorded"
        }
        return format(metric: metric, value: sample.value)
    }

    func formattedTarget(for metric: PerformanceMetric) -> String? {
        guard let target = metric.target else {
            return nil
        }
        let formatted = format(metric: metric, value: target.value)
        switch target.kind {
        case .maximum:
            return "Target <= \(formatted)"
        case .minimum:
            return "Target >= \(formatted)"
        }
    }

    func status(for metric: PerformanceMetric) -> PerformanceStatus? {
        guard let sample = latestSamples[metric] else {
            return nil
        }
        return status(for: metric, value: sample.value)
    }

    func reset() {
        historyByMetric = [:]
        latestSamples = [:]
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let samples = try? decoder.decode([PerformanceSample].self, from: data) else {
            return
        }

        var grouped: [PerformanceMetric: [PerformanceSample]] = [:]
        for sample in samples {
            grouped[sample.metric, default: []].append(sample)
        }

        var latest: [PerformanceMetric: PerformanceSample] = [:]
        for (metric, entries) in grouped {
            let sorted = entries.sorted { $0.recordedAt < $1.recordedAt }
            let trimmed = Array(sorted.suffix(maxSamplesPerMetric))
            grouped[metric] = trimmed
            if let last = trimmed.last {
                latest[metric] = last
            }
        }

        historyByMetric = grouped
        latestSamples = latest
    }

    private func persist() {
        let allSamples = historyByMetric.values.flatMap { $0 }
        guard let data = try? encoder.encode(allSamples) else {
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func format(metric: PerformanceMetric, value: Double) -> String {
        switch metric.unit {
        case .milliseconds:
            if value >= 1000 {
                return String(format: "%.2f s", value / 1000.0)
            }
            return String(format: "%.0f ms", value)
        case .scansPerMinute:
            return String(format: "%.1f scans/min", value)
        }
    }

    private func status(for metric: PerformanceMetric, value: Double) -> PerformanceStatus? {
        guard let target = metric.target else {
            return nil
        }
        switch target.kind {
        case .maximum:
            return value <= target.value ? .withinTarget : .outsideTarget
        case .minimum:
            return value >= target.value ? .withinTarget : .outsideTarget
        }
    }

    private func logSample(_ sample: PerformanceSample) {
        let formatted = format(metric: sample.metric, value: sample.value)
        if let status = status(for: sample.metric, value: sample.value), status == .outsideTarget {
            logger.warning("Performance \(sample.metric.rawValue, privacy: .public) off target: \(formatted, privacy: .public)")
        } else {
            logger.info("Performance \(sample.metric.rawValue, privacy: .public): \(formatted, privacy: .public)")
        }
    }
}
