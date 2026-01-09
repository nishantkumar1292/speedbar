import Cocoa
import Network

// MARK: - Color Theme
struct Theme {
    static let background = NSColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1.0)
    static let cardBackground = NSColor(red: 0.15, green: 0.20, blue: 0.28, alpha: 1.0)
    static let accent = NSColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
    static let accentGlow = NSColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1.0)
    static let textPrimary = NSColor.white
    static let textSecondary = NSColor(red: 0.6, green: 0.65, blue: 0.7, alpha: 1.0)
    static let gridLine = NSColor(red: 0.25, green: 0.30, blue: 0.38, alpha: 1.0)
    static let chartLine = NSColor(red: 0.3, green: 0.6, blue: 0.95, alpha: 1.0)
    static let buttonGradientTop = NSColor(red: 0.3, green: 0.7, blue: 0.95, alpha: 1.0)
    static let buttonGradientBottom = NSColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
    static let progressBackground = NSColor(red: 0.1, green: 0.35, blue: 0.5, alpha: 1.0)
}

// MARK: - Network Monitor
class NetworkMonitor {
    private var lastBytes: (rx: UInt64, tx: UInt64) = (0, 0)
    private var lastTime = Date()

    func getSpeed() -> (download: Double, upload: Double) {
        let current = getTotalBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)

        guard elapsed > 0, elapsed < 10, lastBytes.rx > 0,
              current.rx >= lastBytes.rx, current.tx >= lastBytes.tx else {
            lastBytes = current
            lastTime = now
            return (0, 0)
        }

        let rxSpeed = Double(current.rx - lastBytes.rx) / elapsed
        let txSpeed = Double(current.tx - lastBytes.tx) / elapsed

        lastBytes = current
        lastTime = now

        return (rxSpeed, txSpeed)
    }

    func reset() {
        lastBytes = (0, 0)
        lastTime = Date()
    }

    private func getTotalBytes() -> (rx: UInt64, tx: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var rx: UInt64 = 0, tx: UInt64 = 0

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") else { continue }

            if let data = ptr.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(networkData.ifi_ibytes)
                tx += UInt64(networkData.ifi_obytes)
            }
        }
        return (rx, tx)
    }
}

// MARK: - Latency Monitor
struct LatencyPoint {
    let timestamp: Date
    let latency: Double
}

class LatencyMonitor {
    private(set) var history: [LatencyPoint] = []
    private let maxHistoryDuration: TimeInterval = 300
    private let queue = DispatchQueue(label: "latency.monitor")

    func measureLatency(completion: @escaping (Double) -> Void) {
        queue.async {
            let start = Date()
            let connection = NWConnection(host: "8.8.8.8", port: 53, using: .tcp)
            var completed = false

            let timeout = DispatchWorkItem {
                guard !completed else { return }
                completed = true
                connection.cancel()
                DispatchQueue.main.async { completion(-1) }
            }
            self.queue.asyncAfter(deadline: .now() + 2, execute: timeout)

            connection.stateUpdateHandler = { state in
                guard !completed else { return }
                if case .ready = state {
                    completed = true
                    timeout.cancel()
                    let latency = Date().timeIntervalSince(start) * 1000
                    connection.cancel()
                    DispatchQueue.main.async { completion(latency) }
                } else if case .failed = state {
                    completed = true
                    timeout.cancel()
                    connection.cancel()
                    DispatchQueue.main.async { completion(-1) }
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func record(_ latency: Double) {
        let point = LatencyPoint(timestamp: Date(), latency: latency)
        history.append(point)
        pruneOldData()
    }

    func pruneOldData() {
        let cutoff = Date().addingTimeInterval(-maxHistoryDuration)
        history.removeAll { $0.timestamp < cutoff }
    }

    func getRecentHistory() -> [LatencyPoint] {
        pruneOldData()
        return history
    }
}

// MARK: - Speed Test
class SpeedTest {
    enum State {
        case idle
        case testing(progress: Double, phase: String)
        case completed(download: Double, upload: Double)
        case failed
    }

    private let queue = DispatchQueue(label: "speed.test")
    var onStateChange: ((State) -> Void)?
    private var isCancelled = false

    func start() {
        isCancelled = false
        DispatchQueue.main.async {
            self.onStateChange?(.testing(progress: 0, phase: "Connecting..."))
        }

        queue.async {
            self.runTest()
        }
    }

    func cancel() {
        isCancelled = true
    }

    private func runTest() {
        // Download test - fetch a file and measure speed
        var downloadSpeed: Double = 0
        var uploadSpeed: Double = 0

        // Phase 1: Download test
        DispatchQueue.main.async {
            self.onStateChange?(.testing(progress: 0.1, phase: "Testing download..."))
        }

        downloadSpeed = measureDownloadSpeed()

        if isCancelled { return }

        // Phase 2: Upload test
        DispatchQueue.main.async {
            self.onStateChange?(.testing(progress: 0.6, phase: "Testing upload..."))
        }

        uploadSpeed = measureUploadSpeed()

        if isCancelled { return }

        DispatchQueue.main.async {
            self.onStateChange?(.testing(progress: 1.0, phase: "Complete"))
        }

        Thread.sleep(forTimeInterval: 0.3)

        DispatchQueue.main.async {
            if downloadSpeed > 0 || uploadSpeed > 0 {
                self.onStateChange?(.completed(download: downloadSpeed, upload: uploadSpeed))
            } else {
                self.onStateChange?(.failed)
            }
        }
    }

    private func measureDownloadSpeed() -> Double {
        let testURLs = [
            "https://speed.cloudflare.com/__down?bytes=10000000",
            "https://proof.ovh.net/files/1Mb.dat"
        ]

        for urlString in testURLs {
            guard let url = URL(string: urlString) else { continue }

            let semaphore = DispatchSemaphore(value: 0)
            var speed: Double = 0

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config)

            let startTime = Date()
            var totalBytes: Int = 0

            let task = session.dataTask(with: url) { data, response, error in
                if let data = data, error == nil {
                    totalBytes = data.count
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        speed = Double(totalBytes) / elapsed // bytes per second
                    }
                }
                semaphore.signal()
            }
            task.resume()

            // Update progress during download
            for i in 1...4 {
                if isCancelled { task.cancel(); return 0 }
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async {
                    self.onStateChange?(.testing(progress: 0.1 + Double(i) * 0.1, phase: "Testing download..."))
                }
            }

            _ = semaphore.wait(timeout: .now() + 10)

            if speed > 0 { return speed }
        }

        return 0
    }

    private func measureUploadSpeed() -> Double {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return 0 }

        let semaphore = DispatchSemaphore(value: 0)
        var speed: Double = 0

        // Create 1MB of random data
        let dataSize = 1_000_000
        var randomData = Data(count: dataSize)
        randomData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            arc4random_buf(baseAddress, dataSize)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        let startTime = Date()

        let task = session.uploadTask(with: request, from: randomData) { _, response, error in
            if error == nil {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0 {
                    speed = Double(dataSize) / elapsed
                }
            }
            semaphore.signal()
        }
        task.resume()

        // Update progress during upload
        for i in 1...3 {
            if isCancelled { task.cancel(); return 0 }
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async {
                self.onStateChange?(.testing(progress: 0.6 + Double(i) * 0.1, phase: "Testing upload..."))
            }
        }

        _ = semaphore.wait(timeout: .now() + 10)

        return speed
    }
}

// MARK: - Chart View
class LatencyChartView: NSView {
    var latencyHistory: [LatencyPoint] = []
    private let chartPadding: CGFloat = 10
    private let rightPadding: CGFloat = 45
    private let bottomPadding: CGFloat = 22
    private let topPadding: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        Theme.cardBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let chartRect = NSRect(
            x: chartPadding,
            y: bottomPadding,
            width: bounds.width - chartPadding - rightPadding,
            height: bounds.height - bottomPadding - topPadding
        )

        drawYAxis(in: chartRect)
        drawXAxis(in: chartRect)
        drawLatencyLine(in: chartRect)
    }

    private func drawYAxis(in rect: NSRect) {
        let labels = ["600 ms", "450 ms", "300 ms", "150 ms", "0 ms"]
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ]

        for (i, label) in labels.enumerated() {
            let y = rect.minY + rect.height * CGFloat(labels.count - 1 - i) / CGFloat(labels.count - 1) - 5
            (label as NSString).draw(at: NSPoint(x: rect.maxX + 5, y: y), withAttributes: attrs)
        }

        Theme.gridLine.setStroke()
        for i in 0..<labels.count {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(labels.count - 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            path.lineWidth = 0.5

            if i == 2 { // 300ms threshold - dashed line
                let dashes: [CGFloat] = [4, 4]
                path.setLineDash(dashes, count: 2, phase: 0)
                NSColor(red: 0.4, green: 0.45, blue: 0.55, alpha: 1.0).setStroke()
                path.stroke()
                Theme.gridLine.setStroke()
            } else {
                path.stroke()
            }
        }
    }

    private func drawXAxis(in rect: NSRect) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ]

        for i in 0..<5 {
            let timeOffset = TimeInterval(-300 + i * 75)
            let time = now.addingTimeInterval(timeOffset)
            let label = formatter.string(from: time)
            let x = rect.minX + rect.width * CGFloat(i) / 4
            (label as NSString).draw(at: NSPoint(x: x - 20, y: 5), withAttributes: attrs)
        }
    }

    private func drawLatencyLine(in rect: NSRect) {
        guard latencyHistory.count > 1 else { return }

        let now = Date()
        let windowStart = now.addingTimeInterval(-300)
        let validPoints = latencyHistory.filter { $0.latency >= 0 && $0.timestamp >= windowStart }
        guard validPoints.count > 1 else { return }

        // Draw glow effect
        let glowPath = NSBezierPath()
        var started = false

        for point in validPoints {
            let timeFraction = point.timestamp.timeIntervalSince(windowStart) / 300
            let x = rect.minX + rect.width * CGFloat(timeFraction)
            let normalizedLatency = min(point.latency, 600) / 600
            let y = rect.minY + rect.height * CGFloat(normalizedLatency)

            if !started {
                glowPath.move(to: NSPoint(x: x, y: y))
                started = true
            } else {
                glowPath.line(to: NSPoint(x: x, y: y))
            }
        }

        // Draw glow
        Theme.accentGlow.withAlphaComponent(0.3).setStroke()
        glowPath.lineWidth = 4
        glowPath.lineJoinStyle = .round
        glowPath.stroke()

        // Draw main line
        Theme.chartLine.setStroke()
        glowPath.lineWidth = 2
        glowPath.stroke()
    }
}

// MARK: - Header View
class SectionHeaderView: NSView {
    private let title: String
    private let iconName: String

    init(frame: NSRect, title: String, icon: String) {
        self.title = title
        self.iconName = icon
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw icon circle
        let iconSize: CGFloat = 20
        let iconRect = NSRect(x: 10, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        Theme.accent.setFill()
        NSBezierPath(ovalIn: iconRect).fill()

        // Draw icon symbol
        let iconAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .bold)
        ]
        let iconText = iconName
        let iconTextSize = (iconText as NSString).size(withAttributes: iconAttrs)
        (iconText as NSString).draw(
            at: NSPoint(x: iconRect.midX - iconTextSize.width / 2, y: iconRect.midY - iconTextSize.height / 2),
            withAttributes: iconAttrs
        )

        // Draw title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textPrimary,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]
        (title as NSString).draw(at: NSPoint(x: 38, y: (bounds.height - 14) / 2), withAttributes: titleAttrs)
    }
}

// MARK: - Current Speeds View
class CurrentSpeedsView: NSView {
    var downloadSpeed: Double? = nil  // nil means no test run yet
    var uploadSpeed: Double? = nil

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        Theme.cardBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let midX = bounds.width / 2

        // Download section
        drawSpeedSection(
            at: NSPoint(x: midX / 2, y: bounds.height / 2),
            label: "DOWNLOAD",
            speed: downloadSpeed,
            icon: "↓",
            iconColor: Theme.accent
        )

        // Separator line
        Theme.gridLine.setStroke()
        let sepPath = NSBezierPath()
        sepPath.move(to: NSPoint(x: midX, y: 15))
        sepPath.line(to: NSPoint(x: midX, y: bounds.height - 15))
        sepPath.lineWidth = 1
        sepPath.stroke()

        // Upload section
        drawSpeedSection(
            at: NSPoint(x: midX + midX / 2, y: bounds.height / 2),
            label: "UPLOAD",
            speed: uploadSpeed,
            icon: "↑",
            iconColor: Theme.accent
        )
    }

    private func drawSpeedSection(at center: NSPoint, label: String, speed: Double?, icon: String, iconColor: NSColor) {
        // Label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.systemFont(ofSize: 10, weight: .medium)
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        (label as NSString).draw(
            at: NSPoint(x: center.x - labelSize.width / 2, y: center.y + 15),
            withAttributes: labelAttrs
        )

        // Icon
        let iconAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: iconColor,
            .font: NSFont.systemFont(ofSize: 16, weight: .bold)
        ]

        let speedAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textPrimary,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        ]
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.systemFont(ofSize: 12, weight: .regular)
        ]

        if let speed = speed {
            // Show actual speed
            let iconSize = (icon as NSString).size(withAttributes: iconAttrs)
            let (speedValue, speedUnit) = formatSpeedWithUnit(speed)

            let speedSize = (speedValue as NSString).size(withAttributes: speedAttrs)
            let unitSize = (speedUnit as NSString).size(withAttributes: unitAttrs)
            let totalWidth = iconSize.width + 5 + speedSize.width + 3 + unitSize.width

            var x = center.x - totalWidth / 2
            let y = center.y - 20

            (icon as NSString).draw(at: NSPoint(x: x, y: y - 2), withAttributes: iconAttrs)
            x += iconSize.width + 5
            (speedValue as NSString).draw(at: NSPoint(x: x, y: y - 5), withAttributes: speedAttrs)
            x += speedSize.width + 3
            (speedUnit as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: unitAttrs)
        } else {
            // Show placeholder
            let placeholder = "-- --"
            let placeholderAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.textSecondary,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            ]
            let placeholderSize = (placeholder as NSString).size(withAttributes: placeholderAttrs)
            (placeholder as NSString).draw(
                at: NSPoint(x: center.x - placeholderSize.width / 2, y: center.y - 25),
                withAttributes: placeholderAttrs
            )
        }
    }

    private func formatSpeedWithUnit(_ bytesPerSec: Double) -> (String, String) {
        let bitsPerSec = bytesPerSec * 8
        if bitsPerSec < 1000 { return (String(format: "%.0f", bitsPerSec), "bps") }
        if bitsPerSec < 1_000_000 { return (String(format: "%.1f", bitsPerSec / 1000), "Kbps") }
        if bitsPerSec < 1_000_000_000 { return (String(format: "%.1f", bitsPerSec / 1_000_000), "Mbps") }
        return (String(format: "%.1f", bitsPerSec / 1_000_000_000), "Gbps")
    }
}

// MARK: - Speed Test Button View
class SpeedTestButtonView: NSView {
    var onClick: (() -> Void)?
    var progress: Double = 0
    var isRunning: Bool = false
    var statusText: String = "RUN SPEED TEST"
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if !isRunning {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let buttonRect = bounds.insetBy(dx: 0, dy: 0)

        // Draw button background with gradient
        let gradient: NSGradient
        if isHovered && !isRunning {
            gradient = NSGradient(
                starting: Theme.accentGlow,
                ending: Theme.buttonGradientTop
            )!
        } else {
            gradient = NSGradient(
                starting: Theme.buttonGradientTop,
                ending: Theme.buttonGradientBottom
            )!
        }

        let buttonPath = NSBezierPath(roundedRect: buttonRect, xRadius: 6, yRadius: 6)
        gradient.draw(in: buttonPath, angle: 90)

        // Draw progress bar if running
        if isRunning && progress > 0 {
            let progressRect = NSRect(
                x: buttonRect.minX,
                y: buttonRect.minY,
                width: buttonRect.width * CGFloat(progress),
                height: buttonRect.height
            )

            let progressGradient = NSGradient(
                starting: Theme.accentGlow,
                ending: Theme.accent
            )!

            NSGraphicsContext.saveGraphicsState()
            buttonPath.addClip()
            progressGradient.draw(in: progressRect, angle: 0)
            NSGraphicsContext.restoreGraphicsState()

            // Draw animated stripes
            drawAnimatedStripes(in: buttonRect, progress: progress)
        }

        // Draw button text
        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let textSize = (statusText as NSString).size(withAttributes: textAttrs)
        (statusText as NSString).draw(
            at: NSPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2),
            withAttributes: textAttrs
        )
    }

    private func drawAnimatedStripes(in rect: NSRect, progress: Double) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()

        let stripeWidth: CGFloat = 15
        let progressWidth = rect.width * CGFloat(progress)
        let stripeColor = NSColor.white.withAlphaComponent(0.15)
        stripeColor.setFill()

        let offset = CGFloat(Int(Date().timeIntervalSinceReferenceDate * 30) % Int(stripeWidth * 2))

        var x: CGFloat = -stripeWidth * 2 + offset
        while x < progressWidth {
            let stripePath = NSBezierPath()
            stripePath.move(to: NSPoint(x: x, y: rect.minY))
            stripePath.line(to: NSPoint(x: x + stripeWidth, y: rect.minY))
            stripePath.line(to: NSPoint(x: x + stripeWidth + rect.height, y: rect.maxY))
            stripePath.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            stripePath.close()
            stripePath.fill()
            x += stripeWidth * 2
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    func update(progress: Double, status: String, running: Bool) {
        self.progress = progress
        self.statusText = status
        self.isRunning = running
        needsDisplay = true
    }
}

// MARK: - Quit Button
class QuitButton: NSView {
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isHovered {
            NSColor(red: 0.3, green: 0.35, blue: 0.45, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let text = "Quit"
        let textSize = (text as NSString).size(withAttributes: textAttrs)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2),
            withAttributes: textAttrs
        )
    }
}

// MARK: - Main Popover View
class MainPopoverView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.background.setFill()
        bounds.fill()
    }
}

// MARK: - Helpers
func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 1024 { return String(format: "%.0fB", bytesPerSec) }
    if bytesPerSec < 1024 * 1024 { return String(format: "%.1fK", bytesPerSec / 1024) }
    if bytesPerSec < 1024 * 1024 * 1024 { return String(format: "%.1fM", bytesPerSec / 1024 / 1024) }
    return String(format: "%.1fG", bytesPerSec / 1024 / 1024 / 1024)
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor = NetworkMonitor()
    private var latencyMonitor = LatencyMonitor()
    private var speedTest = SpeedTest()
    private var timer: Timer?
    private var latencyTimer: Timer?
    private var animationTimer: Timer?
    private var popover: NSPopover!
    private var chartView: LatencyChartView!
    private var speedsView: CurrentSpeedsView!
    private var speedTestButton: SpeedTestButtonView!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "↓ -- ↑ --"
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        setupPopover()
        setupSpeedTest()

        _ = monitor.getSpeed()
        startTimer()
        startLatencyTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func setupPopover() {
        let popoverWidth: CGFloat = 340
        let popoverHeight: CGFloat = 380

        let mainView = MainPopoverView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))

        // Connection Delay Header
        let delayHeader = SectionHeaderView(
            frame: NSRect(x: 10, y: popoverHeight - 35, width: popoverWidth - 20, height: 30),
            title: "CONNECTION DELAY",
            icon: "◉"
        )
        mainView.addSubview(delayHeader)

        // Chart View
        chartView = LatencyChartView(frame: NSRect(x: 10, y: popoverHeight - 175, width: popoverWidth - 20, height: 135))
        mainView.addSubview(chartView)

        // Current Speeds Header
        let speedsHeader = SectionHeaderView(
            frame: NSRect(x: 10, y: popoverHeight - 205, width: popoverWidth - 20, height: 30),
            title: "CURRENT SPEEDS",
            icon: "⚡"
        )
        mainView.addSubview(speedsHeader)

        // Current Speeds View
        speedsView = CurrentSpeedsView(frame: NSRect(x: 10, y: popoverHeight - 295, width: popoverWidth - 20, height: 85))
        mainView.addSubview(speedsView)

        // Speed Test Button
        speedTestButton = SpeedTestButtonView(frame: NSRect(x: 10, y: popoverHeight - 340, width: popoverWidth - 20, height: 38))
        speedTestButton.onClick = { [weak self] in
            self?.runSpeedTest()
        }
        mainView.addSubview(speedTestButton)

        // Quit Button
        let quitButton = QuitButton(frame: NSRect(x: (popoverWidth - 60) / 2, y: 10, width: 60, height: 25))
        quitButton.onClick = { [weak self] in
            self?.quit()
        }
        mainView.addSubview(quitButton)

        let viewController = NSViewController()
        viewController.view = mainView

        popover = NSPopover()
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.behavior = .applicationDefined
        popover.contentViewController = viewController
    }

    private func setupSpeedTest() {
        speedTest.onStateChange = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .idle:
                self.speedTestButton.update(progress: 0, status: "RUN SPEED TEST", running: false)
                self.stopAnimationTimer()

            case .testing(let progress, let phase):
                self.speedTestButton.update(progress: progress, status: phase, running: true)
                self.startAnimationTimer()

            case .completed(let download, let upload):
                let dlSpeed = self.formatSpeedMbps(download)
                let ulSpeed = self.formatSpeedMbps(upload)
                self.speedTestButton.update(progress: 0, status: "↓\(dlSpeed) ↑\(ulSpeed)", running: false)
                self.stopAnimationTimer()

                // Update the speeds view with test results
                self.speedsView.downloadSpeed = download
                self.speedsView.uploadSpeed = upload
                self.speedsView.needsDisplay = true

                // Reset button text after showing results (but keep speeds view)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.speedTestButton.statusText.hasPrefix("↓") == true {
                        self?.speedTestButton.update(progress: 0, status: "RUN SPEED TEST", running: false)
                    }
                }

            case .failed:
                self.speedTestButton.update(progress: 0, status: "Test Failed - Retry", running: false)
                self.stopAnimationTimer()
            }
        }
    }

    private func formatSpeedMbps(_ bytesPerSec: Double) -> String {
        let mbps = bytesPerSec * 8 / 1_000_000
        if mbps < 1 {
            return String(format: "%.0f Kbps", bytesPerSec * 8 / 1000)
        }
        return String(format: "%.1f Mbps", mbps)
    }

    private func runSpeedTest() {
        speedTest.start()
    }

    private func startAnimationTimer() {
        stopAnimationTimer()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.speedTestButton.needsDisplay = true
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            quit()
            return
        }

        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            chartView.latencyHistory = latencyMonitor.getRecentHistory()
            chartView.needsDisplay = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startEventMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true {
                self?.closePopover()
            }
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    @objc private func handleWake() {
        monitor.reset()
        startTimer()
        startLatencyTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateSpeed()
        }
        timer?.tolerance = 0.2
    }

    private func startLatencyTimer() {
        latencyTimer?.invalidate()
        latencyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.measureLatency()
        }
        measureLatency()
    }

    private func measureLatency() {
        latencyMonitor.measureLatency { [weak self] latency in
            self?.latencyMonitor.record(latency)
            if self?.popover.isShown == true {
                self?.chartView.latencyHistory = self?.latencyMonitor.getRecentHistory() ?? []
                self?.chartView.needsDisplay = true
            }
        }
    }

    private func updateSpeed() {
        let (down, up) = monitor.getSpeed()
        let text = "↓\(formatSpeed(down)) ↑\(formatSpeed(up))"
        DispatchQueue.main.async {
            self.statusItem.button?.title = text
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
