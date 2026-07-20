#if DEBUG
import CoreData
import CoreLocation
import Foundation

/// App Store スクリーンショット用のデモデータ投入(DEBUG限定、Releaseには含まれない)。
///
/// 起動引数 `-demoData 1` で `TekulogApp.init` から**同期的に**実行する。
/// `DayRouteScreen` の fetch は init 時点で固定されるため、ビュー構築より前に
/// viewContext 上でデータを揃える必要がある(async だと初回表示に間に合わない)。
///
/// 投入内容: 過去14日分の `DailyStat` + ルート付き `WalkSession` 3件(今日の朝の散歩/
/// 昨日の夜のランニング/3日前の夕方の散歩)。固定 UUID で冪等(再起動しても重複しない)。
/// シミュレータは CMPedometer が無く台帳 refresh が no-op のため、ホームの歩数リングは
/// `StepLedgerService.setDemoTodaySteps` で直接与える。
@MainActor
enum DemoDataSeeder {

    /// 今日の歩数(ホームのリング表示と DailyStat の両方に使う)。
    private static let todaySteps = 9_240

    /// 冪等判定用の固定ID(今日の散歩セッション)。
    private static let walkID = UUID(uuidString: "DE300001-0000-4000-8000-000000000001")!
    private static let runID  = UUID(uuidString: "DE300001-0000-4000-8000-000000000002")!
    private static let walk2ID = UUID(uuidString: "DE300001-0000-4000-8000-000000000003")!

    /// 代々木公園付近。
    private static let park = CLLocationCoordinate2D(latitude: 35.67126, longitude: 139.69489)

    static func seedIfRequested() {
        let defaults = UserDefaults.standard

        // `-demoDataCleanup 1`: 固定IDのデモセッションを削除して終わり(実機の後片付け用)。
        if defaults.object(forKey: "demoDataCleanup") != nil {
            cleanup()
            return
        }

        guard let flag = defaults.object(forKey: "demoData") else { return }
        // `-demoData sessions`: セッションのみ投入。実機で使う想定 —
        // DailyStat(本物の歩数台帳)を上書きせず、消せるデータだけを足す。
        let sessionsOnly = (flag as? String) == "sessions"

        let context = PersistenceController.shared.container.viewContext
        do {
            let request = WalkSession.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", walkID as CVarArg)
            request.fetchLimit = 1
            guard try context.count(for: request) == 0 else { return }   // 投入済み

            if !sessionsOnly {
                // ホームの歩数リング(台帳はシミュレータでは更新されない)。
                SessionCoordinator.shared.stepLedger.setDemoTodaySteps(todaySteps)
                seedDailyStats(context)
            }
            seedSessions(context)
            try context.save()
        } catch {
            AppLog.lifecycle.error("DemoDataSeeder: 投入失敗 \(error.localizedDescription, privacy: .public)")
        }
    }

    /// デモセッション(固定ID)を削除する。DailyStat はシミュレータ専用投入なので触らない。
    private static func cleanup() {
        let context = PersistenceController.shared.container.viewContext
        do {
            let request = WalkSession.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", [walkID, runID, walk2ID])
            for session in try context.fetch(request) {
                context.delete(session)
            }
            try context.save()
            AppLog.lifecycle.notice("DemoDataSeeder: デモセッションを削除")
        } catch {
            AppLog.lifecycle.error("DemoDataSeeder: 削除失敗 \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - DailyStat(直近14日)

    private static func seedDailyStats(_ context: NSManagedObjectContext) {
        // 今日→13日前。目標(既定8,000歩)超えの日を多めにしてカレンダーを緑にする。
        let steps = [todaySteps, 11_480, 7_920, 6_410, 10_250, 8_890, 5_120,
                     12_040, 9_660, 4_380, 8_010, 10_930, 7_350, 9_820]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for (offset, value) in steps.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let request = DailyStat.fetchRequest()
            request.predicate = NSPredicate(format: "day == %@", day as NSDate)
            request.fetchLimit = 1
            let stat = (try? context.fetch(request).first) ?? nil
            let target = stat ?? DailyStat(context: context)
            target.day = day
            target.steps = Int64(value)
            target.updatedAt = Date()
        }
    }

    // MARK: - セッション(ルート付き)

    private static func seedSessions(_ context: NSManagedObjectContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 今日 07:32〜08:10 朝の散歩(公園1周+外周、約2.9km)
        makeSession(context, id: walkID, kind: .walking,
                    start: today.addingTimeInterval(7 * 3600 + 32 * 60),
                    duration: 38 * 60, steps: 4_120,
                    center: park, radius: 350, laps: 1.3, speedNoise: 0.05)

        // 昨日 19:06〜19:38 夜のランニング(2周強、約5.0km)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            makeSession(context, id: runID, kind: .running,
                        start: yesterday.addingTimeInterval(19 * 3600 + 6 * 60),
                        duration: 32 * 60, steps: 4_930,
                        center: park, radius: 380, laps: 2.1, speedNoise: 0.04)
        }

        // 3日前 16:12〜16:57 夕方の散歩
        if let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today) {
            makeSession(context, id: walk2ID, kind: .walking,
                        start: threeDaysAgo.addingTimeInterval(16 * 3600 + 12 * 60),
                        duration: 45 * 60, steps: 4_760,
                        center: park, radius: 400, laps: 1.4, speedNoise: 0.06)
        }
    }

    /// 公園を周回するもっともらしいルートでセッションを1件作る。
    private static func makeSession(_ context: NSManagedObjectContext,
                                    id: UUID, kind: ActivityKind,
                                    start: Date, duration: TimeInterval, steps: Int,
                                    center: CLLocationCoordinate2D,
                                    radius: Double, laps: Double, speedNoise: Double) {
        let session = WalkSession(context: context)
        session.id = id
        session.activityKind = kind
        session.startedAt = start
        session.endedAt = start.addingTimeInterval(duration)
        session.totalSteps = Int64(steps)

        // 10秒ごとに1点。半径に緩い揺らぎを入れて「道なり」に見せる。
        let interval: TimeInterval = 10
        let count = Int(duration / interval)
        var previous: CLLocation?
        var distance: Double = 0
        for i in 0...count {
            let progress = Double(i) / Double(count)
            let theta = progress * laps * 2 * .pi
            let wobble = 1 + speedNoise * sin(theta * 5) + 0.03 * sin(theta * 11)
            let r = radius * wobble
            let lat = center.latitude + r * cos(theta) / 111_320
            let lon = center.longitude + r * sin(theta) / (111_320 * cos(center.latitude * .pi / 180))

            let point = RoutePoint(context: context)
            point.timestamp = start.addingTimeInterval(Double(i) * interval)
            point.latitude = lat
            point.longitude = lon
            // 高低差は「1点あたり1m超の上り」のみ合算される(DayRouteView.ascent)ため、
            // 序盤10%で30m登る坂(1点あたり約+1.3m)を入れ、後半はゆるく下る。
            let climb = min(progress / 0.10, 1)
            point.altitude = 30 + 30 * climb - 12 * max(0, progress - 0.5) / 0.5
                + 0.3 * sin(Double(i))
            point.horizontalAccuracy = 5
            point.session = session

            let location = CLLocation(latitude: lat, longitude: lon)
            if let previous { distance += location.distance(from: previous) }
            point.speed = distance > 0 ? distance / (Double(i) * interval) : 0
            previous = location
        }

        session.totalDistance = distance
        session.avgPace = distance > 0 ? duration / (distance / 1000) : 0
        // ざっくり MET×体重60kg×時間。デモ表示用の概算で十分。
        let met = kind == .running ? 9.8 : 3.8
        session.energyBurned = met * 60 * (duration / 3600)
    }
}
#endif
