import XCTest
@testable import Tekulog

/// `ExploreMapView` の純粋なヘルパー(表示ラベル生成・方位差)のみを対象にする。
/// フォグの描画は `FogPainterTests`、実際の地図操作は実機での目視確認が対象。
/// `ExploreMapView` は SwiftUI の @State/@EnvironmentObject を持つため MainActor 隔離されており、
/// このテストクラスも @MainActor にする必要がある。
@MainActor
final class ExploreMapViewTests: XCTestCase {

    // MARK: - compassLabel

    func testCompassLabelForCardinalDirections() {
        let view = ExploreMapView()
        XCTAssertEqual(view.compassLabel(0), "北")
        XCTAssertEqual(view.compassLabel(90), "東")
        XCTAssertEqual(view.compassLabel(180), "南")
        XCTAssertEqual(view.compassLabel(270), "西")
    }

    func testCompassLabelWrapsAroundThreeHundredSixty() {
        let view = ExploreMapView()
        XCTAssertEqual(view.compassLabel(350), "北", "350°は北(0°)に最も近い")
    }

    // MARK: - distanceLabel

    func testDistanceLabelUsesMetersBelowOneKilometer() {
        let view = ExploreMapView()
        XCTAssertEqual(view.distanceLabel(850), "850m")
    }

    func testDistanceLabelUsesKilometersAtOrAboveOneKilometer() {
        let view = ExploreMapView()
        XCTAssertEqual(view.distanceLabel(1500), "1.5km")
    }

    // MARK: - angularDifference

    func testAngularDifferenceHandlesWraparound() {
        let view = ExploreMapView()
        XCTAssertEqual(view.angularDifference(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(view.angularDifference(10, 350), 20, accuracy: 0.001)
        XCTAssertEqual(view.angularDifference(0, 180), 180, accuracy: 0.001)
    }
}
