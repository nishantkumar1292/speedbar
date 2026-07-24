import AppKit
import ServiceManagement

private enum DefaultsKey {
    static let hasShownWelcome = "hasShownWelcome"
    static let lastDownloadSpeed = "lastDownloadSpeed"
    static let lastUploadSpeed = "lastUploadSpeed"
    static let lastSpeedTestDate = "lastSpeedTestDate"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let connectionMonitor = ConnectionMonitor()
    private let networkMonitor = NetworkMonitor()
    private let latencyMonitor = LatencyMonitor()
    private let speedTest = SpeedTest()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var contentView: PopoverContentView!
    private var trafficTimer: Timer?
    private var latencyTimer: Timer?

    private var pathState: ConnectionState = .checking
    private var displayedConnectionState: ConnectionState = .checking
    private var latestTraffic: ThroughputSample = .zero
    private var lastSpeedTestResult: SpeedTestResult?
    private var isSpeedTestRunning = false
    private var isMonitoringPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        loadLastSpeedTest()
        setUpCallbacks()
        setUpWorkspaceNotifications()
        updateLaunchAtLoginControl()

        contentView.updateSpeedTest(result: lastSpeedTestResult, state: .idle)
        connectionMonitor.start()
        startMonitoringTimers()

        if !UserDefaults.standard.bool(forKey: DefaultsKey.hasShownWelcome) {
            UserDefaults.standard.set(true, forKey: DefaultsKey.hasShownWelcome)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoringTimers()
        latencyMonitor.cancel()
        connectionMonitor.cancel()
        speedTest.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = "Measuring…"
        button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "SpeedBar is checking your connection"
        button.setAccessibilityLabel("SpeedBar")
        button.setAccessibilityValue("Measuring connection")
    }

    private func setUpPopover() {
        let size = NSSize(width: 360, height: 472)
        contentView = PopoverContentView(
            frame: NSRect(origin: .zero, size: size)
        )

        contentView.testButton.target = self
        contentView.testButton.action = #selector(speedTestButtonClicked)
        contentView.launchAtLoginButton.target = self
        contentView.launchAtLoginButton.action = #selector(toggleLaunchAtLogin)
        contentView.settingsButton.target = self
        contentView.settingsButton.action = #selector(showOptions)
        contentView.quitButton.target = self
        contentView.quitButton.action = #selector(quit)

        let viewController = NSViewController()
        viewController.view = contentView

        popover = NSPopover()
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = viewController
    }

    private func setUpCallbacks() {
        connectionMonitor.onChange = { [weak self] state in
            self?.handlePathChange(state)
        }

        speedTest.onStateChange = { [weak self] state in
            self?.handleSpeedTestState(state)
        }
    }

    private func setUpWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func handlePathChange(_ state: ConnectionState) {
        let didChangeInterface = state.interfaceName != pathState.interfaceName
        let didChangeAvailability = state.availability != pathState.availability
        pathState = state

        if didChangeInterface || didChangeAvailability {
            networkMonitor.reset()
        }

        if !state.isOnline, isSpeedTestRunning {
            speedTest.cancel()
        }
        if !state.isOnline {
            latencyMonitor.cancel()
        }

        guard !isMonitoringPaused else { return }
        displayedConnectionState = state
        contentView.updateConnection(state, summary: contentView.chartView.summary)
        updateSpeed()

        if state.isOnline, didChangeAvailability {
            measureLatency()
        } else if state.availability == .offline, didChangeAvailability {
            recordLatency(.offline)
        }
    }

    private func handleSpeedTestState(_ state: SpeedTest.State) {
        switch state {
        case .idle:
            isSpeedTestRunning = false
        case .testing:
            isSpeedTestRunning = true
        case .completed(let result):
            isSpeedTestRunning = false
            lastSpeedTestResult = result
            save(result)
        case .failed, .cancelled:
            isSpeedTestRunning = false
        }

        contentView.updateSpeedTest(result: lastSpeedTestResult, state: state)
        updateContextualAccessibility()
    }

    private func startMonitoringTimers() {
        guard !isMonitoringPaused else { return }
        stopMonitoringTimers()

        let newTrafficTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSpeed()
            }
        }
        newTrafficTimer.tolerance = 0.15
        RunLoop.main.add(newTrafficTimer, forMode: .common)
        trafficTimer = newTrafficTimer

        let newLatencyTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.measureLatency()
            }
        }
        newLatencyTimer.tolerance = 0.08
        RunLoop.main.add(newLatencyTimer, forMode: .common)
        latencyTimer = newLatencyTimer

        updateSpeed()
        measureLatency()
    }

    private func stopMonitoringTimers() {
        trafficTimer?.invalidate()
        trafficTimer = nil
        latencyTimer?.invalidate()
        latencyTimer = nil
    }

    private func updateSpeed() {
        contentView.refreshRelativeTimes()
        guard !isMonitoringPaused else {
            latestTraffic = .zero
            contentView.updateTraffic(.zero)
            updateStatusItem()
            return
        }

        if pathState.isOnline {
            latestTraffic = networkMonitor.getSpeed(interfaceName: pathState.interfaceName)
        } else {
            networkMonitor.reset()
            latestTraffic = .zero
        }
        contentView.updateTraffic(latestTraffic)
        updateStatusItem()
    }

    private func measureLatency() {
        guard !isMonitoringPaused else { return }
        switch pathState.availability {
        case .online:
            latencyMonitor.measureLatency(isOnline: true) { [weak self] measurement in
                self?.recordLatency(measurement)
            }
        case .offline:
            recordLatency(.offline)
        case .checking, .connecting, .paused:
            break
        }
    }

    private func recordLatency(_ measurement: LatencyMeasurement) {
        latencyMonitor.record(measurement)
        let history = latencyMonitor.getRecentHistory()
        contentView.updateLatency(history)
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let title: String
        let tooltip: String
        let accessibilityValue: String
        if isMonitoringPaused {
            title = "Paused"
            tooltip = "SpeedBar monitoring is paused"
            accessibilityValue = "Monitoring paused"
        } else {
            switch pathState.availability {
            case .online:
                title = "↓\(menuBarRate(latestTraffic.downloadBytesPerSecond)) ↑\(menuBarRate(latestTraffic.uploadBytesPerSecond))"
                let latencyText = contentView.chartView.summary.current.map {
                    "\(Int($0.rounded())) millisecond latency"
                } ?? "latency unavailable"
                tooltip = "Download \(RateFormatter.bytesPerSecond(latestTraffic.downloadBytesPerSecond)) · Upload \(RateFormatter.bytesPerSecond(latestTraffic.uploadBytesPerSecond)) · \(latencyText)"
                accessibilityValue = tooltip
            case .offline:
                title = "Offline"
                tooltip = "SpeedBar: no internet connection"
                accessibilityValue = "No internet connection"
            case .connecting:
                title = "Connecting…"
                tooltip = "SpeedBar is waiting for the network"
                accessibilityValue = "Connecting"
            case .checking:
                title = "Measuring…"
                tooltip = "SpeedBar is checking your connection"
                accessibilityValue = "Measuring connection"
            case .paused:
                title = "Paused"
                tooltip = "SpeedBar monitoring is paused"
                accessibilityValue = "Monitoring paused"
            }
        }

        button.title = title
        button.toolTip = tooltip
        button.setAccessibilityValue(accessibilityValue)
    }

    private func menuBarRate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0)
        if value < 1_000 {
            return "\(Int(value.rounded()))B/s"
        }
        if value < 1_000_000 {
            let scaled = value / 1_000
            return scaled >= 100
                ? String(format: "%.0fK/s", scaled)
                : String(format: "%.1fK/s", scaled)
        }
        if value < 1_000_000_000 {
            let scaled = value / 1_000_000
            return scaled >= 100
                ? String(format: "%.0fM/s", scaled)
                : String(format: "%.1fM/s", scaled)
        }
        return String(format: "%.1fG/s", value / 1_000_000_000)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(using: NSApp.currentEvent)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        contentView.updateLatency(latencyMonitor.getRecentHistory())
        contentView.updateConnection(
            displayedConnectionState,
            summary: contentView.chartView.summary
        )
        contentView.refreshRelativeTimes()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showContextMenu(using event: NSEvent?) {
        guard let event, let button = statusItem.button else { return }
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: button)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "SpeedBar")
        menu.autoenablesItems = false

        menu.addItem(menuItem("Open SpeedBar", action: #selector(openFromMenu)))
        menu.addItem(
            menuItem(
                isSpeedTestRunning ? "Cancel Speed Test" : "Run Speed Test",
                action: #selector(speedTestButtonClicked)
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                isMonitoringPaused ? "Resume Monitoring" : "Pause Monitoring",
                action: #selector(toggleMonitoring)
            )
        )

        let loginItem = menuItem("Launch at Login", action: #selector(toggleLaunchAtLogin))
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isEnabled = false
        }
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("About SpeedBar", action: #selector(showAbout)))
        menu.addItem(menuItem("Quit SpeedBar", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func openFromMenu() {
        showPopover()
    }

    @objc private func speedTestButtonClicked() {
        if isSpeedTestRunning {
            speedTest.cancel()
            return
        }
        guard pathState.isOnline else {
            contentView.updateSpeedTest(
                result: lastSpeedTestResult,
                state: .failed(message: "Connect to the internet, then try again.")
            )
            return
        }
        speedTest.start()
    }

    @objc private func toggleMonitoring() {
        isMonitoringPaused.toggle()

        if isMonitoringPaused {
            stopMonitoringTimers()
            latencyMonitor.cancel()
            networkMonitor.reset()
            displayedConnectionState = ConnectionState(
                availability: .paused,
                interfaceName: nil,
                interfaceLabel: "Monitoring paused",
                isExpensive: false,
                isConstrained: false
            )
            contentView.updateConnection(displayedConnectionState, summary: .empty)
            latestTraffic = .zero
            contentView.updateTraffic(.zero)
        } else {
            displayedConnectionState = pathState
            contentView.updateConnection(pathState, summary: contentView.chartView.summary)
            startMonitoringTimers()
        }
        updateStatusItem()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(
                title: "Launch at Login couldn’t be changed",
                message: error.localizedDescription
            )
        }
        updateLaunchAtLoginControl()
    }

    private func updateLaunchAtLoginControl() {
        if #available(macOS 13.0, *) {
            contentView.launchAtLoginButton.isEnabled = true
            contentView.launchAtLoginButton.state = SMAppService.mainApp.status == .enabled
                ? .on
                : .off
            contentView.launchAtLoginButton.toolTip = "Start SpeedBar automatically after you sign in"
        } else {
            contentView.launchAtLoginButton.state = .off
            contentView.launchAtLoginButton.isEnabled = false
            contentView.launchAtLoginButton.toolTip = "Available on macOS 13 or later"
        }
    }

    @objc private func showOptions() {
        let menu = NSMenu(title: "SpeedBar options")
        menu.autoenablesItems = false
        menu.addItem(
            menuItem(
                isMonitoringPaused ? "Resume Monitoring" : "Pause Monitoring",
                action: #selector(toggleMonitoring)
            )
        )
        menu.addItem(menuItem("About SpeedBar", action: #selector(showAbout)))
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: contentView.settingsButton.bounds.minX, y: contentView.settingsButton.bounds.maxY),
            in: contentView.settingsButton
        )
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        let credits = NSAttributedString(
            string: "A focused view of live traffic, latency, and connection capacity.\n\nLatency uses a TCP probe to 1.1.1.1. Speed tests use Cloudflare and transfer about 26 MB.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "SpeedBar",
            .applicationVersion: version,
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateContextualAccessibility() {
        contentView.testButton.setAccessibilityLabel(
            isSpeedTestRunning ? "Cancel speed test" : contentView.testButton.title
        )
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func save(_ result: SpeedTestResult) {
        let defaults = UserDefaults.standard
        defaults.set(result.downloadBytesPerSecond, forKey: DefaultsKey.lastDownloadSpeed)
        defaults.set(result.uploadBytesPerSecond, forKey: DefaultsKey.lastUploadSpeed)
        defaults.set(result.completedAt, forKey: DefaultsKey.lastSpeedTestDate)
    }

    private func loadLastSpeedTest() {
        let defaults = UserDefaults.standard
        let download = defaults.double(forKey: DefaultsKey.lastDownloadSpeed)
        let upload = defaults.double(forKey: DefaultsKey.lastUploadSpeed)
        guard download > 0,
              upload > 0,
              let date = defaults.object(forKey: DefaultsKey.lastSpeedTestDate) as? Date else {
            return
        }
        lastSpeedTestResult = SpeedTestResult(
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload,
            completedAt: date
        )
    }

    @objc private func handleSleep() {
        stopMonitoringTimers()
        latencyMonitor.cancel()
        networkMonitor.reset()
        if isSpeedTestRunning {
            speedTest.cancel()
        }
    }

    @objc private func handleWake() {
        networkMonitor.reset()
        guard !isMonitoringPaused else { return }
        displayedConnectionState = pathState
        contentView.updateConnection(pathState, summary: contentView.chartView.summary)
        startMonitoringTimers()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let applicationDelegate = AppDelegate()
    application.delegate = applicationDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}
