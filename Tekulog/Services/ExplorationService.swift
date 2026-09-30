import Combine
import CoreData
import CoreLocation
import os

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
/// セル番号の計算(座標 → セル)は `ExplorationGrid` が唯一の実装で、ここでは行わない。
///
/// `@unchecked Sendable`: 保持する `context` へのアクセスは常に `context.perform` 上で
/// 完結するためスレッド安全。`outingGate` は自身がロックで保護し、`rebuildState`
/// (`CurrentValueSubject`)は `send` / `value` がスレッド安全。
final class ExplorationService: @unchecked Sendable {
    private let context: NSManagedObjectContext

    /// **外出単位の排他**。「グリッド再構築の全体」と「外出1件の確定後処理(経路取得→分類→
    /// セル反映→新エリア数保存)」をこのゲートで直列化する。再構築の途中(セルが一部しか
    /// 戻っていない状態)で外出が確定しても、その外出は再構築が終わってから処理されるので、
    /// 新エリア数が「古い順に1回ずつ反映した結果」と一致する。
    /// ゲートは再入不可: 保持中の処理は `recordVisited` などをそのまま呼ぶ(二重に取らない)。
    /// 取得・解放は `OutingPostProcessor` と `ExplorationBackfillService` だけが行う。
    let outingGate = AsyncGate()

    /// グリッド再構築の実行中か。`CurrentValueSubject` は購読した時点で現在値を流すので、
    /// 探索マップは「フラグを読む」と「変更通知を購読する」を別々に行わずに済む
    /// (別々だと、その間に完了した場合に「更新中」表示が残る)。
    let rebuildState = CurrentValueSubject<Bool, Never>(false)

    init(persistence: PersistenceController = .shared) {
        context = persistence.newBackgroundContext()
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
        let valid = coordinates.filter(CLLocationCoordinate2DIsValid)
        guard !valid.isEmpty else { return 0 }

        // 経路が通るセル(重複なし・初出順)。
        var seen = Set<Int64>()
        var cells: [ExplorationGrid.Cell] = []
        for coordinate in densify(valid) {
            let cell = ExplorationGrid.cell(for: coordinate)
            if seen.insert(cell.key).inserted { cells.append(cell) }
        }
        guard let first = cells.first else { return 0 }
        var minLat = first.latBucket, maxLat = first.latBucket
        var minLon = first.lonBucket, maxLon = first.lonBucket
        for cell in cells {
            minLat = min(minLat, cell.latBucket); maxLat = max(maxLat, cell.latBucket)
            minLon = min(minLon, cell.lonBucket); maxLon = max(maxLon, cell.lonBucket)
        }

        return try await context.perform { [context] in
            // 既存セルの確認は、経路の外接範囲を1回 fetch して済ませる(セルごとに fetch すると、
            // 全セッションを再生するグリッド再構築で「セッション数 × セル数」の往復になる)。
            let request = NSFetchRequest<NSDictionary>(entityName: "ExploredCell")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["latBucket", "lonBucket"]
            request.predicate = NSPredicate(
                format: "latBucket >= %d AND latBucket <= %d AND lonBucket >= %d AND lonBucket <= %d",
                minLat, maxLat, minLon, maxLon)
            var existing = Set<Int64>()
            for row in try context.fetch(request) {
                guard let lat = (row["latBucket"] as? NSNumber)?.int32Value,
                      let lon = (row["lonBucket"] as? NSNumber)?.int32Value else { continue }
                existing.insert(ExplorationGrid.key(latBucket: lat, lonBucket: lon))
            }

            var newCount = 0
            for cell in cells where !existing.contains(cell.key) {
                let center = cell.center
                let row = ExploredCell(context: context)
                row.latBucket = cell.latBucket
                row.lonBucket = cell.lonBucket
                row.centerLatitude = center.latitude
                row.centerLongitude = center.longitude
                row.firstSeenAt = firstSeenAt
                newCount += 1
            }
            if newCount > 0 {
                try context.save()
            }
            return newCount
        }
    }

    /// 開拓済みの全セルの中心座標を返す。探索マップのフォグ描画は表示範囲に依らず全件を
    /// メモリに持つ(`FogCellIndex`)ので、その入力になる。
    func fetchAllCells() async throws -> [CLLocationCoordinate2D] {
        try await context.perform { [context] in
            let request = NSFetchRequest<NSDictionary>(entityName: "ExploredCell")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["centerLatitude", "centerLongitude"]
            return try context.fetch(request).compactMap { row in
                guard let latitude = (row["centerLatitude"] as? NSNumber)?.doubleValue,
                      let longitude = (row["centerLongitude"] as? NSNumber)?.doubleValue else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }
    }

    /// 開拓済みセルを全削除する(グリッド再構築の最初の手順)。
    /// batch delete は context を経由せずストアを直接書き換えるので、直後に `reset()` して
    /// この context が抱えている登録済みオブジェクトを捨てる(残すと削除済みの行を参照する)。
    func resetAllCells() async throws {
        try await context.perform { [context] in
            let request = NSBatchDeleteRequest(
                fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: "ExploredCell"))
            try context.execute(request)
            context.reset()
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
    ///
    /// 「未開拓」は、その地点が**地図上で晴れて見えない**こと(= `explorationRevealRadiusMeters`
    /// 以内に開拓済みセルの中心が無いこと)で判定する。晴れの半径(150m)はセル(75m)より広いので、
    /// 「その地点のセルが未開拓か」だけで判定すると、晴れて見える場所に「未踏エリア」の印が立つ。
    func findFrontierCandidates(home: CLLocationCoordinate2D)
        async throws -> [(coordinate: CLLocationCoordinate2D, bearingDegrees: Double, distanceMeters: Double)] {
        let radius = Tunables.explorationFrontierMaxRadiusMeters
        let box = boundingBox(center: home, radiusMeters: radius + Tunables.explorationRevealRadiusMeters)
        let explored = try await fetchCells(minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon)
        // 保存済みの中心はセル番号だけで決まる値なので、セルへ戻すと元のセルになる。
        let exploredKeys = Set(explored.map { ExplorationGrid.cell(for: $0).key })

        var candidates: [(coordinate: CLLocationCoordinate2D, bearingDegrees: Double, distanceMeters: Double)] = []
        let directionCount = Tunables.explorationFrontierDirectionCount
        for i in 0..<directionCount {
            let bearing = Double(i) * (360.0 / Double(directionCount))
            var step = Tunables.explorationFrontierStepMeters
            while step <= radius {
                let point = offset(from: home, distanceMeters: step, bearingDegrees: bearing)
                if !isRevealed(point, exploredKeys: exploredKeys) {
                    candidates.append((point, bearing, step))
                    break
                }
                step += Tunables.explorationFrontierStepMeters
            }
        }
        return candidates
    }

    /// `point` から晴れの半径以内に、開拓済みセルの中心があるか。
    /// 近傍のセルだけを調べる(行ごとに経度セル幅が違うので、経度バケットは行ごとに求め直す)。
    /// `internal`(テストから直接検証するため)。
    func isRevealed(_ point: CLLocationCoordinate2D, exploredKeys: Set<Int64>) -> Bool {
        let reveal = Tunables.explorationRevealRadiusMeters
        let reach = Int32((reveal / Tunables.explorationCellSizeMeters).rounded(.up)) + 1
        let baseRow = ExplorationGrid.latBucket(latitude: point.latitude)
        for row in (baseRow - reach)...(baseRow + reach) {
            let baseColumn = ExplorationGrid.lonBucket(longitude: point.longitude, latBucket: row)
            for column in (baseColumn - reach)...(baseColumn + reach)
            where exploredKeys.contains(ExplorationGrid.key(latBucket: row, lonBucket: column)) {
                let center = ExplorationGrid.center(latBucket: row, lonBucket: column)
                if distanceMeters(center, point) <= reveal { return true }
            }
        }
        return false
    }

    // MARK: - 地理計算ヘルパー

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

/// 先着順の非同期ミューテックス(再入不可)。`ExplorationService.outingGate` として、
/// 外出単位の処理を直列化するために使う。
///
/// `acquire()` は空いていれば即座に戻り、保持中なら待ち行列に入って中断する。
/// `release()` は待ちがあれば先頭を再開し(保持をそのまま引き継ぐ)、なければ解放する。
/// 使用箇所の Task はキャンセルされない前提で、キャンセルには対応しない。
final class AsyncGate: Sendable {
    private struct State {
        var isHeld = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state -> Bool in
                if state.isHeld {
                    state.waiters.append(continuation)
                    return false
                }
                state.isHeld = true
                return true
            }
            // ロックの外で再開する(再開先がすぐ release() を呼んでも自己デッドロックしない)。
            if acquired { continuation.resume() }
        }
    }

    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.isHeld = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
