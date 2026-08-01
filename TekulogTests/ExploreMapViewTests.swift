import XCTest
import MapKit
@testable import Tekulog

/// `ExploreMapView` の純粋なヘルパー(表示ラベル生成・領域の重なり判定)のみを対象にする。
/// Canvas でのフォグ描画・実際の地図操作は実機/シミュレータでの目視確認が必要
/// (このテストファイルの対象外)。
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

    // MARK: - overlapRatio

    func testOverlapRatioIsOneForIdenticalRegions() {
        let view = ExploreMapView()
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        XCTAssertEqual(view.overlapRatio(region, region), 1, accuracy: 0.001)
    }

    func testOverlapRatioIsZeroForDisjointRegions() {
        let view = ExploreMapView()
        let a = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.00, longitude: 139.00),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        let b = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.00, longitude: 145.00),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        XCTAssertEqual(view.overlapRatio(a, b), 0)
    }

    func testOverlapRatioIsPartialForSlightlyShiftedRegions() {
        let view = ExploreMapView()
        let a = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        // 中心を半分だけずらす → 重なりはおよそ 0.25(縦横それぞれ半分)。
        let b = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.69, longitude: 139.77),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        let ratio = view.overlapRatio(a, b)
        XCTAssertGreaterThan(ratio, 0)
        XCTAssertLessThan(ratio, 1)
    }
}
