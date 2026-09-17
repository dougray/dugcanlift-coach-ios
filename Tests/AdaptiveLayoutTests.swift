import XCTest
@testable import Coach

/// Pins the width rules the large-screen layouts are built on. The one that
/// matters most is the first: at iPhone portrait width everything must resolve
/// to the single column Coach has always had.
final class AdaptiveLayoutTests: XCTestCase {

    /// Content width inside a page's padding for a window `points` wide.
    private func content(_ points: CGFloat) -> CGFloat {
        AdaptiveLayout.contentWidth(in: points)
    }

    func testEveryIPhonePortraitWidthIsOneColumn() {
        // iPhone SE through the widest Pro Max.
        for width in [320, 375, 393, 402, 430, 440] as [CGFloat] {
            let w = content(width)
            XCTAssertEqual(AdaptiveLayout.columns(for: w), 1, "width \(width)")
            XCTAssertEqual(AdaptiveLayout.columns(for: w, minColumnWidth: 280), 1, "width \(width)")
            XCTAssertFalse(AdaptiveLayout.showsWeekGrid(width: w), "width \(width)")
            XCTAssertFalse(AdaptiveLayout.showsSideColumn(width: w), "width \(width)")
        }
    }

    func testUnmeasuredWidthIsOneColumn() {
        XCTAssertEqual(AdaptiveLayout.columns(for: 0), 1)
        XCTAssertEqual(AdaptiveLayout.columns(for: -10), 1)
        XCTAssertFalse(AdaptiveLayout.showsWeekGrid(width: 0))
    }

    func testColumnsNeedTheirMinimumWidthEach() {
        // Two 320 pt columns and a 12 pt gutter need 652 pt.
        XCTAssertEqual(AdaptiveLayout.columns(for: 651), 1)
        XCTAssertEqual(AdaptiveLayout.columns(for: 652), 2)
        XCTAssertEqual(AdaptiveLayout.columns(for: 984), 3)
    }

    func testColumnsAreClampedToTheMaximum() {
        XCTAssertEqual(AdaptiveLayout.columns(for: 5000, maxColumns: 2), 2)
        XCTAssertEqual(AdaptiveLayout.columns(for: 5000, maxColumns: 1), 1)
    }

    func testWeekGridNeedsSevenDayColumns() {
        // 7 x 128 + 6 x 12 = 968.
        XCTAssertFalse(AdaptiveLayout.showsWeekGrid(width: 967))
        XCTAssertTrue(AdaptiveLayout.showsWeekGrid(width: 968))
    }

    func testSideColumnOnlyWhenChartsStillSitTwoAbreast() {
        let threshold = AdaptiveLayout.sideColumnMinContentWidth
        XCTAssertFalse(AdaptiveLayout.showsSideColumn(width: threshold - 1))
        XCTAssertTrue(AdaptiveLayout.showsSideColumn(width: threshold))
        let chartsWidth = threshold - AdaptiveLayout.sideColumnWidth - AdaptiveLayout.gutter
        XCTAssertEqual(AdaptiveLayout.columns(for: chartsWidth, maxColumns: 2), 2)
    }

    func testContentWidthIsCappedSoPagesStopGrowing() {
        XCTAssertEqual(content(3000), AdaptiveLayout.maxContentWidth - 2 * AdaptiveLayout.pagePadding)
        XCTAssertEqual(content(10), 0)
    }
}
