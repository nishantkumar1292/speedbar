import Cocoa

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

func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 1024 { return String(format: "%.0fB", bytesPerSec) }
    if bytesPerSec < 1024 * 1024 { return String(format: "%.1fK", bytesPerSec / 1024) }
    if bytesPerSec < 1024 * 1024 * 1024 { return String(format: "%.1fM", bytesPerSec / 1024 / 1024) }
    return String(format: "%.1fG", bytesPerSec / 1024 / 1024 / 1024)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor = NetworkMonitor()
    private var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "↓ -- ↑ --"
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Initial read to establish baseline
        _ = monitor.getSpeed()
        startTimer()
        
        // Handle sleep/wake cycles
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    @objc private func handleWake() {
        monitor.reset()
        startTimer()
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateSpeed()
        }
        timer?.tolerance = 0.2 // Helps with power efficiency
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
