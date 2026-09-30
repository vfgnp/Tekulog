import XCTest
import MapKit
import CoreGraphics
@testable import Tekulog

/// フォグ描画(`FogPainter`)をオフスクリーンのビットマップに描いて、ピクセルのα値で検証する。
///
/// 「拡大・縮小・移動しても晴れが地図とズレない」は、描画結果が**地理座標だけで決まる**こと
/// (縮尺や描画範囲の切り方に依存しないこと)と同値なので、それをここで自動検証する。
/// 実機での操作中の見え方(MapKit がタイルを変換して合成する部分)は目視確認の対象。
/// 設計: `design/explore-map/03-detailed-design.md` §8、受け入れ基準 AC-3〜AC-6 / AC-18。
final class FogPainterTests: XCTestCase {

    private let style = FogPainter.Style(fogOpacity: 0.55, revealRadiusMeters: 150,
                                         solidFraction: 0.5, minScreenRadius: 4)

    /// 東京駅付近のセル中心(グリッドに乗った実在しうる値)。
    private var cellCenter: CLLocationCoordinate2D {
        ExplorationGrid.cell(for: .init(latitude: 35.6812, longitude: 139.7671)).center
    }

    // MARK: - オフスクリーン描画ヘルパー

    /// 描画結果。`alpha` は行0が画像の上端(= 北)。
    private struct Rendered {
        let width: Int
        let height: Int
        let mapRect: MKMapRect
        let pixelsPerMapPoint: Double
        let alpha: [UInt8]

        /// 地理座標に対応するピクセルの不透明度(0〜1)。
        func opacity(at coordinate: CLLocationCoordinate2D) -> Double {
            let point = MKMapPoint(coordinate)
            let x = Int(((point.x - mapRect.minX) * pixelsPerMapPoint).rounded(.down))
            let y = Int(((point.y - mapRect.minY) * pixelsPerMapPoint).rounded(.down))
            precondition((0..<width).contains(x) && (0..<height).contains(y), "サンプル点が描画範囲の外")
            return Double(alpha[y * width + x]) / 255
        }
    }

    private func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// `MKOverlayRenderer` が渡す context と同じ「地図ポイント座標系」に CTM を合わせる。
    /// - Parameter contentScale: 1画面ポイントあたりのピクセル数(実機の Retina 相当は 2)。
    private func prepare(_ context: CGContext, mapRect: MKMapRect, zoomScale: Double, contentScale: Double) {
        let scale = zoomScale * contentScale
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -mapRect.minX, y: -mapRect.minY)
    }

    private func render(_ index: FogCellIndex, mapRect: MKMapRect, zoomScale: Double,
                        contentScale: Double = 1) -> Rendered {
        let scale = zoomScale * contentScale
        let width = Int((mapRect.width * scale).rounded())
        let height = Int((mapRect.height * scale).rounded())
        let context = makeContext(width: width, height: height)
        prepare(context, mapRect: mapRect, zoomScale: zoomScale, contentScale: contentScale)
        FogPainter.draw(index: index, mapRect: mapRect, zoomScale: zoomScale, style: style, in: context)

        // ビットマップのメモリは先頭行が画像の上端だが、CG の y は上向き(y=0 が下端)。
        // 地図ポイントの y は南向きに増えるので、CTM を反転しない限り「北」がメモリの末尾行に来る。
        // 行を反転して「行0 = 北端」に揃える。
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = height - 1 - row
            for column in 0..<width {
                alpha[row * width + column] = data[(source * width + column) * 4 + 3]
            }
        }
        return Rendered(width: width, height: height, mapRect: mapRect,
                        pixelsPerMapPoint: scale, alpha: alpha)
    }

    /// `center` を中心に、`pixels` 四方を `metersPerPixel` の縮尺で覆う地図矩形と縮尺。
    private func frame(around center: CLLocationCoordinate2D, pixels: Double,
                       metersPerPixel: Double) -> (rect: MKMapRect, zoomScale: Double) {
        let zoomScale = 1 / (metersPerPixel * MKMapPointsPerMeterAtLatitude(center.latitude))
        let side = pixels / zoomScale
        let origin = MKMapPoint(center)
        return (MKMapRect(x: origin.x - side / 2, y: origin.y - side / 2, width: side, height: side), zoomScale)
    }

    private func offset(_ coordinate: CLLocationCoordinate2D, eastMeters: Double = 0,
                        northMeters: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: coordinate.latitude + northMeters / 111_320,
            longitude: coordinate.longitude + eastMeters / (111_320 * cos(coordinate.latitude * .pi / 180)))
    }

    // MARK: - 晴れの実寸(AC-4)

    func testRevealProfileMatchesRealWorldDistances() {
        let center = cellCenter
        let index = FogCellIndex(coordinates: [center])
        let (rect, zoomScale) = frame(around: center, pixels: 800, metersPerPixel: 1)
        XCTAssertEqual(index.level(forZoomScale: zoomScale), 0, "この縮尺では集約しない")
        let image = render(index, mapRect: rect, zoomScale: zoomScale)

        XCTAssertEqual(image.opacity(at: center), 0, accuracy: 0.02, "セル中心は完全に晴れる")
        XCTAssertEqual(image.opacity(at: offset(center, eastMeters: 50)), 0, accuracy: 0.02, "50m は完全に晴れる")
        XCTAssertEqual(image.opacity(at: offset(center, northMeters: 70)), 0, accuracy: 0.03, "70m は完全に晴れる")
        XCTAssertEqual(image.opacity(at: offset(center, eastMeters: -70)), 0, accuracy: 0.03, "西側 70m も同じ")

        // 75m〜150m は線形に戻る: 110m では (110-75)/75 ≒ 0.47 ぶんフォグが残る。
        let expectedMid = 0.55 * (110.0 - 75.0) / 75.0
        XCTAssertEqual(image.opacity(at: offset(center, eastMeters: 110)), expectedMid, accuracy: 0.04)
        XCTAssertEqual(image.opacity(at: offset(center, northMeters: -110)), expectedMid, accuracy: 0.04)

        XCTAssertEqual(image.opacity(at: offset(center, eastMeters: 160)), 0.55, accuracy: 0.02, "150m の外はフォグ")
        XCTAssertEqual(image.opacity(at: offset(center, northMeters: 160)), 0.55, accuracy: 0.02)
        XCTAssertEqual(image.opacity(at: offset(center, eastMeters: 300)), 0.55, accuracy: 0.02)
    }

    func testEmptyIndexIsUniformFog() {
        let (rect, zoomScale) = frame(around: cellCenter, pixels: 64, metersPerPixel: 5)
        let image = render(.empty, mapRect: rect, zoomScale: zoomScale)
        XCTAssertTrue(image.alpha.allSatisfy { abs(Double($0) / 255 - 0.55) < 0.01 }, "セルが無ければ全面フォグ")
    }

    // MARK: - 縮尺・描画範囲に依存しない(AC-3)

    func testSameGeographicPointLooksTheSameAtDifferentZoomLevels() {
        let center = cellCenter
        let index = FogCellIndex(coordinates: [center])
        let samples = [offset(center), offset(center, eastMeters: 60), offset(center, northMeters: 105),
                       offset(center, eastMeters: -120, northMeters: 40), offset(center, eastMeters: 190)]

        var results: [[Double]] = []
        for metersPerPixel in [0.5, 1.0, 2.0, 4.0] {
            let (rect, zoomScale) = frame(around: center, pixels: 900 / metersPerPixel, metersPerPixel: metersPerPixel)
            XCTAssertEqual(index.level(forZoomScale: zoomScale), 0)
            let image = render(index, mapRect: rect, zoomScale: zoomScale)
            results.append(samples.map { image.opacity(at: $0) })
        }
        for other in results.dropFirst() {
            for (a, b) in zip(results[0], other) {
                XCTAssertEqual(a, b, accuracy: 0.06, "縮尺を変えたら同じ地点の見え方が変わった")
            }
        }
    }

    func testRevealGrowsOnScreenInProportionToZoom() {
        let center = cellCenter
        let index = FogCellIndex(coordinates: [center])

        /// 中心から東へ走査し、フォグの半分の濃さを初めて超えるピクセル距離(= 画面上の晴れの半径)。
        func radiusInPixels(metersPerPixel: Double) -> Double {
            let (rect, zoomScale) = frame(around: center, pixels: 800 / metersPerPixel, metersPerPixel: metersPerPixel)
            let image = render(index, mapRect: rect, zoomScale: zoomScale)
            for meters in stride(from: 0.0, through: 300, by: metersPerPixel) {
                if image.opacity(at: offset(center, eastMeters: meters)) > 0.55 / 2 {
                    return meters / metersPerPixel
                }
            }
            return .infinity
        }

        let zoomedOut = radiusInPixels(metersPerPixel: 2)
        let zoomedIn = radiusInPixels(metersPerPixel: 0.5)
        XCTAssertEqual(zoomedIn / zoomedOut, 4, accuracy: 0.3, "4倍に拡大したら晴れの画面上の半径も4倍")
        // 半分の濃さになるのは 75m + 75m/2 = 112.5m 地点。
        XCTAssertEqual(zoomedOut * 2, 112.5, accuracy: 6)
    }

    func testResultDoesNotDependOnWhereTheDrawnRectStarts() {
        let center = cellCenter
        let index = FogCellIndex(coordinates: [center, offset(center, eastMeters: 300, northMeters: 75)])
        let samples = [offset(center), offset(center, eastMeters: 90), offset(center, eastMeters: 210, northMeters: 60),
                       offset(center, northMeters: -130)]

        let (baseRect, zoomScale) = frame(around: center, pixels: 900, metersPerPixel: 1)
        let base = render(index, mapRect: baseRect, zoomScale: zoomScale)
        // 2つ目のセルは北東にだけある。上下・左右が反転して描かれていないことを絶対位置で確かめる。
        XCTAssertEqual(base.opacity(at: offset(center, eastMeters: 300, northMeters: 75)), 0, accuracy: 0.02)
        XCTAssertEqual(base.opacity(at: offset(center, eastMeters: 300, northMeters: -150)), 0.55, accuracy: 0.02,
                       "南東にはセルが無い")
        XCTAssertEqual(base.opacity(at: offset(center, eastMeters: -300, northMeters: 75)), 0.55, accuracy: 0.02,
                       "北西にはセルが無い")
        // 描画範囲をピクセル境界に揃えたまま、あちこちへずらす(地図をパンした状態に相当)。
        let pixel = 1 / zoomScale
        for (dx, dy) in [(37.0, 0.0), (-120.0, 85.0), (200.0, -150.0)] {
            let shifted = baseRect.offsetBy(dx: dx * pixel, dy: dy * pixel)
            let image = render(index, mapRect: shifted, zoomScale: zoomScale)
            for sample in samples {
                XCTAssertEqual(image.opacity(at: sample), base.opacity(at: sample), accuracy: 0.02,
                               "描画範囲をずらしたら同じ地点の見え方が変わった")
            }
        }
    }

    // MARK: - タイルの継ぎ目(AC-5)

    func testTwoAdjacentTilesMatchOneCombinedDrawing() {
        let center = cellCenter
        // タイル境界(中央の縦線)の両側とその上にセルを置く。
        let index = FogCellIndex(coordinates: [
            center, offset(center, eastMeters: 75), offset(center, eastMeters: -75, northMeters: 75),
            offset(center, eastMeters: 20, northMeters: -150), offset(center, eastMeters: -200, northMeters: -40),
        ])
        let (left, zoomScale) = frame(around: offset(center, eastMeters: -128), pixels: 256, metersPerPixel: 1)
        let right = left.offsetBy(dx: left.width, dy: 0)
        let combined = MKMapRect(x: left.minX, y: left.minY, width: left.width * 2, height: left.height)

        let leftImage = render(index, mapRect: left, zoomScale: zoomScale)
        let rightImage = render(index, mapRect: right, zoomScale: zoomScale)
        let whole = render(index, mapRect: combined, zoomScale: zoomScale)
        XCTAssertEqual(whole.width, leftImage.width + rightImage.width)

        var maxDifference = 0
        for row in 0..<whole.height {
            for column in 0..<whole.width {
                let tileValue = column < leftImage.width
                    ? leftImage.alpha[row * leftImage.width + column]
                    : rightImage.alpha[row * rightImage.width + (column - leftImage.width)]
                maxDifference = max(maxDifference, abs(Int(tileValue) - Int(whole.alpha[row * whole.width + column])))
            }
        }
        XCTAssertLessThanOrEqual(maxDifference, 3, "タイルを分けて描いた結果が、一括で描いた結果と食い違う(継ぎ目が出る)")
    }

    // MARK: - 広域表示でも消えない(AC-6)

    func testRevealStaysVisibleWhenZoomedFarOut() {
        let center = cellCenter
        let index = FogCellIndex(coordinates: [center])
        // 1ピクセル = 1.2km 前後。実寸 150m は 0.1 ピクセルしかない。
        for metersPerPixel in [200.0, 1_200.0, 6_000.0] {
            let (rect, zoomScale) = frame(around: center, pixels: 128, metersPerPixel: metersPerPixel)
            XCTAssertGreaterThan(index.level(forZoomScale: zoomScale), 0, "この縮尺では集約レベルを使う")
            let image = render(index, mapRect: rect, zoomScale: zoomScale)
            XCTAssertLessThan(image.opacity(at: center), 0.35, "\(metersPerPixel)m/px: セル位置の晴れが見えなくなった")
            XCTAssertEqual(image.alpha[0].toOpacity, 0.55, accuracy: 0.02, "遠く離れた隅はフォグのまま")
        }
    }

    func testMinimumScreenRadiusAppliesOnlyWhenRealSizeIsSmaller() {
        let level = FogCellIndex(coordinates: [cellCenter]).levels[0]
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(cellCenter.latitude)
        let real = 150 * pointsPerMeter

        let near = FogPainter.radius(pointsPerMeter: pointsPerMeter, squareSize: level.squareSize,
                                     level: 0, zoomScale: 0.05, style: style)
        XCTAssertEqual(near, real, accuracy: 1e-6, "通常の縮尺では実寸どおり")

        // 下限は「画面上 4pt」。タイルは表示時に最大2倍縮小されうるので、タイル上では余裕係数を掛ける。
        let far = FogPainter.radius(pointsPerMeter: pointsPerMeter, squareSize: 512 * 64,
                                    level: 6, zoomScale: 1e-5, style: style)
        XCTAssertEqual(far, 4 * FogPainter.tileScaleMargin / 1e-5, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(far * 1e-5 / 2, 4 - 1e-9, "タイルが2倍縮小されても画面上 4pt を下回らない")
    }

    // MARK: - 集約レベルの晴れは元の晴れを必ず覆う

    func testAggregatedRevealAlwaysCoversTheOriginalReveal() {
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(cellCenter.latitude)
        for level in 1...FogCellIndex.maxLevel {
            let square = FogCellIndex.baseSquareSize * pow(2, Double(level))
            let halfDiagonal = square * 0.5.squareRoot()
            // 下限が効かない(十分に拡大した)縮尺で比べる。
            let outer = FogPainter.radius(pointsPerMeter: pointsPerMeter, squareSize: square,
                                          level: level, zoomScale: 1, style: style)
            let solid = outer * FogPainter.solidFraction(pointsPerMeter: pointsPerMeter, squareSize: square,
                                                         level: level, style: style)
            // 元のセルは代表点から最大で半対角だけ離れている。その晴れ(完全 75m / 外周 150m)を覆うこと。
            XCTAssertGreaterThanOrEqual(solid, halfDiagonal + 75 * pointsPerMeter, "レベル\(level): 完全に晴れる範囲が欠ける")
            XCTAssertGreaterThanOrEqual(outer, halfDiagonal + 150 * pointsPerMeter, "レベル\(level): 外周が欠ける")
            // 隣の升目(中心間隔 = 一辺)と、完全に晴れる範囲どうしが重なる(経路が途切れない)。
            XCTAssertGreaterThan(solid * 2, square, "レベル\(level): 隣の升目との間にフォグが残る")
        }
        XCTAssertEqual(FogPainter.solidFraction(pointsPerMeter: pointsPerMeter, squareSize: 512, level: 0, style: style),
                       0.5, accuracy: 1e-9, "レベル0は実寸の割合そのまま")
    }

    /// セルをまとめて描く縮尺(集約レベル)でも、各セルの中心から 75m 以内は完全に晴れる
    /// (元の「完全に晴れる範囲」が欠けない)。セルは升目の隅に寄った位置も含めてばらまく。
    func testFullyClearCoreIsNeverLostAtAggregatedZooms() {
        var state: UInt64 = 99
        func random(_ range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + (range.upperBound - range.lowerBound) * Double(state >> 11) / Double(1 << 53)
        }
        let base = cellCenter
        let cells = (0..<25).map { _ in
            ExplorationGrid.cell(for: offset(base, eastMeters: random(-6_000...6_000),
                                             northMeters: random(-6_000...6_000))).center
        }
        let index = FogCellIndex(coordinates: cells)

        for metersPerPixel in [30.0, 45, 70, 110, 180, 300] {
            let (rect, zoomScale) = frame(around: base, pixels: 15_000 / metersPerPixel, metersPerPixel: metersPerPixel)
            XCTAssertGreaterThan(index.level(forZoomScale: zoomScale), 0, "\(metersPerPixel)m/px は集約レベルのはず")
            let image = render(index, mapRect: rect, zoomScale: zoomScale)
            for cell in cells {
                for (east, north) in [(0.0, 0.0), (70.0, 0.0), (-70.0, 0.0), (0.0, 70.0), (0.0, -70.0), (49.0, 49.0)] {
                    XCTAssertEqual(image.opacity(at: offset(cell, eastMeters: east, northMeters: north)), 0,
                                   accuracy: 0.004,
                                   "\(metersPerPixel)m/px: セル中心から (\(east), \(north))m にフォグが残った")
                }
            }
        }
    }

    /// 連続した経路(セルが一列に並ぶ)は、どの縮尺でも途切れずに晴れて見える。
    func testContinuousRouteStaysConnectedAtEveryZoom() {
        let start = cellCenter
        let latStep = ExplorationGrid.latCellDegrees
        // 北へ 6km、セルを1つずつ連ねた直線の経路。
        let route = (0..<80).map {
            ExplorationGrid.cell(for: .init(latitude: start.latitude + Double($0) * latStep,
                                            longitude: start.longitude)).center
        }
        let index = FogCellIndex(coordinates: route)
        let middle = route[40]

        for metersPerPixel in [2.0, 10, 25, 60, 150, 400] {
            let (rect, zoomScale) = frame(around: middle, pixels: 3_000 / metersPerPixel, metersPerPixel: metersPerPixel)
            let image = render(index, mapRect: rect, zoomScale: zoomScale)
            // 経路に沿って(描画範囲に収まる ±1.4km を)細かくサンプルし、フォグが残る箇所がないこと。
            for meters in stride(from: -1_400.0, through: 1_400, by: metersPerPixel) {
                XCTAssertLessThan(image.opacity(at: offset(middle, northMeters: meters)), 0.1,
                                  "\(metersPerPixel)m/px: 経路の途中(\(meters)m)が途切れた")
            }
        }
    }

    // MARK: - 性能(AC-18 / NFR-1)

    /// 50,000 セルを敷き詰めた最悪ケースで、描画単位1枚(256pt 四方・2倍解像度 = 512px 四方)の
    /// 描画時間を計測する。合否の基準は「開発機のシミュレータ・**最適化ありのビルド**で平均 50ms 以内」。
    ///
    /// 描画は Swift のループでマスクを計算するので、最適化なし(Debug)では数十倍遅く、出荷する
    /// ビルドの実態を表さない。Debug では計測値を出すだけで判定しない(スキップ扱い)。判定するには:
    /// `xcodebuild test -configuration Release ENABLE_TESTABILITY=YES -only-testing:TekulogTests/FogPainterTests`
    func testDrawingOneTileWithFiftyThousandCellsStaysWithinBudget() throws {
        let center = cellCenter
        let index = FogCellIndex(coordinates: ExplorationGrid.denseBlock(around: center, count: 50_000))
        XCTAssertEqual(index.cellCount, 50_000)
        let origin = MKMapPoint(center)
        let iterations = 8

        var report: [String] = []
        var worst = 0.0
        for level in 0...5 {
            // そのレベルで1タイルに最も多くの点が入る縮尺(レベルが切り替わる直前)。
            let zoomScale = FogCellIndex.minSquareScreenPoints / index.levels[level].squareSize
            let side = 256 / zoomScale
            let rect = MKMapRect(x: origin.x - side / 2, y: origin.y - side / 2, width: side, height: side)

            var total = 0.0
            for _ in 0..<iterations {
                let context = makeContext(width: 512, height: 512)
                prepare(context, mapRect: rect, zoomScale: zoomScale, contentScale: 2)
                let start = CFAbsoluteTimeGetCurrent()
                FogPainter.draw(index: index, mapRect: rect, zoomScale: zoomScale, style: style, in: context)
                total += CFAbsoluteTimeGetCurrent() - start
            }
            let average = total / Double(iterations)
            worst = max(worst, average)
            report.append(String(format: "L%d %.1fms", level, average * 1000))
        }
        print("FogPainter 50,000セル 1タイル平均: \(report.joined(separator: " / "))")
        #if DEBUG
        throw XCTSkip("最適化なしのビルドでは判定しない(計測値: \(report.joined(separator: " / ")))")
        #else
        XCTAssertLessThan(worst, 0.050, "1タイルの描画が平均 50ms を超えた: \(report)")
        #endif
    }
}

private extension UInt8 {
    var toOpacity: Double { Double(self) / 255 }
}
