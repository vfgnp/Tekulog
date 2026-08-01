import CoreData
import CoreLocation

/// 探索グリッド(`ExploredCell`)の読み書きを一手に引き受けるサービス。
///
/// **単一 context で直列化する設計が肝**: ライブ確定(`SessionCoordinator.finalize`)と
/// 起動時バックフィル(`ExplorationBackfillService`)の両方が同じセルを同時に upsert しうる。
/// `WalkRepository` のようにメソッドごとに `newBackgroundContext()` を作ると、
/// 2つの独立した context が同じセルを「未存在」と誤認して二重挿入し、
/// 「新規開拓セル数」の二重カウントや一意制約違反を起こす。そのため保持する `context` は
/// init 時に一度だけ生成し、以後すべての読み書きをこの1つの context の `perform`
/// (同一 context に対しては FIFO で直列化される)経由でのみ行う。
/// この理由から、`SessionCoordinator` が1つの `ExplorationService` インスタンスを所有し、
/// バックフィル側にも同じインスタンスを注入すること(それぞれが独自に生成しないこと)。
///
/// `@unchecked Sendable`: 保持する `context` へのアクセスは常に `context.perform` 上で
/// 完結するためスレッド安全。
final class ExplorationService: @unchecked Sendable {
    private let context: NSManagedObjectContext

    init(persistence: PersistenceController = .shared) {
        context = persistence.newBackgroundContext()
    }

    /// 緯度経度から、東西方向の歪み(緯度による経度1度あたりの距離差)を補正した
    /// グリッドセル識別子を求める。自宅位置に依存しないので、自宅を変更してもズレない。
    /// `internal`(テストから直接検証するため。`TekulogTests` 参照)。
    func bucket(for coordinate: CLLocationCoordinate2D) -> (lat: Int32, lon: Int32, centerLat: Double, centerLon: Double) {
        let metersPerDegreeLat = 111_320.0
        let latCellDeg = Tunables.explorationCellSizeMeters / metersPerDegreeLat
        let lonCellDeg = Tunables.explorationCellSizeMeters
            / (metersPerDegreeLat * max(cos(coordinate.latitude * .pi / 180), 0.01))
        let latBucket = Int32((coordinate.latitude / latCellDeg).rounded(.down))
        let lonBucket = Int32((coordinate.longitude / lonCellDeg).rounded(.down))
        let centerLat = (Double(latBucket) + 0.5) * latCellDeg
        let centerLon = (Double(lonBucket) + 0.5) * lonCellDeg
        return (latBucket, lonBucket, centerLat, centerLon)
    }

    /// 連続する点の間隔がセルサイズより大きい場合に中間点を補間する。
    /// GPS の間引き(distanceFilter)や自転車の速い移動でセルを飛び越え、
    /// フォグマップに実際には通った穴が空いたままになるのを防ぐ。
    func densify(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        let step = Tunables.explorationCellSizeMeters * 0.6
        var result: [CLLocationCoordinate2D] = [coordinates[0]]
        for i in 1..<coordinates.count {
            let a = coordinates[i - 1]
            let b = coordinates[i]
            let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            if distance > step {
                let segments = max(1, Int(distance / step))
                for s in 1..<segments {
                    let t = Double(s) / Double(segments)
                    result.append(CLLocationCoordinate2D(
                        latitude: a.latitude + (b.latitude - a.latitude) * t,
                        longitude: a.longitude + (b.longitude - a.longitude) * t))
                }
            }
            result.append(b)
        }
        return result
    }

    /// ルート座標列(時系列順)を探索グリッドへ反映する。
    /// - Returns: このセッションで新規に開拓されたセル数。
    @discardableResult
    func recordVisited(coordinates: [CLLocationCoordinate2D], firstSeenAt: Date) async throws -> Int {
        guard !coordinates.isEmpty else { return 0 }
        let densified = densify(coordinates)
        let buckets = densified.map(bucket(for:))
        return try await context.perform { [context] in
            var newCount = 0
            var handled = Set<Int64>()
            for bucket in buckets {
                // Int32 のペアを1つの Int64 キーへ詰めて、セッション内の重複 upsert を避ける。
                let key = (Int64(bucket.lat) << 32) | Int64(UInt32(bitPattern: bucket.lon))
                guard !handled.contains(key) else { continue }
                handled.insert(key)

                let request = ExploredCell.fetchRequest()
                request.predicate = NSPredicate(format: "latBucket == %d AND lonBucket == %d", bucket.lat, bucket.lon)
                request.fetchLimit = 1
                if try context.fetch(request).first == nil {
                    let cell = ExploredCell(context: context)
                    cell.latBucket = bucket.lat
                    cell.lonBucket = bucket.lon
                    cell.centerLatitude = bucket.centerLat
                    cell.centerLongitude = bucket.centerLon
                    cell.firstSeenAt = firstSeenAt
                    newCount += 1
                }
            }
            if newCount > 0 {
                try context.save()
            }
            return newCount
        }
    }

    /// 指定した矩形範囲(bounding box)内の探索済みセル中心座標を返す。
    /// フォグ描画・フロンティア判定の両方がこれを使う。
    func fetchCells(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) async throws -> [CLLocationCoordinate2D] {
        try await context.perform { [context] in
            let request = ExploredCell.fetchRequest()
            request.predicate = NSPredicate(
                format: "centerLatitude >= %f AND centerLatitude <= %f AND centerLongitude >= %f AND centerLongitude <= %f",
                minLat, maxLat, minLon, maxLon)
            return try context.fetch(request).map {
                CLLocationCoordinate2D(latitude: $0.centerLatitude, longitude: $0.centerLongitude)
            }
        }
    }

    /// 開拓済みセルの総数(自宅まわりの開拓率の分母/分子計算などに使う)。
    func totalExploredCellCount() async throws -> Int {
        try await context.perform { [context] in
            try context.count(for: ExploredCell.fetchRequest())
        }
    }

    /// 自宅から `radiusMeters` 以内の開拓率(0〜1)。
    func explorationRate(home: CLLocationCoordinate2D, radiusMeters: Double) async throws -> Double {
        let box = boundingBox(center: home, radiusMeters: radiusMeters)
        let cells = try await fetchCells(minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon)
        let exploredInRadius = cells.filter { distanceMeters($0, home) <= radiusMeters }.count
        let cellArea = Tunables.explorationCellSizeMeters * Tunables.explorationCellSizeMeters
        let totalCells = max(1, Int((Double.pi * radiusMeters * radiusMeters) / cellArea))
        return min(1, Double(exploredInRadius) / Double(totalCells))
    }

    /// 自宅を中心に `Tunables.explorationFrontierDirectionCount` 方位へレイキャストし、
    /// 各方位で最初に見つかった未開拓地点を返す(未開拓の方位がなければその方位は含まない)。
    func findFrontierCandidates(home: CLLocationCoordinate2D)
        async throws -> [(coordinate: CLLocationCoordinate2D, bearingDegrees: Double, distanceMeters: Double)] {
        let radius = Tunables.explorationFrontierMaxRadiusMeters
        let box = boundingBox(center: home, radiusMeters: radius)
        let explored = try await fetchCells(minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon)
        let exploredBuckets = Set(explored.map(bucketKey(for:)))

        var candidates: [(coordinate: CLLocationCoordinate2D, bearingDegrees: Double, distanceMeters: Double)] = []
        let directionCount = Tunables.explorationFrontierDirectionCount
        for i in 0..<directionCount {
            let bearing = Double(i) * (360.0 / Double(directionCount))
            var step = Tunables.explorationFrontierStepMeters
            while step <= radius {
                let point = offset(from: home, distanceMeters: step, bearingDegrees: bearing)
                if !exploredBuckets.contains(bucketKey(for: point)) {
                    candidates.append((point, bearing, step))
                    break
                }
                step += Tunables.explorationFrontierStepMeters
            }
        }
        return candidates
    }

    // MARK: - 地理計算ヘルパー

    func bucketKey(for coordinate: CLLocationCoordinate2D) -> Int64 {
        let b = bucket(for: coordinate)
        return (Int64(b.lat) << 32) | Int64(UInt32(bitPattern: b.lon))
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    func boundingBox(center: CLLocationCoordinate2D, radiusMeters: Double)
        -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * max(cos(center.latitude * .pi / 180), 0.01))
        return (center.latitude - latDelta, center.latitude + latDelta,
                center.longitude - lonDelta, center.longitude + lonDelta)
    }

    /// 大圏distance公式で、中心から指定した距離・方位(0°=北, 時計回り)の地点を求める。
    /// `internal`(テストから直接検証するため)。
    func offset(from center: CLLocationCoordinate2D, distanceMeters: Double, bearingDegrees: Double)
        -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let bearingRad = bearingDegrees * .pi / 180
        let angularDistance = distanceMeters / earthRadius
        let lat1 = center.latitude * .pi / 180
        let lon1 = center.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angularDistance) + cos(lat1) * sin(angularDistance) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(angularDistance) * cos(lat1),
                                cos(angularDistance) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}
