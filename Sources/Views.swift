import AppKit
import Foundation

// MARK: - Popover root

final class PopoverContentView: NSVisualEffectView {
    let testButton = NSButton(title: "Run test", target: nil, action: nil)
    let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    let settingsButton = NSButton(title: "Settings…", target: nil, action: nil)
    let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    private let connectionSymbol = NSImageView()
    private let connectionLabel = PopoverContentView.label()
    private let currentLatencyLabel = PopoverContentView.label(alignment: .right)
    private let connectionDetailLabel = PopoverContentView.label()
    private let freshnessLabel = PopoverContentView.label(alignment: .right)

    private let liveCadenceLabel = PopoverContentView.label(alignment: .right)
    private let downloadValueLabel = PopoverContentView.label()
    private let uploadValueLabel = PopoverContentView.label()

    private let latencySummaryLabel = PopoverContentView.label(alignment: .right)
    let chartView = LatencyChartView(frame: NSRect(x: 16, y: 126, width: 328, height: 157))

    private let speedTestHeadingLabel = PopoverContentView.label()
    private let speedTestTimestampLabel = PopoverContentView.label(alignment: .right)
    private let downloadResultLabel = PopoverContentView.label()
    private let uploadResultLabel = PopoverContentView.label()

    private var connectionState: ConnectionState = .checking
    private var latencySummary: LatencySummary = .empty
    private var lastResult: SpeedTestResult?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        setUpConnectionSection()
        setUpLiveTrafficSection()
        setUpLatencySection()
        setUpSpeedTestSection()
        setUpFooter()
        updateConnection(.checking, summary: .empty)
        updateTraffic(.zero)
        updateSpeedTest(result: nil, state: .idle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.background.cgColor
        chartView.needsDisplay = true
    }

    func updateConnection(_ state: ConnectionState, summary: LatencySummary) {
        connectionState = state
        latencySummary = summary

        connectionLabel.stringValue = state.title
        connectionDetailLabel.stringValue = state.subtitle

        let symbolName: String
        let symbolColor: NSColor
        switch state.availability {
        case .checking:
            symbolName = "circle.dotted"
            symbolColor = Theme.textSecondary
        case .online:
            symbolName = "circle.fill"
            symbolColor = Theme.success
        case .connecting:
            symbolName = "circle.dotted"
            symbolColor = Theme.warning
        case .offline:
            symbolName = "exclamationmark.circle.fill"
            symbolColor = Theme.critical
        case .paused:
            symbolName = "pause.circle.fill"
            symbolColor = Theme.textSecondary
        }
        connectionSymbol.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        connectionSymbol.contentTintColor = symbolColor

        guard state.isOnline else {
            currentLatencyLabel.stringValue = "—"
            freshnessLabel.stringValue = ""
            updateConnectionAccessibility()
            return
        }

        let isFresh = summary.latestTimestamp.map {
            Date().timeIntervalSince($0) <= 3
        } ?? false

        if isFresh, let current = summary.current {
            currentLatencyLabel.stringValue = "\(Int(current.rounded())) ms"
            freshnessLabel.stringValue = "now"
        } else if isFresh, summary.latestMeasurement == .timedOut {
            currentLatencyLabel.stringValue = "—"
            freshnessLabel.stringValue = "probe timed out"
        } else {
            currentLatencyLabel.stringValue = "—"
            freshnessLabel.stringValue = "measuring"
        }
        updateConnectionAccessibility()
    }

    func updateTraffic(_ sample: ThroughputSample) {
        downloadValueLabel.stringValue = RateFormatter.bytesPerSecond(
            sample.downloadBytesPerSecond
        )
        uploadValueLabel.stringValue = RateFormatter.bytesPerSecond(
            sample.uploadBytesPerSecond
        )
        liveCadenceLabel.stringValue = connectionState.isOnline ? "per second" : "not connected"

        let value = "Download \(downloadValueLabel.stringValue), upload \(uploadValueLabel.stringValue)"
        setAccessibilityLabel("Live traffic")
        downloadValueLabel.setAccessibilityValue(value)
    }

    func updateLatency(_ history: [LatencyPoint]) {
        chartView.latencyHistory = history
        latencySummary = chartView.summary

        let summaryParts = [
            chartView.summary.average.map { "Avg \(Int($0.rounded())) ms" },
            chartView.summary.lossPercentage.map { "Loss \(String(format: "%.0f", $0))%" }
        ].compactMap { $0 }
        latencySummaryLabel.stringValue = summaryParts.isEmpty
            ? "1 sec samples · 5 min"
            : summaryParts.joined(separator: " · ")

        updateConnection(connectionState, summary: chartView.summary)
    }

    func updateSpeedTest(result: SpeedTestResult?, state: SpeedTest.State) {
        if let result {
            lastResult = result
        }

        switch state {
        case .idle:
            showStoredResultOrEmpty()
        case .testing(let phase):
            speedTestHeadingLabel.stringValue = phase.rawValue
            speedTestTimestampLabel.stringValue = "Cloudflare"
            if lastResult == nil {
                downloadResultLabel.stringValue = "Quick capacity estimate"
                uploadResultLabel.stringValue = ""
            } else {
                showResultValues(lastResult)
            }
            testButton.title = "Cancel"
            testButton.toolTip = "Cancel the current speed test"
        case .completed(let completedResult):
            lastResult = completedResult
            showStoredResultOrEmpty()
            testButton.title = "Run again"
        case .failed(let message):
            speedTestHeadingLabel.stringValue = "Speed test failed"
            speedTestTimestampLabel.stringValue = ""
            downloadResultLabel.frame = NSRect(x: 16, y: 64, width: 228, height: 25)
            downloadResultLabel.stringValue = message
            downloadResultLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            downloadResultLabel.textColor = Theme.critical
            uploadResultLabel.stringValue = ""
            testButton.title = "Retry"
            testButton.toolTip = "Retry the speed test"
        case .cancelled:
            speedTestHeadingLabel.stringValue = "Speed test cancelled"
            speedTestTimestampLabel.stringValue = ""
            if lastResult == nil {
                downloadResultLabel.frame = NSRect(x: 16, y: 64, width: 228, height: 25)
                downloadResultLabel.stringValue = "No result was saved"
                downloadResultLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
                downloadResultLabel.textColor = Theme.textSecondary
                uploadResultLabel.stringValue = ""
            } else {
                showResultValues(lastResult)
            }
            testButton.title = "Run test"
            testButton.toolTip = speedTestHelp
        }
    }

    func refreshRelativeTimes() {
        guard let lastResult else { return }
        if testButton.title != "Cancel" {
            speedTestTimestampLabel.stringValue = RelativeTimeFormatter.string(
                since: lastResult.completedAt
            )
        }
    }

    private func setUpConnectionSection() {
        connectionSymbol.frame = NSRect(x: 16, y: 439, width: 10, height: 10)
        connectionSymbol.imageScaling = .scaleProportionallyUpOrDown
        connectionSymbol.setAccessibilityElement(false)
        addSubview(connectionSymbol)

        connectionLabel.frame = NSRect(x: 34, y: 428, width: 194, height: 26)
        connectionLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        connectionLabel.textColor = Theme.textPrimary
        addSubview(connectionLabel)

        currentLatencyLabel.frame = NSRect(x: 248, y: 428, width: 96, height: 26)
        currentLatencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        currentLatencyLabel.textColor = Theme.textPrimary
        addSubview(currentLatencyLabel)

        connectionDetailLabel.frame = NSRect(x: 34, y: 409, width: 206, height: 16)
        connectionDetailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        connectionDetailLabel.textColor = Theme.textSecondary
        addSubview(connectionDetailLabel)

        freshnessLabel.frame = NSRect(x: 244, y: 409, width: 100, height: 16)
        freshnessLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        freshnessLabel.textColor = Theme.textSecondary
        addSubview(freshnessLabel)

        addSeparator(y: 396)
    }

    private func setUpLiveTrafficSection() {
        let heading = Self.label()
        heading.frame = NSRect(x: 16, y: 373, width: 120, height: 17)
        heading.stringValue = "Live traffic"
        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = Theme.textPrimary
        addSubview(heading)

        liveCadenceLabel.frame = NSRect(x: 240, y: 373, width: 104, height: 17)
        liveCadenceLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        liveCadenceLabel.textColor = Theme.textSecondary
        addSubview(liveCadenceLabel)

        let downloadCaption = Self.label()
        downloadCaption.frame = NSRect(x: 16, y: 352, width: 152, height: 16)
        downloadCaption.stringValue = "↓ Download"
        downloadCaption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        downloadCaption.textColor = Theme.textSecondary
        addSubview(downloadCaption)

        let uploadCaption = Self.label()
        uploadCaption.frame = NSRect(x: 184, y: 352, width: 160, height: 16)
        uploadCaption.stringValue = "↑ Upload"
        uploadCaption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        uploadCaption.textColor = Theme.textSecondary
        addSubview(uploadCaption)

        downloadValueLabel.frame = NSRect(x: 16, y: 322, width: 152, height: 28)
        downloadValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        downloadValueLabel.textColor = Theme.textPrimary
        addSubview(downloadValueLabel)

        uploadValueLabel.frame = NSRect(x: 184, y: 322, width: 160, height: 28)
        uploadValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        uploadValueLabel.textColor = Theme.textPrimary
        addSubview(uploadValueLabel)

        let columnSeparator = NSBox(frame: NSRect(x: 176, y: 324, width: 1, height: 40))
        columnSeparator.boxType = .separator
        addSubview(columnSeparator)
        addSeparator(y: 313)
    }

    private func setUpLatencySection() {
        let heading = Self.label()
        heading.frame = NSRect(x: 16, y: 291, width: 168, height: 17)
        heading.stringValue = "Latency · last 5 min"
        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = Theme.textPrimary
        addSubview(heading)

        latencySummaryLabel.frame = NSRect(x: 184, y: 291, width: 160, height: 17)
        latencySummaryLabel.stringValue = "1 sec samples · 5 min"
        latencySummaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        latencySummaryLabel.textColor = Theme.textSecondary
        addSubview(latencySummaryLabel)

        addSubview(chartView)
        addSeparator(y: 116)
    }

    private func setUpSpeedTestSection() {
        speedTestHeadingLabel.frame = NSRect(x: 16, y: 94, width: 218, height: 17)
        speedTestHeadingLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        speedTestHeadingLabel.textColor = Theme.textPrimary
        addSubview(speedTestHeadingLabel)

        speedTestTimestampLabel.frame = NSRect(x: 240, y: 94, width: 104, height: 17)
        speedTestTimestampLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        speedTestTimestampLabel.textColor = Theme.textSecondary
        addSubview(speedTestTimestampLabel)

        configureResultLabel(downloadResultLabel, frame: NSRect(x: 16, y: 64, width: 110, height: 25))
        configureResultLabel(uploadResultLabel, frame: NSRect(x: 132, y: 64, width: 112, height: 25))

        testButton.frame = NSRect(x: 252, y: 62, width: 92, height: 32)
        testButton.bezelStyle = .rounded
        testButton.controlSize = .large
        testButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        testButton.bezelColor = Theme.accent
        testButton.contentTintColor = .white
        testButton.toolTip = speedTestHelp
        testButton.setAccessibilityLabel("Run speed test")
        addSubview(testButton)

        addSeparator(y: 49)
    }

    private func setUpFooter() {
        launchAtLoginButton.frame = NSRect(x: 16, y: 14, width: 158, height: 22)
        launchAtLoginButton.font = NSFont.systemFont(ofSize: 12)
        launchAtLoginButton.setAccessibilityHelp(
            "Start SpeedBar automatically after you sign in"
        )
        addSubview(launchAtLoginButton)

        settingsButton.frame = NSRect(x: 196, y: 11, width: 82, height: 28)
        settingsButton.bezelStyle = .inline
        settingsButton.font = NSFont.systemFont(ofSize: 12)
        settingsButton.setAccessibilityHelp("Open SpeedBar options")
        addSubview(settingsButton)

        quitButton.frame = NSRect(x: 290, y: 11, width: 54, height: 28)
        quitButton.bezelStyle = .inline
        quitButton.font = NSFont.systemFont(ofSize: 12)
        quitButton.setAccessibilityLabel("Quit SpeedBar")
        addSubview(quitButton)
    }

    private func configureResultLabel(_ label: NSTextField, frame: NSRect) {
        label.frame = frame
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    private func addSeparator(y: CGFloat) {
        let separator = NSBox(frame: NSRect(x: 16, y: y, width: 328, height: 1))
        separator.boxType = .separator
        addSubview(separator)
    }

    private func showStoredResultOrEmpty() {
        guard let lastResult else {
            speedTestHeadingLabel.stringValue = "Speed test"
            speedTestTimestampLabel.stringValue = ""
            downloadResultLabel.frame = NSRect(x: 16, y: 64, width: 228, height: 25)
            downloadResultLabel.stringValue = "No test yet · about 20 MB down + 5 MB up"
            downloadResultLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            downloadResultLabel.textColor = Theme.textSecondary
            uploadResultLabel.stringValue = ""
            testButton.title = "Run test"
            testButton.toolTip = speedTestHelp
            return
        }

        speedTestHeadingLabel.stringValue = "Last speed test · Cloudflare"
        speedTestTimestampLabel.stringValue = RelativeTimeFormatter.string(
            since: lastResult.completedAt
        )
        showResultValues(lastResult)
        testButton.title = "Run again"
        testButton.toolTip = speedTestHelp
    }

    private func showResultValues(_ result: SpeedTestResult?) {
        guard let result else { return }
        downloadResultLabel.frame = NSRect(x: 16, y: 64, width: 110, height: 25)
        downloadResultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        downloadResultLabel.textColor = Theme.textPrimary
        downloadResultLabel.stringValue = "↓ \(RateFormatter.bitsPerSecond(result.downloadBytesPerSecond))"

        uploadResultLabel.stringValue = "↑ \(RateFormatter.bitsPerSecond(result.uploadBytesPerSecond))"
        uploadResultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        uploadResultLabel.textColor = Theme.textPrimary
    }

    private func updateConnectionAccessibility() {
        let latencyText = currentLatencyLabel.stringValue == "—"
            ? freshnessLabel.stringValue
            : "latency \(currentLatencyLabel.stringValue)"
        connectionLabel.setAccessibilityLabel("Connection")
        connectionLabel.setAccessibilityValue(
            "\(connectionState.title), \(connectionState.subtitle), \(latencyText)"
        )
    }

    private var speedTestHelp: String {
        "Measures connection capacity using about 20 MB of download data and 5 MB of upload data."
    }

    private static func label(alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }
}

// MARK: - Latency scope

final class LatencyChartView: NSView {
    private struct YAxisScale {
        let maxValue: Double
        let interval: Double
    }

    var latencyHistory: [LatencyPoint] = [] {
        didSet {
            summary = calculateSummary()
            updateAccessibilitySummary()
            needsDisplay = true
        }
    }

    private(set) var summary: LatencySummary = .empty

    private let chartPadding: CGFloat = 10
    private let rightPadding: CGFloat = 49
    private let bottomPadding: CGFloat = 23
    private let topPadding: CGFloat = 12
    private let windowDuration: TimeInterval = 300
    private let sampleInterval: TimeInterval = 1
    private let minimumYAxisMax: Double = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Latency history")
        toolTip = "Blue is latency. Amber triangles are clipped spikes. Red crosses are missed probes."
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        Theme.panel.setFill()
        let cardPath = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        cardPath.fill()
        Theme.panelBorder.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        let chartRect = NSRect(
            x: chartPadding,
            y: bottomPadding,
            width: bounds.width - chartPadding - rightPadding,
            height: bounds.height - bottomPadding - topPadding
        )
        guard chartRect.width > 0, chartRect.height > 0 else { return }

        let now = Date()
        let windowStart = now.addingTimeInterval(-windowDuration)
        let visiblePoints = latencyHistory.filter { $0.timestamp >= windowStart }
        let validLatencies = visiblePoints.compactMap(\.latency).filter(\.isFinite)
        let scale = computeYAxisScale(from: validLatencies)

        drawYAxis(in: chartRect, scale: scale)
        drawXAxis(in: chartRect)

        if visiblePoints.isEmpty {
            drawEmptyMessage("Collecting latency history…", in: chartRect)
            return
        }
        if validLatencies.isEmpty,
           visiblePoints.allSatisfy({ $0.measurement == .offline }) {
            drawEmptyMessage("Latency starts when you’re online.", in: chartRect)
            return
        }

        drawLatencyLine(
            in: chartRect,
            points: visiblePoints,
            windowStart: windowStart,
            scale: scale
        )
        drawExceptionalMarkers(
            in: chartRect,
            points: visiblePoints,
            windowStart: windowStart,
            scale: scale
        )
    }

    private func calculateSummary(now: Date = Date()) -> LatencySummary {
        let cutoff = now.addingTimeInterval(-60)
        let recent = latencyHistory.filter { $0.timestamp >= cutoff }
        let successfulValues = recent.compactMap(\.latency).filter(\.isFinite)
        let average = successfulValues.isEmpty
            ? nil
            : successfulValues.reduce(0, +) / Double(successfulValues.count)

        let differences = zip(successfulValues, successfulValues.dropFirst()).map {
            abs($1 - $0)
        }
        let jitter = differences.isEmpty
            ? nil
            : differences.reduce(0, +) / Double(differences.count)

        let attempted = recent.filter { $0.measurement != .offline }
        let failures = attempted.filter { $0.measurement == .timedOut }.count
        let loss = attempted.isEmpty
            ? nil
            : Double(failures) / Double(attempted.count) * 100

        let latest = latencyHistory.last
        let isFresh = latest.map { now.timeIntervalSince($0.timestamp) <= 3 } ?? false
        let current = isFresh ? latest?.latency : nil

        return LatencySummary(
            current: current,
            average: average,
            jitter: jitter,
            lossPercentage: loss,
            latestMeasurement: latest?.measurement,
            latestTimestamp: latest?.timestamp
        )
    }

    private func computeYAxisScale(from latencies: [Double]) -> YAxisScale {
        guard !latencies.isEmpty else {
            return YAxisScale(maxValue: minimumYAxisMax, interval: minimumYAxisMax / 2)
        }

        let sorted = latencies.sorted()
        let percentileIndex = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        let targetMax = max(minimumYAxisMax, sorted[percentileIndex] * 1.25)
        let interval = niceInterval(for: targetMax / 2)
        return YAxisScale(maxValue: interval * 2, interval: interval)
    }

    private func niceInterval(for value: Double) -> Double {
        guard value > 0 else { return 20 }
        let magnitude = pow(10, floor(log10(value)))
        let fraction = value / magnitude
        let niceFraction: Double
        if fraction <= 1 {
            niceFraction = 1
        } else if fraction <= 2 {
            niceFraction = 2
        } else if fraction <= 5 {
            niceFraction = 5
        } else {
            niceFraction = 10
        }
        return niceFraction * magnitude
    }

    private func drawYAxis(in rect: NSRect, scale: YAxisScale) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ]

        for index in 0...2 {
            let value = Double(index) * scale.interval
            let y = rect.minY + rect.height * CGFloat(index) / 2
            let label = "\(Int(value.rounded()))"
            (label as NSString).draw(
                at: NSPoint(x: rect.maxX + 6, y: y - 5),
                withAttributes: attributes
            )

            Theme.grid.setStroke()
            let gridPath = NSBezierPath()
            gridPath.move(to: NSPoint(x: rect.minX, y: y))
            gridPath.line(to: NSPoint(x: rect.maxX, y: y))
            gridPath.lineWidth = 0.5
            gridPath.stroke()
        }

        if scale.maxValue > 100 {
            let y = yPosition(for: 100, in: rect, scale: scale)
            let threshold = NSBezierPath()
            threshold.move(to: NSPoint(x: rect.minX, y: y))
            threshold.line(to: NSPoint(x: rect.maxX, y: y))
            threshold.setLineDash([4, 4], count: 2, phase: 0)
            threshold.lineWidth = 0.7
            Theme.warning.withAlphaComponent(0.7).setStroke()
            threshold.stroke()
        }
    }

    private func drawXAxis(in rect: NSRect) {
        let labels: [(String, CGFloat)] = [
            ("−5m", 0),
            ("−2m", 0.6),
            ("now", 1)
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        ]

        for (label, fraction) in labels {
            let x = rect.minX + rect.width * fraction
            let size = (label as NSString).size(withAttributes: attributes)
            let labelX = max(
                rect.minX,
                min(x - size.width / 2, rect.maxX - size.width)
            )
            (label as NSString).draw(
                at: NSPoint(x: labelX, y: 6),
                withAttributes: attributes
            )
        }
    }

    private func drawLatencyLine(
        in rect: NSRect,
        points: [LatencyPoint],
        windowStart: Date,
        scale: YAxisScale
    ) {
        let segments = lineSegments(
            in: rect,
            points: points,
            windowStart: windowStart,
            scale: scale
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()

        for segment in segments where !segment.isEmpty {
            let linePath = NSBezierPath()
            linePath.move(to: segment[0])
            for point in segment.dropFirst() {
                linePath.line(to: point)
            }
            linePath.lineWidth = 2
            linePath.lineJoinStyle = .round
            linePath.lineCapStyle = .round
            Theme.accent.setStroke()
            linePath.stroke()
        }

        if let latest = segments.last?.last {
            Theme.panel.setFill()
            Theme.accent.setStroke()
            let endpoint = NSBezierPath(
                ovalIn: NSRect(x: latest.x - 3, y: latest.y - 3, width: 6, height: 6)
            )
            endpoint.lineWidth = 2
            endpoint.fill()
            endpoint.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func lineSegments(
        in rect: NSRect,
        points: [LatencyPoint],
        windowStart: Date,
        scale: YAxisScale
    ) -> [[NSPoint]] {
        var segments: [[NSPoint]] = []
        var current: [NSPoint] = []
        var previousTimestamp: Date?

        for point in points {
            guard let latency = point.latency, latency.isFinite else {
                if !current.isEmpty { segments.append(current) }
                current = []
                previousTimestamp = nil
                continue
            }

            if let previousTimestamp,
               point.timestamp.timeIntervalSince(previousTimestamp) > sampleInterval * 2.5 {
                if !current.isEmpty { segments.append(current) }
                current = []
            }

            current.append(
                NSPoint(
                    x: xPosition(for: point.timestamp, in: rect, windowStart: windowStart),
                    y: yPosition(for: latency, in: rect, scale: scale)
                )
            )
            previousTimestamp = point.timestamp
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private func drawExceptionalMarkers(
        in rect: NSRect,
        points: [LatencyPoint],
        windowStart: Date,
        scale: YAxisScale
    ) {
        for point in points {
            let x = xPosition(for: point.timestamp, in: rect, windowStart: windowStart)
            switch point.measurement {
            case .success(let latency) where latency > scale.maxValue:
                Theme.warning.setFill()
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: x, y: rect.maxY - 7))
                triangle.line(to: NSPoint(x: x - 3.5, y: rect.maxY - 1))
                triangle.line(to: NSPoint(x: x + 3.5, y: rect.maxY - 1))
                triangle.close()
                triangle.fill()
            case .timedOut:
                Theme.critical.setStroke()
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: x - 3, y: rect.maxY - 7))
                cross.line(to: NSPoint(x: x + 3, y: rect.maxY - 1))
                cross.move(to: NSPoint(x: x + 3, y: rect.maxY - 7))
                cross.line(to: NSPoint(x: x - 3, y: rect.maxY - 1))
                cross.lineWidth = 1.5
                cross.stroke()
            case .offline:
                Theme.textSecondary.withAlphaComponent(0.6).setFill()
                NSBezierPath(
                    ovalIn: NSRect(x: x - 1.5, y: rect.minY + 2, width: 3, height: 3)
                ).fill()
            case .success:
                break
            }
        }
    }

    private func drawEmptyMessage(_ message: String, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textSecondary,
            .font: NSFont.systemFont(ofSize: 11, weight: .regular)
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        (message as NSString).draw(
            at: NSPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func xPosition(
        for timestamp: Date,
        in rect: NSRect,
        windowStart: Date
    ) -> CGFloat {
        let fraction = max(
            0,
            min(timestamp.timeIntervalSince(windowStart) / windowDuration, 1)
        )
        return rect.minX + rect.width * CGFloat(fraction)
    }

    private func yPosition(
        for latency: Double,
        in rect: NSRect,
        scale: YAxisScale
    ) -> CGFloat {
        let normalized = max(0, min(latency / scale.maxValue, 1))
        return rect.minY + rect.height * CGFloat(normalized)
    }

    private func updateAccessibilitySummary() {
        let currentText = summary.current.map {
            "Current \(Int($0.rounded())) milliseconds"
        } ?? "No current reading"
        let averageText = summary.average.map {
            "average \(Int($0.rounded())) milliseconds"
        } ?? "average unavailable"
        let jitterText = summary.jitter.map {
            "jitter \(Int($0.rounded())) milliseconds"
        } ?? "jitter unavailable"
        let lossText = summary.lossPercentage.map {
            "\(Int($0.rounded())) percent missed probes"
        } ?? "probe loss unavailable"
        setAccessibilityValue(
            [currentText, averageText, jitterText, lossText].joined(separator: ", ")
        )
    }
}
