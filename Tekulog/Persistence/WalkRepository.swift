import CoreData
import CoreLocation

/// ルート1点分の値。CLLocation を Core Data 層へ持ち込まずに受け渡す。
struct RouteSample: Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let horizontalAccuracy: Double

    init(location: CLLocation) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        speed = max(0, location.speed)
        horizontalAccuracy = location.horizontalAccuracy
    }
}

/// セッション確定時の集計値。
struct SessionMetrics: Sendable {
    var totalDistance: Double = 0   // メートル
    var totalSteps: Int = 0
    var avgPace: Double = 0         // 秒/km
    var energyBurned: Double = 0    // kcal
    var healthKitWorkoutUUID: UUID?
}

/// 通勤判定(`OutingClassifier`)が過去セッションと照合するための最小限のスナップショット。
struct CommuteCandidate: Sendable {
    let startedAt: Date
    let startCoordinate: CLLocationCoordinate2D
    let endCoordinate: CLLocationCoordinate2D
}

/// WalkSession / RoutePoint の永続化操作。書き込みはバックグラウンド context 上で行う。
///
/// `@unchecked Sendable`: 各メソッドが専用 background context を生成し `perform` 上で
/// 完結するため、複数スレッド/Task から呼んでも安全。
final class WalkRepository: @unchecked Sendable {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    /// 新しいセッションを作成し、その永続ID を返す。
    /// `id` は呼び出し側が採番して渡す(通知やレース検出に同じ値を再利用するため)。
    func beginSession(id: UUID, kind: ActivityKind, startedAt: Date) async throws -> NSManagedObjectID {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            let session = WalkSession(context: context)
            session.id = id
            session.startedAt = startedAt
            session.activityKind = kind
            try context.save()
            return session.objectID
        }
    }

    /// ルート点をまとめて追記する。GPS ストリームから小バッチで呼ぶ想定。
    func appendPoints(_ samples: [RouteSample], to sessionID: NSManagedObjectID) async throws {
        guard !samples.isEmpty else { return }
        let context = persistence.newBackgroundContext()
        try await context.perform {
            guard let session = try context.existingObject(with: sessionID) as? WalkSession else {
                return
            }
            for sample in samples {
                let point = RoutePoint(context: context)
                point.timestamp = sample.timestamp
                point.latitude = sample.latitude
                point.longitude = sample.longitude
                point.altitude = sample.altitude
                point.speed = sample.speed
                point.horizontalAccuracy = sample.horizontalAccuracy
                point.session = session
            }
            try context.save()
        }
    }

    /// セッションを確定(終了時刻と集計値を書き込み)する。
    func finalizeSession(_ sessionID: NSManagedObjectID,
                         endedAt: Date,
                         metrics: SessionMetrics) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            guard let session = try context.existingObject(with: sessionID) as? WalkSession else {
                return
            }
            session.endedAt = endedAt
            session.totalDistance = metrics.totalDistance
            session.totalSteps = Int64(metrics.totalSteps)
            session.avgPace = metrics.avgPace
            session.energyBurned = metrics.energyBurned
            session.healthKitWorkoutUUID = metrics.healthKitWorkoutUUID
            try context.save()
        }
    }

    /// `endedAt` より後のルート点を削除し、残った点の総距離(m)を返す。
    /// 停止検知(stopDuration 経過後)までに記録された末尾の静止点を切り落とすために使う。
    @discardableResult
    func trimTrailingPoints(after endedAt: Date, in sessionID: NSManagedObjectID) async throws -> Double {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            guard let session = try context.existingObject(with: sessionID) as? WalkSession else {
                return 0
            }
            // endedAt より後の点を削除。
            for point in session.orderedPoints where (point.timestamp ?? .distantPast) > endedAt {
                context.delete(point)
            }
            try context.save()

            // 残った点で総距離を再計算。
            let remaining = session.orderedPoints
            var distance: Double = 0
            var previous: CLLocation?
            for point in remaining {
                let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
                if let previous {
                    distance += location.distance(from: previous)
                }
                previous = location
            }
            return distance
        }
    }

    /// HealthKit のワークアウト UUID を後追いで紐付ける。
    func attachHealthKitWorkout(_ workoutUUID: UUID, to sessionID: NSManagedObjectID) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            guard let session = try context.existingObject(with: sessionID) as? WalkSession else {
                return
            }
            session.healthKitWorkoutUUID = workoutUUID
            try context.save()
        }
    }

    /// セッションを削除(誤検知の手動破棄など)。RoutePoint は Cascade 削除。
    func deleteSession(_ sessionID: NSManagedObjectID) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            guard let session = try context.existingObject(with: sessionID) as? WalkSession else {
                return
            }
            context.delete(session)
            try context.save()
        }
    }

    /// 日別歩数台帳を upsert する。`day` は startOfDay 前提(uniqueness 制約のキー)。
    /// CMPedometer の7日照会結果を StepLedgerService が定期的に書き込む。
    func upsertDailySteps(day: Date, steps: Int) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            let request = DailyStat.fetchRequest()
            request.predicate = NSPredicate(format: "day == %@", day as NSDate)
            request.fetchLimit = 1
            let stat = try context.fetch(request).first ?? {
                let new = DailyStat(context: context)
                new.day = day
                return new
            }()
            stat.steps = Int64(steps)
            stat.updatedAt = Date()
            try context.save()
        }
    }

    /// セッションを UUID で削除する。通知の「破棄」アクションから呼ぶ。
    func deleteSession(withID id: UUID) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            let request = WalkSession.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let session = try context.fetch(request).first else { return }
            context.delete(session)
            try context.save()
        }
    }

    /// 確定済みセッションのルート座標を取得する(探索グリッド反映・外出目的判定に使う)。
    func fetchRouteCoordinates(for sessionID: NSManagedObjectID) async throws -> [CLLocationCoordinate2D] {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            guard let session = try context.existingObject(with: sessionID) as? WalkSession else { return [] }
            return session.coordinates
        }
    }

    /// 通勤判定用: 指定期間内の確定済み walking/cycling セッションの開始/終了地点を返す
    /// (`sessionID` 自身は除外)。
    func fetchCommuteCandidates(since: Date, before: Date, excluding sessionID: NSManagedObjectID) async throws -> [CommuteCandidate] {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            let request = WalkSession.fetchRequest()
            request.predicate = NSPredicate(
                format: "startedAt >= %@ AND startedAt < %@ AND endedAt != nil AND activityTypeRaw IN %@",
                since as NSDate, before as NSDate, ["walking", "cycling"])
            let sessions = try context.fetch(request).filter { $0.objectID != sessionID }
            return sessions.compactMap { session -> CommuteCandidate? in
                guard let startedAt = session.startedAt else { return nil }
                let coords = session.coordinates
                guard let first = coords.first, let last = coords.last else { return nil }
                return CommuteCandidate(startedAt: startedAt, startCoordinate: first, endCoordinate: last)
            }
        }
    }

    /// `OutingClassifier` の判定結果と、探索グリッドの新規開拓数を書き込む(確定時に一度だけ)。
    /// `classifiedAt` が既に立っていれば書き込まない — ライブ確定とバックフィルが同じセッションを
    /// 二重処理した場合に、後勝ちで正しい値(先に処理した側)を誤って 0 上書きするのを防ぐガード。
    ///
    /// ユーザーが先に外出目的を手動で決めていた(`purposeIsUserSet`)場合、目的は上書きしない
    /// (`setPurpose` は `classifiedAt` を立てないので、保存通知から詳細を開いてすぐ目的を変えると、
    /// 自動判定のほうが後から届く)。新規開拓数と `classifiedAt` は書く。
    /// セッションが既に削除されていれば何もしない(分類の通信を待っている間に削除されうる)。
    func finalizeClassification(sessionID: NSManagedObjectID, purpose: OutingPurpose, newCellCount: Int) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            guard let session = try Self.existingSession(sessionID, in: context),
                  session.classifiedAt == nil else { return }
            if !session.purposeIsUserSet {
                session.purpose = purpose
            }
            session.exploredNewCellCount = Int64(newCellCount)
            session.classifiedAt = Date()
            try context.save()
        }
    }

    /// ユーザーがログ詳細のチップで外出目的を手動上書きする。以後の一括再判定から保護するため
    /// `purposeIsUserSet` も立てる。
    func setPurpose(sessionID: NSManagedObjectID, purpose: OutingPurpose) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            guard let session = try context.existingObject(with: sessionID) as? WalkSession else { return }
            session.purpose = purpose
            session.purposeIsUserSet = true
            try context.save()
        }
    }

    /// 未分類(`classifiedAt == nil`)の確定済みセッションを `startedAt` 昇順で1件返す。
    /// `ExplorationBackfillService` が起動時にこれを使って古いセッションを順に再生する。
    /// カーソルではなくこのフラグで判定するため、ライブ確定が先に処理した最新セッションを
    /// バックフィルが後から二重処理することもない。
    func fetchOldestUnclassifiedSession() async throws -> (id: NSManagedObjectID, kind: ActivityKind, startedAt: Date, totalDistance: Double)? {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            let request = WalkSession.fetchRequest()
            request.predicate = NSPredicate(format: "classifiedAt == nil AND endedAt != nil")
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
            request.fetchLimit = 1
            guard let session = try context.fetch(request).first, let startedAt = session.startedAt else { return nil }
            return (session.objectID, session.activityKind, startedAt, session.totalDistance)
        }
    }

    // MARK: - 探索グリッドの再構築(ExplorationBackfillService)

    /// 確定済みの全セッションを `startedAt` 昇順で返す。グリッド再構築が古い順に再生するために使う。
    func fetchFinalizedSessions() async throws -> [FinalizedSessionRef] {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            let request = WalkSession.fetchRequest()
            request.predicate = NSPredicate(format: "endedAt != nil")
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
            return try context.fetch(request).compactMap { session in
                guard let startedAt = session.startedAt else { return nil }
                return FinalizedSessionRef(id: session.objectID,
                                           kind: session.activityKind,
                                           startedAt: startedAt,
                                           totalDistance: session.totalDistance,
                                           isClassified: session.classifiedAt != nil)
            }
        }
    }

    /// 探索グリッドの新規開拓数だけを書き直す。外出目的(`purpose` / `purposeIsUserSet`)と
    /// `classifiedAt` には触れない。**グリッド再構築(排他ゲート保持中)からしか呼ばないこと** —
    /// それ以外から呼ぶと、`finalizeClassification` の `classifiedAt` ガードが守っている
    /// 「後から来た二重処理が正しい値を 0 で上書きしない」が崩れる。
    /// セッションが既に削除されていれば何もしない。
    func setExploredNewCellCount(sessionID: NSManagedObjectID, count: Int) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            guard let session = try Self.existingSession(sessionID, in: context) else { return }
            session.exploredNewCellCount = Int64(count)
            try context.save()
        }
    }

    /// 外出目的の分類と探索グリッドへの反映が済んでいるか。セッションが既に削除されていれば
    /// `true`(もう処理する必要がない)を返す。
    func isClassified(sessionID: NSManagedObjectID) async throws -> Bool {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            guard let session = try Self.existingSession(sessionID, in: context) else { return true }
            return session.classifiedAt != nil
        }
    }

    /// `fetchRouteCoordinates(for:)` の「削除済みなら `nil`」版。グリッド再構築は、再生の途中で
    /// 削除されたセッションを失敗ではなく読み飛ばしとして扱うため、削除とそれ以外のエラーを区別する。
    func fetchRouteCoordinatesIfExists(for sessionID: NSManagedObjectID) async throws -> [CLLocationCoordinate2D]? {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            try Self.existingSession(sessionID, in: context)?.coordinates
        }
    }

    /// `existingObject(with:)` は対象が無いと `NSManagedObjectReferentialIntegrityError` を投げる。
    /// それだけを「削除済み」(`nil`)として扱い、他のエラーはそのまま投げる。
    private static func existingSession(_ sessionID: NSManagedObjectID,
                                        in context: NSManagedObjectContext) throws -> WalkSession? {
        do {
            return try context.existingObject(with: sessionID) as? WalkSession
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSManagedObjectReferentialIntegrityError {
            return nil
        }
    }
}

/// グリッド再構築(`ExplorationBackfillService`)が確定済みセッションを古い順に再生するための
/// スナップショット。
///
/// `@unchecked Sendable`: `NSManagedObjectID` は不変でスレッド間共有できる。
struct FinalizedSessionRef: @unchecked Sendable {
    let id: NSManagedObjectID
    let kind: ActivityKind
    let startedAt: Date
    let totalDistance: Double
    /// 外出目的の分類が済んでいるか(`classifiedAt != nil`)。
    let isClassified: Bool
}
