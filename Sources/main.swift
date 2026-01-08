import Cocoa
import Network

class NetworkMonitor {
    private var lastBytes: (rx: UInt64, tx: UInt64) = (0, 0)
    private var lastTime = Date()
    
    func getSpeed() -> (download: Double, upload: Double) {
        let current = getTotalBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        
        // Reset baseline if: first run, too much time elapsed (sleep), or counter reset
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
            // Skip loopback and non-active interfaces
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

struct LatencyPoint {
    let timestamp: Date
    let latency: Double // in milliseconds, -1 means timeout/error
}

class LatencyMonitor {
    private(set) var history: [LatencyPoint] = []
    private let maxHistoryDuration: TimeInterval = 300 // 5 minutes
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

class LatencyChartView: NSView {
    var latencyHistory: [LatencyPoint] = []
    private let chartPadding: CGFloat = 40
    private let rightPadding: CGFloat = 50
    private let bottomPadding: CGFloat = 25
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let bgColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        
        let chartRect = NSRect(
            x: chartPadding, y: bottomPadding,
            width: bounds.width - chartPadding - rightPadding,
            height: bounds.height - bottomPadding - 45
        )
        
        drawTitle()
        drawYAxis(in: chartRect)
        drawXAxis(in: chartRect)
        drawThresholdLine(in: chartRect)
        drawLatencyLine(in: chartRect)
    }
    
    private func drawTitle() {
        let title = "CONNECTION DELAY"
        let subtitle = "High values or large variations may reduce call quality"
        
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.gray,
            .font: NSFont.systemFont(ofSize: 10)
        ]
        
        (title as NSString).draw(at: NSPoint(x: 12, y: bounds.height - 22), withAttributes: titleAttrs)
        (subtitle as NSString).draw(at: NSPoint(x: 12, y: bounds.height - 38), withAttributes: subtitleAttrs)
    }
    
    private func drawYAxis(in rect: NSRect) {
        let labels = ["600 ms", "450 ms", "300 ms", "150 ms", "0 ms"]
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.gray,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ]
        
        for (i, label) in labels.enumerated() {
            let y = rect.minY + rect.height * CGFloat(labels.count - 1 - i) / CGFloat(labels.count - 1) - 5
            (label as NSString).draw(at: NSPoint(x: rect.maxX + 5, y: y), withAttributes: attrs)
        }
        
        // Draw horizontal grid lines
        NSColor(calibratedWhite: 0.3, alpha: 1.0).setStroke()
        for i in 0..<labels.count {
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(labels.count - 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            path.lineWidth = 0.5
            if i == labels.count - 3 { // 300ms threshold
                let dashes: [CGFloat] = [4, 4]
                path.setLineDash(dashes, count: 2, phase: 0)
                NSColor(calibratedWhite: 0.5, alpha: 1.0).setStroke()
            }
            path.stroke()
            NSColor(calibratedWhite: 0.3, alpha: 1.0).setStroke()
        }
    }
    
    private func drawXAxis(in rect: NSRect) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.gray,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ]
        
        // Draw 5 time labels spanning 5 minutes
        for i in 0..<5 {
            let timeOffset = TimeInterval(-300 + i * 75) // -5min to now in 75sec steps
            let time = now.addingTimeInterval(timeOffset)
            let label = formatter.string(from: time)
            let x = rect.minX + rect.width * CGFloat(i) / 4
            (label as NSString).draw(at: NSPoint(x: x - 20, y: 5), withAttributes: attrs)
        }
    }
    
    private func drawThresholdLine(in rect: NSRect) {
        let thresholdY = rect.minY + rect.height * (300.0 / 600.0)
        NSColor(calibratedWhite: 0.5, alpha: 1.0).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: thresholdY))
        path.line(to: NSPoint(x: rect.maxX, y: thresholdY))
        let dashes: [CGFloat] = [4, 4]
        path.setLineDash(dashes, count: 2, phase: 0)
        path.lineWidth = 1
        path.stroke()
    }
    
    private func drawLatencyLine(in rect: NSRect) {
        guard latencyHistory.count > 1 else { return }
        
        let now = Date()
        let windowStart = now.addingTimeInterval(-300)
        let validPoints = latencyHistory.filter { $0.latency >= 0 && $0.timestamp >= windowStart }
        guard validPoints.count > 1 else { return }
        
        let path = NSBezierPath()
        var started = false
        
        for point in validPoints {
            let timeFraction = point.timestamp.timeIntervalSince(windowStart) / 300
            let x = rect.minX + rect.width * CGFloat(timeFraction)
            let normalizedLatency = min(point.latency, 600) / 600
            let y = rect.minY + rect.height * CGFloat(normalizedLatency)
            
            if !started {
                path.move(to: NSPoint(x: x, y: y))
                started = true
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        
        NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1.0).setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.stroke()
    }
}

func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 1024 { return String(format: "%.0fB", bytesPerSec) }
    if bytesPerSec < 1024 * 1024 { return String(format: "%.1fK", bytesPerSec / 1024) }
    if bytesPerSec < 1024 * 1024 * 1024 { return String(format: "%.1fM", bytesPerSec / 1024 / 1024) }
    return String(format: "%.1fG", bytesPerSec / 1024 / 1024 / 1024)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor = NetworkMonitor()
    private var latencyMonitor = LatencyMonitor()
    private var timer: Timer?
    private var latencyTimer: Timer?
    private var popover: NSPopover!
    private var chartView: LatencyChartView!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "↓ -- ↑ --"
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        
        setupPopover()
        
        // Initial read to establish baseline
        _ = monitor.getSpeed()
        startTimer()
        startLatencyTimer()
        
        // Handle sleep/wake cycles
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    private func setupPopover() {
        chartView = LatencyChartView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        
        let viewController = NSViewController()
        viewController.view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 240))
        viewController.view.addSubview(chartView)
        chartView.frame = NSRect(x: 0, y: 40, width: 380, height: 200)
        
        let quitButton = NSButton(frame: NSRect(x: 155, y: 8, width: 70, height: 24))
        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quit)
        viewController.view.addSubview(quitButton)
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 240)
        popover.behavior = .transient
        popover.contentViewController = viewController
    }
    
    @objc private func togglePopover(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            quit()
            return
        }
        
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            chartView.latencyHistory = latencyMonitor.getRecentHistory()
            chartView.needsDisplay = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
        measureLatency() // Initial measurement
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Hide from dock
app.run()
