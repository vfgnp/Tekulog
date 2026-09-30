import CoreLocation

/// 探索グリッドの定義(座標 → セル)。ここが唯一の実装で、入力は座標だけ
/// (自宅位置に依存しないので、自宅を変更しても開拓済みデータはズレない)。
///
/// **緯度行ごとに経度セル幅を固定するのが肝**: まず緯度でバケット(行)を決め、経度セル幅は
/// その「行の中心緯度」だけから求める。点そのものの緯度で経度幅を決めると(旧実装)、
/// 同じ行の中でも南端と北端で経度の境界が約1.4セルずれ、セルが斜めの帯に歪む・セル中心が
/// 一意に決まらない・中心を再変換すると約3割が別セルになる、という不具合になる
/// (`design/explore-map/01-requirements.md` の原因 E)。
enum ExplorationGrid {
    struct Cell: Hashable, Sendable {
        let latBucket: Int32
        let lonBucket: Int32

        /// Int32 のペアを1つの Int64 へ詰めたキー(集合・辞書用)。
        var key: Int64 { ExplorationGrid.key(latBucket: latBucket, lonBucket: lonBucket) }
        /// セル中心。セル番号だけで決まるので、どの点から入っても同じ値になる。
        var center: CLLocationCoordinate2D { ExplorationGrid.center(latBucket: latBucket, lonBucket: lonBucket) }
    }

    static let metersPerDegreeLatitude = 111_320.0

    /// 緯度方向のセル幅(度)。全世界で一定。
    static var latCellDegrees: Double {
        Tunables.explorationCellSizeMeters / metersPerDegreeLatitude
    }

    /// 経度方向のセル幅(度)。行(`latBucket`)の中心緯度だけで決まる。
    static func lonCellDegrees(latBucket: Int32) -> Double {
        let rowCenterLatitude = (Double(latBucket) + 0.5) * latCellDegrees
        // 極域でのゼロ除算防止(利用範囲外だがクラッシュさせない)。
        let cosine = max(cos(rowCenterLatitude * .pi / 180), 0.01)
        return Tunables.explorationCellSizeMeters / (metersPerDegreeLatitude * cosine)
    }

    static func latBucket(latitude: Double) -> Int32 {
        Int32((latitude / latCellDegrees).rounded(.down))
    }

    /// 指定した行における、経度のバケット番号。
    static func lonBucket(longitude: Double, latBucket: Int32) -> Int32 {
        Int32((longitude / lonCellDegrees(latBucket: latBucket)).rounded(.down))
    }

    static func cell(for coordinate: CLLocationCoordinate2D) -> Cell {
        let lat = latBucket(latitude: coordinate.latitude)
        return Cell(latBucket: lat, lonBucket: lonBucket(longitude: coordinate.longitude, latBucket: lat))
    }

    static func center(latBucket: Int32, lonBucket: Int32) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (Double(latBucket) + 0.5) * latCellDegrees,
            longitude: (Double(lonBucket) + 0.5) * lonCellDegrees(latBucket: latBucket))
    }

    static func key(latBucket: Int32, lonBucket: Int32) -> Int64 {
        (Int64(latBucket) << 32) | Int64(UInt32(bitPattern: lonBucket))
    }

    /// 性能確認用: `center` の周囲に `count` 個のセル中心を正方形に敷き詰めて返す
    /// (最も描画負荷の高い「一帯がすべて開拓済み」の状態)。単体テストと、DEBUG の
    /// `-demoFogCells N` が使う(性能テストは最適化ありのビルドでも走らせるので DEBUG 限定にしない)。
    static func denseBlock(around center: CLLocationCoordinate2D, count: Int) -> [CLLocationCoordinate2D] {
        guard count > 0 else { return [] }
        let side = Int(Double(count).squareRoot().rounded(.up))
        let origin = cell(for: center)
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(count)
        outer: for row in 0..<side {
            let lat = origin.latBucket + Int32(row - side / 2)
            let lonOrigin = lonBucket(longitude: center.longitude, latBucket: lat)
            for column in 0..<side {
                result.append(self.center(latBucket: lat, lonBucket: lonOrigin + Int32(column - side / 2)))
                if result.count == count { break outer }
            }
        }
        return result
    }
}
