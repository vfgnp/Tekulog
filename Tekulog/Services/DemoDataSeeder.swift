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
            // 前回のデモセッションが残っていたら消して作り直す(ルート形状の変更を反映)。
            let request = WalkSession.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", [walkID, runID, walk2ID])
            for old in try context.fetch(request) {
                context.delete(old)
            }

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

    /// 朝の散歩(約2.7km): 原宿門→中央広場→北広場(寄り道)→西→南の池→東→原宿門。
    /// 円周だと「散歩のルート」に見えないため、園路をジグザグに繋ぐ経由点で描く。
    private static let walkPath: [(Double, Double)] = [
        (35.67035, 139.70245), (35.66990, 139.70130), (35.67030, 139.70000),
        (35.67105, 139.69895), (35.67200, 139.69850), (35.67280, 139.69760),
        (35.67340, 139.69700), (35.67280, 139.69760),   // 北への寄り道(往復)
        (35.67250, 139.69630), (35.67150, 139.69560), (35.67040, 139.69580),
        (35.66965, 139.69680), (35.66930, 139.69800), (35.66980, 139.69920),
        (35.67060, 139.69990), (35.66995, 139.70110), (35.67035, 139.70245),
    ]

    /// 夜のランニング(外周2周、約4.8km)。
    private static let runLap: [(Double, Double)] = [
        (35.67060, 139.70180), (35.67230, 139.70050), (35.67330, 139.69850),
        (35.67290, 139.69620), (35.67130, 139.69510), (35.66950, 139.69590),
        (35.66880, 139.69800), (35.66940, 139.70030), (35.67060, 139.70180),
    ]

    /// セッションの基準日。`-demoMapDaysAgo N`(N日前、実機は 35 推奨)で
    /// 実データの無い過去日にずらし、本物の記録と地図上で混ざらないようにする。
    /// (負値は UserDefaults の起動引数パースで別キー扱いされ得るため「N日前」の正数指定。)
    private static var demoDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        let raw = UserDefaults.standard.object(forKey: "demoMapDaysAgo")
        let daysAgo = (raw as? Int) ?? (raw as? String).flatMap { Int($0) } ?? 0
        return Calendar.current.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    private static func seedSessions(_ context: NSManagedObjectContext) {
        let calendar = Calendar.current
        let base = demoDay

        // 07:32〜08:10 朝の散歩
        makeSession(context, id: walkID, kind: .walking,
                    start: base.addingTimeInterval(7 * 3600 + 32 * 60),
                    duration: 38 * 60, steps: 4_120, path: walkPath)

        // 前日 19:06〜19:38 夜のランニング(外周2周)
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: base) {
            makeSession(context, id: runID, kind: .running,
                        start: dayBefore.addingTimeInterval(19 * 3600 + 6 * 60),
                        duration: 32 * 60, steps: 4_930,
                        path: runLap + runLap.dropFirst())
        }

        // 3日前 16:12〜16:57 夕方の散歩(逆回り)
        if let threeDaysBefore = calendar.date(byAdding: .day, value: -3, to: base) {
            makeSession(context, id: walk2ID, kind: .walking,
                        start: threeDaysBefore.addingTimeInterval(16 * 3600 + 12 * 60),
                        duration: 45 * 60, steps: 4_760, path: walkPath.reversed())
        }
    }

    /// 経由点列を等間隔に補間し、GPS らしい揺らぎを加えてセッションを1件作る。
    private static func makeSession(_ context: NSManagedObjectContext,
                                    id: UUID, kind: ActivityKind,
                                    start: Date, duration: TimeInterval, steps: Int,
                                    path: [(Double, Double)]) {
        let session = WalkSession(context: context)
        session.id = id
        session.activityKind = kind
        session.startedAt = start
        session.endedAt = start.addingTimeInterval(duration)
        session.totalSteps = Int64(steps)

        // 経由点間の累積距離を出し、10秒ごとの1点を距離で等配分する。
        let waypoints = path.map { CLLocation(latitude: $0.0, longitude: $0.1) }
        var cumulative: [Double] = [0]
        for i in 1..<waypoints.count {
            cumulative.append(cumulative[i - 1] + waypoints[i].distance(from: waypoints[i - 1]))
        }
        let pathLength = cumulative.last ?? 0

        let interval: TimeInterval = 10
        let count = Int(duration / interval)
        var previous: CLLocation?
        var distance: Double = 0
        var segment = 1
        for i in 0...count {
            let progress = Double(i) / Double(count)
            let target = pathLength * progress
            while segment < cumulative.count - 1, cumulative[segment] < target { segment += 1 }
            let segStart = cumulative[segment - 1]
            let segLength = max(cumulative[segment] - segStart, 0.001)
            let t = min(max((target - segStart) / segLength, 0), 1)
            let a = path[segment - 1], b = path[segment]
            // GPS らしい ±数 m の揺らぎ(決定的)。
            let lat = a.0 + (b.0 - a.0) * t + 3e-5 * sin(Double(i) * 2.3)
            let lon = a.1 + (b.1 - a.1) * t + 3e-5 * cos(Double(i) * 1.9)

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
