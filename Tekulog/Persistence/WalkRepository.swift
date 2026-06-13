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
    func beginSession(kind: ActivityKind, startedAt: Date) async throws -> NSManagedObjectID {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            let session = WalkSession(context: context)
            session.id = UUID()
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
}
