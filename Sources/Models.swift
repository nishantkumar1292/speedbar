import AppKit
import Foundation
import Network

// MARK: - Visual language

enum Theme {
    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        }
    }

    static let background = adaptive(
        light: NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1),
        dark: NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1)
    )
    static let panel = adaptive(
        light: NSColor.white,
        dark: NSColor(srgbRed: 0.10, green: 0.14, blue: 0.19, alpha: 1)
    )
    static let panelBorder = adaptive(
        light: NSColor(srgbRed: 0.80, green: 0.84, blue: 0.88, alpha: 1),
        dark: NSColor(srgbRed: 0.19, green: 0.25, blue: 0.32, alpha: 1)
    )
    static let accent = NSColor(srgbRed: 0.18, green: 0.57, blue: 0.94, alpha: 1)
    static let accentSoft = NSColor(srgbRed: 0.18, green: 0.57, blue: 0.94, alpha: 0.14)
    static let success = NSColor(srgbRed: 0.20, green: 0.72, blue: 0.47, alpha: 1)
    static let warning = NSColor(srgbRed: 0.94, green: 0.62, blue: 0.22, alpha: 1)
    static let critical = NSColor(srgbRed: 0.94, green: 0.31, blue: 0.35, alpha: 1)
    static let textPrimary = NSColor.labelColor
    static let textSecondary = NSColor.secondaryLabelColor
    static let grid = adaptive(
        light: NSColor(srgbRed: 0.77, green: 0.82, blue: 0.87, alpha: 0.7),
        dark: NSColor(srgbRed: 0.24, green: 0.31, blue: 0.39, alpha: 0.7)
    )
}

// MARK: - Connection and traffic models

enum ConnectionAvailability: Equatable, Sendable {
    case checking
    case online
    case connecting
    case offline
    case paused
}

struct ConnectionState: Equatable, Sendable {
    var availability: ConnectionAvailability
    var interfaceName: String?
    var interfaceLabel: String
    var isExpensive: Bool
    var isConstrained: Bool

    static let checking = ConnectionState(
        availability: .checking,
        interfaceName: nil,
        interfaceLabel: "Checking connection",
        isExpensive: false,
        isConstrained: false
    )

    var isOnline: Bool { availability == .online }

    var title: String {
        switch availability {
        case .checking: return "Checking connection"
        case .online: return "Online"
        case .connecting: return "Connecting"
        case .offline: return "No internet"
        case .paused: return "Monitoring paused"
        }
    }

    var subtitle: String {
        guard availability == .online else {
            switch availability {
            case .checking: return "Looking for an active network"
            case .connecting: return "The network needs attention"
            case .offline: return "Waiting for a network connection"
            case .paused: return "Readings are not updating"
            case .online: return ""
            }
        }

        var details = [interfaceLabel]
        if isConstrained {
            details.append("Low Data Mode")
        } else if isExpensive {
            details.append("Metered")
        }
        return details.joined(separator: " · ")
    }
}

struct ThroughputSample: Equatable, Sendable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double

    static let zero = ThroughputSample(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
}

// MARK: - Latency models

enum LatencyMeasurement: Equatable, Sendable {
    case success(milliseconds: Double)
    case timedOut
    case offline

    var latency: Double? {
        guard case .success(let milliseconds) = self else { return nil }
        return milliseconds
    }
}

struct LatencyPoint: Equatable, Sendable {
    let timestamp: Date
    let measurement: LatencyMeasurement

    var latency: Double? { measurement.latency }
}

struct LatencySummary: Equatable, Sendable {
    let current: Double?
    let average: Double?
    let jitter: Double?
    let lossPercentage: Double?
    let latestMeasurement: LatencyMeasurement?
    let latestTimestamp: Date?

    static let empty = LatencySummary(
        current: nil,
        average: nil,
        jitter: nil,
        lossPercentage: nil,
        latestMeasurement: nil,
        latestTimestamp: nil
    )
}

// MARK: - Speed-test models

struct SpeedTestResult: Equatable, Sendable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let completedAt: Date
}

enum SpeedTestPhase: String, Sendable {
    case preparing = "Connecting to test server…"
    case download = "Measuring download…"
    case upload = "Measuring upload…"
}

// MARK: - Formatting

enum RateFormatter {
    static func bytesPerSecond(_ value: Double, compact: Bool = false) -> String {
        let safeValue = max(0, value.isFinite ? value : 0)
        let units = compact
            ? ["B/s", "K/s", "M/s", "G/s"]
            : ["B/s", "KB/s", "MB/s", "GB/s"]
        let divisors: [Double] = [1, 1_000, 1_000_000, 1_000_000_000]
        let index: Int

        if safeValue < divisors[1] {
            index = 0
        } else if safeValue < divisors[2] {
            index = 1
        } else if safeValue < divisors[3] {
            index = 2
        } else {
            index = 3
        }

        let scaled = safeValue / divisors[index]
        let number: String
        if index == 0 {
            number = String(format: "%.0f", scaled)
        } else if scaled >= 100 {
            number = String(format: "%.0f", scaled)
        } else if scaled >= 10 {
            number = String(format: "%.1f", scaled)
        } else {
            number = String(format: "%.2f", scaled)
        }
        return "\(number) \(units[index])"
    }

    static func bitsPerSecond(_ bytesPerSecond: Double) -> String {
        let bits = max(0, bytesPerSecond.isFinite ? bytesPerSecond * 8 : 0)
        if bits < 1_000 {
            return String(format: "%.0f bps", bits)
        }
        if bits < 1_000_000 {
            return String(format: bits >= 100_000 ? "%.0f Kbps" : "%.1f Kbps", bits / 1_000)
        }
        if bits < 1_000_000_000 {
            return String(format: bits >= 100_000_000 ? "%.0f Mbps" : "%.1f Mbps", bits / 1_000_000)
        }
        return String(format: "%.2f Gbps", bits / 1_000_000_000)
    }
}

enum RelativeTimeFormatter {
    static func string(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(Int(seconds)) sec ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) hr ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}
