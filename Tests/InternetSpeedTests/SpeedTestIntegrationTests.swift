import XCTest
@testable import InternetSpeed

final class SpeedTestIntegrationTests: XCTestCase {
    @MainActor
    func testLiveCloudflareSpeedTestCompletesWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["SPEEDBAR_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set SPEEDBAR_RUN_NETWORK_TESTS=1 to run the data-using integration test.")
        }

        let completion = expectation(description: "Speed test completes")
        let speedTest = SpeedTest()

        speedTest.onStateChange = { state in
            switch state {
            case .completed(let result):
                XCTAssertGreaterThan(result.downloadBytesPerSecond, 0)
                XCTAssertGreaterThan(result.uploadBytesPerSecond, 0)
                completion.fulfill()
            case .failed(let message):
                XCTFail(message)
                completion.fulfill()
            case .idle, .testing, .cancelled:
                break
            }
        }

        speedTest.start()
        wait(for: [completion], timeout: 60)
    }
}
