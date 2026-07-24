import XCTest
@testable import InternetSpeed

final class LatencyIntegrationTests: XCTestCase {
    @MainActor
    func testLiveLatencyProbeCompletesWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["SPEEDBAR_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set SPEEDBAR_RUN_NETWORK_TESTS=1 to run the live latency test.")
        }

        let completion = expectation(description: "Latency probe completes")
        let monitor = LatencyMonitor()

        monitor.measureLatency(isOnline: true) { measurement in
            switch measurement {
            case .success(let milliseconds):
                XCTAssertGreaterThan(milliseconds, 0)
                XCTAssertLessThan(milliseconds, 5_000)
            case .timedOut:
                XCTFail("The latency target timed out")
            case .offline:
                XCTFail("The live integration environment is offline")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 3)
    }
}
