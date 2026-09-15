import XCTest
@testable import ClaudeTry

final class ChartStyleTests: XCTestCase {
    func test_order_includesOpenCode() {
        XCTAssertTrue(ModelStyle.order.contains("OpenCode"))
    }

    func test_color_openCodeAndBedrock_areDistinct() {
        XCTAssertNotEqual(ModelStyle.color("OpenCode"), ModelStyle.color("Bedrock"))
        XCTAssertNotEqual(ModelStyle.color("OpenCode"), ModelStyle.color("Claude.ai"))
    }
}
