import AppKit
import XCTest
@testable import InternetSpeed

@MainActor
final class PopoverLayoutTests: XCTestCase {
    func testPopoverRendersAndKeepsControlsInsideBounds() throws {
        _ = NSApplication.shared
        let view = PopoverContentView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 472)
        )
        view.appearance = NSAppearance(named: .darkAqua)
        let now = Date()
        var points: [LatencyPoint] = []
        for index in 0..<90 {
            let measurement: LatencyMeasurement
            if index == 54 {
                measurement = .timedOut
            } else {
                measurement = .success(
                    milliseconds: 24 + sin(Double(index) / 6) * 7
                )
            }
            points.append(
                LatencyPoint(
                    timestamp: now.addingTimeInterval(Double(index - 89)),
                    measurement: measurement
                )
            )
        }
        let result = SpeedTestResult(
            downloadBytesPerSecond: 20_250_000,
            uploadBytesPerSecond: 4_350_000,
            completedAt: now.addingTimeInterval(-480)
        )
        let connection = ConnectionState(
            availability: .online,
            interfaceName: "en0",
            interfaceLabel: "Wi‑Fi",
            isExpensive: false,
            isConstrained: false
        )

        view.updateConnection(connection, summary: .empty)
        view.updateTraffic(
            ThroughputSample(
                downloadBytesPerSecond: 1_240_000,
                uploadBytesPerSecond: 318_000
            )
        )
        view.updateLatency(points)
        view.updateConnection(connection, summary: view.chartView.summary)
        view.updateSpeedTest(result: result, state: .completed(result))
        view.layoutSubtreeIfNeeded()

        for control in [
            view.testButton,
            view.launchAtLoginButton,
            view.settingsButton,
            view.quitButton
        ] {
            XCTAssertTrue(view.bounds.contains(control.frame))
        }
        XCTAssertEqual(view.chartView.frame, NSRect(x: 16, y: 126, width: 328, height: 157))

        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not create a popover bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode the popover bitmap")
            return
        }
        XCTAssertGreaterThan(png.count, 10_000)

        if let outputPath = ProcessInfo.processInfo.environment["SPEEDBAR_SNAPSHOT_PATH"] {
            try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }
}
