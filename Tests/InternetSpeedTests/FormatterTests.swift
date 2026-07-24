import XCTest
@testable import InternetSpeed

final class FormatterTests: XCTestCase {
    func testByteRateUsesExplicitDecimalUnits() {
        XCTAssertEqual(RateFormatter.bytesPerSecond(0), "0 B/s")
        XCTAssertEqual(RateFormatter.bytesPerSecond(1_500), "1.50 KB/s")
        XCTAssertEqual(RateFormatter.bytesPerSecond(12_500_000), "12.5 MB/s")
    }

    func testBitRateConvertsFromBytes() {
        XCTAssertEqual(RateFormatter.bitsPerSecond(125_000), "1.0 Mbps")
        XCTAssertEqual(RateFormatter.bitsPerSecond(12_500_000), "100 Mbps")
    }

    func testInvalidRatesNeverReachTheUI() {
        XCTAssertEqual(RateFormatter.bytesPerSecond(-10), "0 B/s")
        XCTAssertEqual(RateFormatter.bytesPerSecond(.infinity), "0 B/s")
        XCTAssertEqual(RateFormatter.bitsPerSecond(.nan), "0 bps")
    }

    func testRelativeTimeCopy() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(
            RelativeTimeFormatter.string(
                since: now.addingTimeInterval(-5),
                now: now
            ),
            "just now"
        )
        XCTAssertEqual(
            RelativeTimeFormatter.string(
                since: now.addingTimeInterval(-125),
                now: now
            ),
            "2 min ago"
        )
    }

    func testConnectionCopyDistinguishesPausedAndOffline() {
        let offline = ConnectionState(
            availability: .offline,
            interfaceName: nil,
            interfaceLabel: "",
            isExpensive: false,
            isConstrained: false
        )
        let paused = ConnectionState(
            availability: .paused,
            interfaceName: nil,
            interfaceLabel: "",
            isExpensive: false,
            isConstrained: false
        )

        XCTAssertEqual(offline.title, "No internet")
        XCTAssertEqual(paused.title, "Monitoring paused")
    }
}
