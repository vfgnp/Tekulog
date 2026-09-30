import XCTest
import MapKit
@testable import Tekulog

/// フォグ描画用の空間索引(`FogCellIndex`)を検証する。
/// 設計: `design/explore-map/03-detailed-design.md` §7、受け入れ基準 AC-6 / AC-7 / AC-18。
final class FogCellIndexTests: XCTestCase {

    private let tokyo = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// 東京周辺(約 ±20km)に散らばった、重複のないセル中心。
    private func scatteredCells(count: Int, seed: UInt64) -> [CLLocationCoordinate2D] {
        var generator = SeededGenerator(state: seed)
        var seen = Set<Int64>()
        var result: [CLLocationCoordinate2D] = []
        while result.count < count {
            let cell = ExplorationGrid.cell(for: .init(
                latitude: tokyo.latitude + Double.random(in: -0.18...0.18, using: &generator),
                longitude: tokyo.longitude + Double.random(in: -0.22...0.22, using: &generator)))
            if seen.insert(cell.key).inserted { result.append(cell.center) }
        }
        return result
    }

    private func collect(_ index: FogCellIndex, in rect: MKMapRect, level: Int) -> [FogCellIndex.Point] {
        var points: [FogCellIndex.Point] = []
        index.forEachPoint(in: rect, level: level) { points.append($0) }
        return points
    }

    // MARK: - 構築

    func testEmptyIndexHasNoCellsAndEnumeratesNothing() {
        let index = FogCellIndex.empty
        XCTAssertEqual(index.cellCount, 0)
        XCTAssertEqual(index.levels.count, FogCellIndex.maxLevel + 1)
        for level in 0...FogCellIndex.maxLevel {
            XCTAssertTrue(collect(index, in: .world, level: level).isEmpty)
        }
    }

    func testInvalidCoordinatesAreDropped() {
        let index = FogCellIndex(coordinates: [
            tokyo,
            CLLocationCoordinate2D(latitude: 200, longitude: 0),
            CLLocationCoordinate2D(latitude: .nan, longitude: 139),
        ])
        XCTAssertEqual(index.cellCount, 1)
    }

    func testLevelZeroKeepsEveryCellAtItsExactPosition() {
        let cells = scatteredCells(count: 400, seed: 1)
        let index = FogCellIndex(coordinates: cells)
        XCTAssertEqual(index.cellCount, 400)

        let all = collect(index, in: .world, level: 0)
        XCTAssertEqual(all.count, 400)
        for cell in cells {
            let expected = MKMapPoint(cell)
            XCTAssertTrue(all.contains { abs($0.x - expected.x) < 1e-6 && abs($0.y - expected.y) < 1e-6 },
                          "レベル0はセル中心をそのままの位置で持つ")
        }
    }

    // MARK: - 矩形クエリ(範囲内のセルが欠けない)

    func testRectQueryNeverMissesAPointInsideTheRectAtAnyLevel() {
        let cells = scatteredCells(count: 600, seed: 2)
        let index = FogCellIndex(coordinates: cells)
        var generator = SeededGenerator(state: 3)

        for level in 0...FogCellIndex.maxLevel {
            let everything = collect(index, in: .world, level: level)
            XCTAssertEqual(everything.count, index.levels[level].pointCount, "レベル\(level): 世界全体なら全点が列挙される")

            for _ in 0..<40 {
                let anchor = MKMapPoint(cells.randomElement(using: &generator)!)
                let width = Double.random(in: 200...400_000, using: &generator)
                let height = Double.random(in: 200...400_000, using: &generator)
                let rect = MKMapRect(x: anchor.x - width * Double.random(in: 0...1, using: &generator),
                                     y: anchor.y - height * Double.random(in: 0...1, using: &generator),
                                     width: width, height: height)
                let found = collect(index, in: rect, level: level)
                let expected = everything.filter {
                    $0.x >= rect.minX && $0.x <= rect.maxX && $0.y >= rect.minY && $0.y <= rect.maxY
                }
                for point in expected {
                    XCTAssertTrue(found.contains { $0.x == point.x && $0.y == point.y },
                                  "レベル\(level): 矩形内の点が列挙されなかった")
                }
            }
        }
    }

    func testFarAwayRectEnumeratesNothing() {
        let index = FogCellIndex(coordinates: scatteredCells(count: 100, seed: 4))
        let osaka = MKMapPoint(CLLocationCoordinate2D(latitude: 34.70, longitude: 135.50))
        let rect = MKMapRect(x: osaka.x - 5_000, y: osaka.y - 5_000, width: 10_000, height: 10_000)
        XCTAssertTrue(collect(index, in: rect, level: 0).isEmpty)
    }

    // MARK: - レベル選択

    func testLevelSelectionIsMonotonicAndKeepsSquaresAtLeastFourPointsOnScreen() {
        let index = FogCellIndex(coordinates: [tokyo])
        var previousLevel = 0
        var zoomScale = 2.0
        while zoomScale > 1e-7 {
            let level = index.level(forZoomScale: zoomScale)
            XCTAssertGreaterThanOrEqual(level, previousLevel, "縮小するほどレベルは上がる(下がらない)")
            XCTAssertTrue((0...FogCellIndex.maxLevel).contains(level))
            let squareOnScreen = index.levels[level].squareSize * zoomScale
            if level < FogCellIndex.maxLevel {
                XCTAssertGreaterThanOrEqual(squareOnScreen, FogCellIndex.minSquareScreenPoints)
            }
            if level > 0 {
                XCTAssertLessThan(index.levels[level - 1].squareSize * zoomScale, FogCellIndex.minSquareScreenPoints,
                                  "条件を満たす最も細かいレベルが選ばれる")
            }
            previousLevel = level
            zoomScale *= 0.7
        }
        XCTAssertEqual(index.level(forZoomScale: 1), 0, "十分に拡大していれば集約しない")
        XCTAssertEqual(index.level(forZoomScale: 0), FogCellIndex.maxLevel)
    }

    /// 1タイル(256pt 四方)に入る点数の上限(設計上 (256/4)² = 4,096)を、敷き詰めデータで確認する。
    func testPointsPerTileAreBoundedAtEveryLevel() {
        let index = FogCellIndex(coordinates: ExplorationGrid.denseBlock(around: tokyo, count: 50_000))
        let center = MKMapPoint(tokyo)
        for level in 0...6 {
            // そのレベルが選ばれる最も縮小側の縮尺(= 1タイルに最も多くの点が入る)。
            let zoomScale = FogCellIndex.minSquareScreenPoints / index.levels[level].squareSize
            XCTAssertEqual(index.level(forZoomScale: zoomScale), level)
            let side = 256 / zoomScale
            let tile = MKMapRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            let inside = collect(index, in: tile, level: level).filter {
                $0.x >= tile.minX && $0.x <= tile.maxX && $0.y >= tile.minY && $0.y <= tile.maxY
            }
            // 上限は 64×64。矩形の両端を含めて数えるので、升目が端に揃うと 65×65 = 4,225 になりうる。
            XCTAssertLessThanOrEqual(inside.count, 65 * 65, "レベル\(level): タイル内の点数が上限を超えた")
        }
    }

    // MARK: - 集約レベル(広域表示でも欠けない)

    func testAggregatedLevelsCoverEveryCell() {
        let cells = scatteredCells(count: 300, seed: 5)
        let index = FogCellIndex(coordinates: cells)
        var previousCount = index.cellCount
        for level in 1...FogCellIndex.maxLevel {
            let target = index.levels[level]
            XCTAssertLessThanOrEqual(target.pointCount, previousCount, "集約するほど点は減る(増えない)")
            XCTAssertGreaterThan(target.pointCount, 0)
            previousCount = target.pointCount

            let points = collect(index, in: .world, level: level)
            let reach = target.squareSize * 0.7072   // 升目の中心から隅まで
            for cell in cells {
                let mapPoint = MKMapPoint(cell)
                let covered = points.contains {
                    let dx = $0.x - mapPoint.x, dy = $0.y - mapPoint.y
                    return (dx * dx + dy * dy).squareRoot() <= reach
                }
                XCTAssertTrue(covered, "レベル\(level): どの升目にも覆われないセルがある")
            }
        }
    }
}
