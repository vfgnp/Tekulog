import MapKit
import CoreGraphics

/// 探索マップのフォグ描画用に、全開拓済みセルを地図座標(`MKMapPoint`)で引ける不変の索引。
///
/// 描画(`FogOverlayRenderer.draw`)は MapKit のバックグラウンドスレッドから複数同時に呼ばれ、
/// そこから Core Data は引けない。そのため表示前に全セルを一度メモリへ読み、この値型に
/// 固めて渡す(構築後は変更しないので `Sendable`)。表示範囲ごとの再取得は行わない。
///
/// **LOD(詳細度レベル)**: 地図を縮小すると 75m セルは1ピクセル未満になり、1タイルに
/// 数万セルが入る。レベル k(≥1)は地図座標を `baseSquareSize * 2^k` の升目に区切り、
/// セルを含む升目ごとに1点(升目の中心)へ集約したもの。縮尺に応じて「升目が画面上
/// `minSquareScreenPoints` 以上になる最も細かいレベル」を使うので、1タイル(256pt 四方)の
/// 点数は最大でも (256/4)² = 4,096 に収まる。レベル0はセル中心そのもの(集約なし)。
struct FogCellIndex: Sendable {
    /// 地図座標上の1点。`pointsPerMeter` はその緯度での「地図ポイント/メートル」
    /// (描画時に三角関数を引かないよう、構築時に持っておく)。
    struct Point: Sendable {
        let x: Double
        let y: Double
        let pointsPerMeter: Double
    }

    struct Level: Sendable {
        /// 升目の一辺(地図ポイント)。レベル0も `baseSquareSize` として扱う。
        let squareSize: Double
        /// 空間ハッシュのバケット一辺(地図ポイント)。
        let bucketSize: Double
        let buckets: [Int64: [Point]]
        /// 全点の `pointsPerMeter` の最大(最も北の点)。晴れの半径の上限を見積もるのに使う。
        let maxPointsPerMeter: Double
        let pointCount: Int
    }

    /// 地図ポイント。セル 75m は日本付近で約 560〜690 ポイントなので、それより少し小さい値。
    static let baseSquareSize = 512.0
    static let maxLevel = 12
    static let minSquareScreenPoints = 4.0
    /// バケット1辺あたりの升目数。
    private static let squaresPerBucket = 32.0
    /// 交差バケット数がこれを超える矩形は、辞書全体の走査に切り替える(極端な入力への保険)。
    private static let maxBucketProbes = 4096

    static let empty = FogCellIndex(coordinates: [])

    let levels: [Level]

    var cellCount: Int { levels[0].pointCount }

    init(coordinates: [CLLocationCoordinate2D]) {
        var base: [Point] = []
        base.reserveCapacity(coordinates.count)
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            let mapPoint = MKMapPoint(coordinate)
            base.append(Point(x: mapPoint.x, y: mapPoint.y,
                              pointsPerMeter: MKMapPointsPerMeterAtLatitude(coordinate.latitude)))
        }

        var built: [Level] = [Self.makeLevel(points: base, squareSize: Self.baseSquareSize)]
        // 升目は入れ子(レベル k の升目は k+1 の升目1つに収まる)なので、1つ下のレベルから集約できる。
        var previous = base
        for k in 1...Self.maxLevel {
            let size = Self.baseSquareSize * pow(2, Double(k))
            var seen = Set<Int64>()
            var aggregated: [Point] = []
            for point in previous {
                let ix = (point.x / size).rounded(.down)
                let iy = (point.y / size).rounded(.down)
                guard seen.insert(Self.key(ix: ix, iy: iy)).inserted else { continue }
                let center = MKMapPoint(x: (ix + 0.5) * size, y: (iy + 0.5) * size)
                aggregated.append(Point(x: center.x, y: center.y,
                                        pointsPerMeter: MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)))
            }
            built.append(Self.makeLevel(points: aggregated, squareSize: size))
            previous = aggregated
        }
        levels = built
    }

    /// 縮尺(`MKZoomScale` = 画面ポイント / 地図ポイント)に対して使うレベル。
    func level(forZoomScale zoomScale: Double) -> Int {
        guard zoomScale > 0, zoomScale.isFinite else { return Self.maxLevel }
        for k in 0...Self.maxLevel where levels[k].squareSize * zoomScale >= Self.minSquareScreenPoints {
            return k
        }
        return Self.maxLevel
    }

    /// `rect` に交差するバケット内の全点を列挙する(`rect` の外の点も含みうる。
    /// 円と矩形の交差判定は呼び出し側で行う)。`rect` 内の点は必ず列挙される。
    func forEachPoint(in rect: MKMapRect, level: Int, _ body: (Point) -> Void) {
        let target = levels[level]
        guard target.pointCount > 0, !rect.isNull,
              rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return }

        let minX = (rect.minX / target.bucketSize).rounded(.down)
        let maxX = (rect.maxX / target.bucketSize).rounded(.down)
        let minY = (rect.minY / target.bucketSize).rounded(.down)
        let maxY = (rect.maxY / target.bucketSize).rounded(.down)
        let probes = (maxX - minX + 1) * (maxY - minY + 1)

        if probes > Double(Self.maxBucketProbes) {
            for points in target.buckets.values {
                for point in points where point.x >= rect.minX && point.x <= rect.maxX
                    && point.y >= rect.minY && point.y <= rect.maxY {
                    body(point)
                }
            }
            return
        }

        var iy = minY
        while iy <= maxY {
            var ix = minX
            while ix <= maxX {
                if let points = target.buckets[Self.key(ix: ix, iy: iy)] {
                    points.forEach(body)
                }
                ix += 1
            }
            iy += 1
        }
    }

    // MARK: - 構築ヘルパー

    private static func makeLevel(points: [Point], squareSize: Double) -> Level {
        let bucketSize = squareSize * squaresPerBucket
        var buckets: [Int64: [Point]] = [:]
        var maxPointsPerMeter = 0.0
        for point in points {
            let ix = (point.x / bucketSize).rounded(.down)
            let iy = (point.y / bucketSize).rounded(.down)
            buckets[key(ix: ix, iy: iy), default: []].append(point)
            maxPointsPerMeter = max(maxPointsPerMeter, point.pointsPerMeter)
        }
        return Level(squareSize: squareSize, bucketSize: bucketSize, buckets: buckets,
                     maxPointsPerMeter: maxPointsPerMeter, pointCount: points.count)
    }

    /// 升目/バケットの整数座標(Double で受ける)を1つのキーへ詰める。
    /// 地図座標は世界全体で 0〜約2.7億なので、どのレベルでも Int32 に収まる。
    private static func key(ix: Double, iy: Double) -> Int64 {
        (Int64(iy) << 32) | Int64(UInt32(truncatingIfNeeded: Int64(ix)))
    }
}

/// フォグの描画本体。「索引・地図矩形・縮尺」だけから決まる純関数で、UIKit/MapKit のビューに
/// 依存しない(オフスクリーンの `CGContext` に描いて単体テストできる)。
///
/// 晴れの位置と大きさは地図座標で決まるので、どのタイルに・どの縮尺で描いても同じ地点は
/// 同じ結果になる(= 地図を動かしても拡大縮小してもズレない)。
///
/// **描き方**: フォグの濃さを自前の粗い格子(マスク)で計算し、1枚の画像にして1回で貼る。
/// 「全面をフォグで塗り、セルごとに放射グラデーションを `destinationOut` で描いて抜く」方式は
/// 結果は同じだが、Core Graphics の1回の描画ごとの準備コストが大きく、1タイルに数千セルが
/// 入る縮尺で 100〜170ms かかった(実測。グラデーションを画像にして貼る方式でも同程度)。
/// マスクの格子は地図座標に固定(タイルの切り方に依らない)なので、隣り合うタイルの継ぎ目で
/// 値が食い違わない。
enum FogPainter {
    struct Style: Sendable {
        /// フォグ(黒)の不透明度。
        var fogOpacity: Double
        /// 1セルが晴らす範囲の外周の実寸半径(m)。
        var revealRadiusMeters: Double
        /// 半径のうち完全に晴れる内側の割合。残りは外周に向かって線形にフォグへ戻る。
        var solidFraction: Double
        /// 晴れの画面上の最小半径(pt)。広域表示で晴れが消えないようにする。
        var minScreenRadius: Double

        static var standard: Style {
            Style(fogOpacity: Tunables.explorationFogOpacity,
                  revealRadiusMeters: Tunables.explorationRevealRadiusMeters,
                  solidFraction: Tunables.explorationRevealSolidFraction,
                  minScreenRadius: Tunables.explorationMinRevealScreenRadius)
        }
    }

    /// MapKit はオーバーレイを2の累乗の段階的な縮尺(`draw` に渡る `zoomScale`)でタイルに描き、
    /// 実際の表示縮尺に合わせて拡大・縮小して表示する。タイルが表示時に縮小されても画面上の
    /// 最小半径(`Style.minScreenRadius`)を下回らないよう、タイル上ではこの係数を掛けた大きさで描く。
    static let tileScaleMargin = 2.0

    /// 集約レベルで半径に足す量(地図ポイント)。升目の中心に置いた代表点から、升目内の
    /// 元のセルは最大で半対角(一辺の 0.707 倍)離れている。完全に晴れる半径・外周の両方に
    /// これを足すので、集約後の晴れは元の晴れを必ず覆い、隣の升目の晴れとも必ず重なる
    /// (歩いた場所がフォグに戻って見えたり、経路が点線状に途切れたりしない)。レベル0は 0。
    static func padding(level: Int, squareSize: Double) -> Double {
        level > 0 ? squareSize * 0.7072 : 0
    }

    /// 1点が晴らす外周の半径(地図ポイント)。
    static func radius(pointsPerMeter: Double, squareSize: Double, level: Int,
                       zoomScale: Double, style: Style) -> Double {
        max(padding(level: level, squareSize: squareSize) + style.revealRadiusMeters * pointsPerMeter,
            style.minScreenRadius * tileScaleMargin / zoomScale)
    }

    /// 外周の半径のうち完全に晴れる内側の割合。レベル0では `style.solidFraction` そのもの、
    /// 集約レベルでは `padding` のぶんだけ内側が広がる(ぼかしの幅は実寸のまま)。
    static func solidFraction(pointsPerMeter: Double, squareSize: Double, level: Int, style: Style) -> Double {
        let pad = padding(level: level, squareSize: squareSize)
        let outer = pad + style.revealRadiusMeters * pointsPerMeter
        guard outer > 0 else { return style.solidFraction }
        return (pad + style.revealRadiusMeters * style.solidFraction * pointsPerMeter) / outer
    }

    /// `mapRect` の範囲のフォグを描く。
    /// - Parameter context: 「地図ポイント座標系(原点 = 世界原点)」に変換済みであること
    ///   (`MKOverlayRenderer` が世界全体を覆うオーバーレイに渡す context はこの状態)。
    static func draw(index: FogCellIndex, mapRect: MKMapRect, zoomScale: Double,
                     style: Style, in context: CGContext) {
        guard zoomScale > 0, zoomScale.isFinite, !mapRect.isNull,
              mapRect.width > 0, mapRect.height > 0 else { return }
        let transform = context.ctm
        let pixelsPerMapPoint = Double(hypot(transform.a, transform.b))
        guard pixelsPerMapPoint > 0, pixelsPerMapPoint.isFinite else { return }

        context.saveGState()
        defer { context.restoreGState() }
        // 世界座標(最大約2.7億)をそのまま描画 API に渡さず、タイル原点からの相対座標で描く。
        context.translateBy(x: mapRect.minX, y: mapRect.minY)
        let localRect = CGRect(x: 0, y: 0, width: mapRect.width, height: mapRect.height)
        context.clip(to: localRect)

        let levelIndex = index.level(forZoomScale: zoomScale)
        let level = index.levels[levelIndex]
        guard level.pointCount > 0 else {
            fillFog(localRect, style: style, in: context)
            return
        }

        // このタイルで最大の晴れ(最も北の点)の大きさから、マスクの粗さを決める。
        let maxRadius = radius(pointsPerMeter: level.maxPointsPerMeter, squareSize: level.squareSize,
                               level: levelIndex, zoomScale: zoomScale, style: style)
        let maxFade = maxRadius * (1 - solidFraction(pointsPerMeter: level.maxPointsPerMeter,
                                                     squareSize: level.squareSize, level: levelIndex, style: style))
        let step = maskStep(radiusPixels: maxRadius * pixelsPerMapPoint,
                            fadePixels: maxFade * pixelsPerMapPoint, level: levelIndex) / pixelsPerMapPoint
        // 集約レベルで格子を粗くするときは、格子の対角ぶん晴れを広げる。線形補間は、ある点を囲む
        // 4つの格子点すべての値を使う。その点が完全に晴れるには4点とも 0 でなければならず、
        // 最も遠い格子点は対角いっぱい(1.414 格子)離れている。対角ぶん広げておけば、本来完全に
        // 晴れる範囲にフォグが残らない(「元の晴れを必ず覆う」を保つ)。
        // レベル0は実寸の正確さを優先して広げない。
        let inflate = levelIndex > 0 && step * pixelsPerMapPoint > 1 ? step * 1.42 : 0

        // 格子は地図座標に固定: 第 k 列の中心は x = (k + 0.5) * step。タイルの外側にも余白を取る
        // (補間が隣の格子点を参照するため)。
        let margin = 2
        let firstColumn = Int((mapRect.minX / step).rounded(.down)) - margin
        let firstRow = Int((mapRect.minY / step).rounded(.down)) - margin
        let width = Int((mapRect.maxX / step).rounded(.up)) + margin - firstColumn
        let height = Int((mapRect.maxY / step).rounded(.up)) + margin - firstRow
        guard width > 0, height > 0, width * height <= maxMaskSamples else {
            fillFog(localRect, style: style, in: context)
            return
        }

        // 各格子点の「フォグが残る割合」(1 = フォグのまま、0 = 完全に晴れ)。
        // 重なる晴れは掛け算でつながる(destinationOut で重ね描きしたのと同じ結果)。
        var remaining = [Float](repeating: 1, count: width * height)
        var touched = false
        let reach = maxRadius + inflate + step
        remaining.withUnsafeMutableBufferPointer { buffer in
            index.forEachPoint(in: mapRect.insetBy(dx: -reach, dy: -reach), level: levelIndex) { point in
                let base = radius(pointsPerMeter: point.pointsPerMeter, squareSize: level.squareSize,
                                  level: levelIndex, zoomScale: zoomScale, style: style)
                let fraction = solidFraction(pointsPerMeter: point.pointsPerMeter, squareSize: level.squareSize,
                                             level: levelIndex, style: style)
                // 格子の単位に直す。
                let outer = (base + inflate) / step
                let solid = (base * fraction + inflate) / step
                let centerX = point.x / step - Double(firstColumn) - 0.5
                let centerY = point.y / step - Double(firstRow) - 0.5
                let minColumn = max(0, Int((centerX - outer).rounded(.up)))
                let maxColumn = min(width - 1, Int((centerX + outer).rounded(.down)))
                let minRow = max(0, Int((centerY - outer).rounded(.up)))
                let maxRow = min(height - 1, Int((centerY + outer).rounded(.down)))
                guard minColumn <= maxColumn, minRow <= maxRow else { return }
                touched = true

                let outerSquared = outer * outer
                let solidSquared = solid * solid
                let fade = max(outer - solid, 1e-9)
                for row in minRow...maxRow {
                    let dy = Double(row) - centerY
                    let rowStart = row * width
                    for column in minColumn...maxColumn {
                        let dx = Double(column) - centerX
                        let distanceSquared = dx * dx + dy * dy
                        if distanceSquared >= outerSquared { continue }
                        if distanceSquared <= solidSquared {
                            buffer[rowStart + column] = 0
                        } else {
                            buffer[rowStart + column] *= Float((distanceSquared.squareRoot() - solid) / fade)
                        }
                    }
                }
            }
        }
        guard touched else {
            fillFog(localRect, style: style, in: context)
            return
        }

        // マスクを画像にする(黒・premultiplied なので色成分は 0、アルファだけを持つ)。
        // `draw(_:in:)` は画像の先頭行を矩形の maxY 側(地図では南)に描くので、行を南から順に詰める。
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let opacity = Float(style.fogOpacity) * 255
        for row in 0..<height {
            let source = (height - 1 - row) * width
            let destination = row * width * 4
            for column in 0..<width {
                pixels[destination + column * 4 + 3] = UInt8((remaining[source + column] * opacity).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            fillFog(localRect, style: style, in: context)
            return
        }
        context.interpolationQuality = .low   // 格子点の間は線形に補間する
        context.draw(image, in: CGRect(x: Double(firstColumn) * step - mapRect.minX,
                                       y: Double(firstRow) * step - mapRect.minY,
                                       width: Double(width) * step, height: Double(height) * step))
    }

    /// マスクの格子点数の上限(想定外に大きい描画要求で巨大な配列を確保しないための保険。
    /// MapKit のタイルは 256pt 四方 × 解像度3倍でも 60 万点に満たない)。
    private static let maxMaskSamples = 4_000_000

    /// マスク1格子の一辺(ピクセル)。晴れの縁のぼかしに格子が3つ以上入る粗さにする。
    /// 集約レベルは縁のぼかしがほとんど無い(数ピクセル未満)ので、晴れの大きさを基準にする。
    private static func maskStep(radiusPixels: Double, fadePixels: Double, level: Int) -> Double {
        let byFade = fadePixels / 3
        let byRadius = level > 0 ? radiusPixels / 5 : 0
        return min(max(max(byFade, byRadius).rounded(.down), 1), 6)
    }

    private static func fillFog(_ rect: CGRect, style: Style, in context: CGContext) {
        context.setFillColor(CGColor(gray: 0, alpha: style.fogOpacity))
        context.fill(rect)
    }
}
