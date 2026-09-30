import XCTest
import CoreLocation
@testable import Tekulog

/// 探索グリッド(座標 → セル)の定義を検証する。
/// 設計: `design/explore-map/03-detailed-design.md` §2、受け入れ基準 AC-8 / AC-9。
final class ExplorationGridTests: XCTestCase {

    /// 利用範囲(日本国内)の代表3緯度。
    private let sites: [(name: String, coordinate: CLLocationCoordinate2D)] = [
        ("札幌", CLLocationCoordinate2D(latitude: 43.0621, longitude: 141.3544)),
        ("東京", CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)),
        ("那覇", CLLocationCoordinate2D(latitude: 26.2124, longitude: 127.6792)),
    ]

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// 再現性のある擬似乱数(テストを決定的にするため `SystemRandomNumberGenerator` は使わない)。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // MARK: - 行内で経度バケットが固定(原因 E の回帰テスト)

    /// 同じ緯度行の南端・中央・北端にある同一経度の点は、同じセルにならなければならない。
    /// 旧実装(点自身の緯度で経度セル幅を決める)では、行の南端と北端で経度バケットが
    /// 約1〜1.7セルずれるため、このテストは失敗する。
    func testSameLongitudeWithinOneRowMapsToSameCell() {
        for site in sites {
            let row = ExplorationGrid.latBucket(latitude: site.coordinate.latitude)
            let rowSouth = Double(row) * ExplorationGrid.latCellDegrees
            let rowNorth = Double(row + 1) * ExplorationGrid.latCellDegrees
            let height = rowNorth - rowSouth
            // セル中心の経度を使う(東西の境界から離す。境界線上の点は浮動小数の丸めで隣へ落ちうる)。
            let longitude = ExplorationGrid.cell(for: site.coordinate).center.longitude

            let south = ExplorationGrid.cell(for: .init(latitude: rowSouth + height * 0.01, longitude: longitude))
            let middle = ExplorationGrid.cell(for: .init(latitude: rowSouth + height * 0.50, longitude: longitude))
            let north = ExplorationGrid.cell(for: .init(latitude: rowSouth + height * 0.99, longitude: longitude))

            XCTAssertEqual(south.latBucket, row, "\(site.name): 南端は同じ行のはず")
            XCTAssertEqual(north.latBucket, row, "\(site.name): 北端は同じ行のはず")
            XCTAssertEqual(south, middle, "\(site.name): 南端と中央が別セルになった")
            XCTAssertEqual(north, middle, "\(site.name): 北端と中央が別セルになった")
        }
    }

    /// 経度セル幅は行だけで決まり、行内のどの緯度から求めても変わらない。
    func testLongitudeBucketDependsOnlyOnRow() {
        for site in sites {
            let row = ExplorationGrid.latBucket(latitude: site.coordinate.latitude)
            let width = ExplorationGrid.lonCellDegrees(latBucket: row)
            XCTAssertEqual(ExplorationGrid.lonBucket(longitude: site.coordinate.longitude, latBucket: row),
                           Int32((site.coordinate.longitude / width).rounded(.down)), site.name)
        }
    }

    // MARK: - セル中心の一意性と往復一致

    func testCellCenterRoundTripsToTheSameCell() {
        var generator = SeededGenerator(state: 20260930)
        for site in sites {
            for _ in 0..<5_000 {
                let point = CLLocationCoordinate2D(
                    latitude: site.coordinate.latitude + Double.random(in: -0.2...0.2, using: &generator),
                    longitude: site.coordinate.longitude + Double.random(in: -0.2...0.2, using: &generator))
                let cell = ExplorationGrid.cell(for: point)
                XCTAssertEqual(ExplorationGrid.cell(for: cell.center), cell,
                               "\(site.name): セル中心を再変換したら別セルになった")
            }
        }
    }

    func testCenterIsIdenticalForDifferentPointsInTheSameCell() {
        for site in sites {
            let cell = ExplorationGrid.cell(for: site.coordinate)
            let center = cell.center
            let latStep = ExplorationGrid.latCellDegrees * 0.4
            let lonStep = ExplorationGrid.lonCellDegrees(latBucket: cell.latBucket) * 0.4
            for (dLat, dLon) in [(latStep, lonStep), (-latStep, lonStep), (latStep, -lonStep), (-latStep, -lonStep)] {
                let other = ExplorationGrid.cell(for: .init(latitude: center.latitude + dLat,
                                                            longitude: center.longitude + dLon))
                XCTAssertEqual(other, cell, site.name)
                XCTAssertEqual(other.center.latitude, center.latitude, site.name)
                XCTAssertEqual(other.center.longitude, center.longitude, site.name)
            }
        }
    }

    func testCenterIsWithinHalfDiagonalOfOriginalPoint() {
        var generator = SeededGenerator(state: 7)
        let halfDiagonal = Tunables.explorationCellSizeMeters * 2.0.squareRoot() / 2
        for site in sites {
            for _ in 0..<500 {
                let point = CLLocationCoordinate2D(
                    latitude: site.coordinate.latitude + Double.random(in: -0.05...0.05, using: &generator),
                    longitude: site.coordinate.longitude + Double.random(in: -0.05...0.05, using: &generator))
                let center = ExplorationGrid.cell(for: point).center
                XCTAssertLessThanOrEqual(meters(point, center), halfDiagonal * 1.01, site.name)
            }
        }
    }

    // MARK: - セルの形(おおむね一辺 75m の矩形)

    func testCellWidthAndHeightAreAboutCellSizeAtAllLatitudes() {
        let size = Tunables.explorationCellSizeMeters
        for site in sites {
            let cell = ExplorationGrid.cell(for: site.coordinate)
            let center = cell.center
            let east = ExplorationGrid.center(latBucket: cell.latBucket, lonBucket: cell.lonBucket + 1)
            let north = ExplorationGrid.center(latBucket: cell.latBucket + 1, lonBucket: cell.lonBucket)
            XCTAssertEqual(meters(center, east), size, accuracy: size * 0.01, "\(site.name): 東西幅")
            // 北隣の行は経度幅がわずかに違うので、緯度差だけで南北幅を測る。
            let northSameLongitude = CLLocationCoordinate2D(latitude: north.latitude, longitude: center.longitude)
            XCTAssertEqual(meters(center, northSameLongitude), size, accuracy: size * 0.01, "\(site.name): 南北幅")
        }
    }

    func testNeighbouringCellsAreDistinct() {
        for site in sites {
            let cell = ExplorationGrid.cell(for: site.coordinate)
            let center = cell.center
            let east = ExplorationGrid.cell(for: .init(
                latitude: center.latitude,
                longitude: center.longitude + ExplorationGrid.lonCellDegrees(latBucket: cell.latBucket)))
            let north = ExplorationGrid.cell(for: .init(
                latitude: center.latitude + ExplorationGrid.latCellDegrees, longitude: center.longitude))
            XCTAssertEqual(east, ExplorationGrid.Cell(latBucket: cell.latBucket, lonBucket: cell.lonBucket + 1), site.name)
            XCTAssertEqual(north.latBucket, cell.latBucket + 1, site.name)
        }
    }

    // MARK: - キー

    func testKeyIsInjectiveAndStable() {
        let a = ExplorationGrid.Cell(latBucket: 100, lonBucket: 200)
        let b = ExplorationGrid.Cell(latBucket: 200, lonBucket: 100)
        let negative = ExplorationGrid.Cell(latBucket: -5, lonBucket: -7)
        let negativeSwapped = ExplorationGrid.Cell(latBucket: -7, lonBucket: -5)
        XCTAssertNotEqual(a.key, b.key, "緯度経度を入れ替えたキーが衝突してはいけない")
        XCTAssertNotEqual(negative.key, negativeSwapped.key, "負のバケット(南半球・西経)でも衝突しない")
        XCTAssertEqual(a.key, ExplorationGrid.key(latBucket: 100, lonBucket: 200))
        XCTAssertEqual(Set([a.key, b.key, negative.key, negativeSwapped.key]).count, 4)
    }

    // MARK: - 自宅位置に依存しない

    func testCellDoesNotDependOnHomeLocation() {
        let defaults = UserDefaults.standard
        let keys = [TekTheme.Keys.homeLocationIsSet, TekTheme.Keys.homeLatitude, TekTheme.Keys.homeLongitude]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        let point = sites[1].coordinate
        defaults.set(true, forKey: TekTheme.Keys.homeLocationIsSet)
        defaults.set(35.0, forKey: TekTheme.Keys.homeLatitude)
        defaults.set(139.0, forKey: TekTheme.Keys.homeLongitude)
        let before = ExplorationGrid.cell(for: point)
        defaults.set(43.0, forKey: TekTheme.Keys.homeLatitude)
        defaults.set(141.0, forKey: TekTheme.Keys.homeLongitude)
        let after = ExplorationGrid.cell(for: point)
        XCTAssertEqual(before, after, "自宅を変更してもセルの割り当ては変わらない")
    }

    // MARK: - denseBlock(性能確認用の合成データ)

    func testDenseBlockProducesRequestedNumberOfDistinctCells() {
        let block = ExplorationGrid.denseBlock(around: sites[1].coordinate, count: 1_000)
        XCTAssertEqual(block.count, 1_000)
        XCTAssertEqual(Set(block.map { ExplorationGrid.cell(for: $0).key }).count, 1_000, "合成セルは互いに別セル")
        XCTAssertTrue(ExplorationGrid.denseBlock(around: sites[1].coordinate, count: 0).isEmpty)
    }
}
