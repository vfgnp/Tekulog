import XCTest
@testable import Tekulog

/// タブの並び順を検証する(受け入れ基準 AC-1)。`Tab` の rawValue は表示順であり、
/// DEBUG の `-initialTab N` 起動引数がそのまま指す番号でもある。
@MainActor
final class MainTabViewTests: XCTestCase {

    func testTabsAreOrderedHomeCalendarExploreMapMyPage() {
        XCTAssertEqual(MainTabView.Tab.home.rawValue, 0)
        XCTAssertEqual(MainTabView.Tab.calendar.rawValue, 1)
        XCTAssertEqual(MainTabView.Tab.exploreMap.rawValue, 2)
        XCTAssertEqual(MainTabView.Tab.myPage.rawValue, 3)
    }

    func testInitialTabArgumentMapsToTheSameOrder() {
        XCTAssertEqual(MainTabView.Tab(rawValue: 0), .home)
        XCTAssertEqual(MainTabView.Tab(rawValue: 1), .calendar, "カレンダーはホームと探索マップの間")
        XCTAssertEqual(MainTabView.Tab(rawValue: 2), .exploreMap)
        XCTAssertEqual(MainTabView.Tab(rawValue: 3), .myPage)
        XCTAssertNil(MainTabView.Tab(rawValue: 4), "タブは4つ")
    }
}
