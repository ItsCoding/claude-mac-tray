import XCTest
@testable import ClaudeTry

final class UsageSnapshotTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_000_000)

    func test_decode_fullPayloadWithRateLimits() throws {
        let json = """
        {"session_id":"abc","cost":{"total_cost_usd":0.5,"total_duration_ms":45000,"total_api_duration_ms":2300},
         "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                        "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
        """
        let snap = try XCTUnwrap(UsageSnapshot.decode(Data(json.utf8), writtenAt: when))
        XCTAssertEqual(snap.sessionID, "abc")
        XCTAssertEqual(snap.writtenAt, when)
        XCTAssertEqual(snap.costUSD, 0.5)
        XCTAssertEqual(snap.apiDurationMs, 2300)
        XCTAssertEqual(snap.wallDurationMs, 45000)
        XCTAssertEqual(snap.fiveHour?.usedPercentage, 23.5)
        XCTAssertEqual(snap.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1738425600))
        XCTAssertEqual(snap.sevenDay?.usedPercentage, 41.2)
        XCTAssertEqual(snap.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1738857600))
    }

    func test_decode_bedrockPayloadHasNoRateLimits() throws {
        let json = """
        {"session_id":"xyz","cost":{"total_cost_usd":1.25,"total_duration_ms":1000,"total_api_duration_ms":500}}
        """
        let snap = try XCTUnwrap(UsageSnapshot.decode(Data(json.utf8), writtenAt: when))
        XCTAssertEqual(snap.sessionID, "xyz")
        XCTAssertEqual(snap.costUSD, 1.25)
        XCTAssertNil(snap.fiveHour)
        XCTAssertNil(snap.sevenDay)
    }

    func test_decode_malformedJSON_returnsNil() {
        XCTAssertNil(UsageSnapshot.decode(Data("not json".utf8), writtenAt: when))
    }

    func test_decode_missingSessionID_returnsNil() {
        XCTAssertNil(UsageSnapshot.decode(Data(#"{"cost":{"total_cost_usd":1}}"#.utf8), writtenAt: when))
    }

    func test_decode_missingCostFields_areNil() throws {
        let snap = try XCTUnwrap(UsageSnapshot.decode(Data(#"{"session_id":"s"}"#.utf8), writtenAt: when))
        XCTAssertNil(snap.costUSD)
        XCTAssertNil(snap.apiDurationMs)
        XCTAssertNil(snap.wallDurationMs)
    }
}
