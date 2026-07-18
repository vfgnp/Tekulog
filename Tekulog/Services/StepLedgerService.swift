import Foundation
import CoreMotion

/// 自前の24時間歩数台帳。
///
/// モーションコプロセッサはアプリと無関係に常時歩数を数えており、
/// `CMPedometer.queryPedometerData(from:to:)` で**過去7日分**をいつでも照会できる。
/// これを定期的に照会して日別に Core Data(`DailyStat`)へ永続化することで、
/// ヘルスケア同等の「1日の総歩数」を HealthKit に頼らず自前で持つ。
/// アプリの常駐も追加センサーも不要なので電池負担はほぼゼロ。
/// 制約: 7日より前は照会できないため、台帳を書き始めた日以降の履歴だけが残る。
@MainActor
final class StepLedgerService: ObservableObject {

    /// 今日の歩数(ホーム表示用)。refresh のたびに更新。
    @Published private(set) var todaySteps: Int = 0

    private let pedometer = CMPedometer()
    private let repository: WalkRepository

    /// 今日の再照会の最短間隔。onWake(約30秒毎)から呼ばれても暴れないための throttle。
    private let todayThrottle: TimeInterval = 60
    /// 過去6日分を照会し直す最短間隔(日付またぎ直後の前日確定・穴埋め用)。
    private let backfillThrottle: TimeInterval = 5 * 60

    private var lastTodayRefreshAt: Date?
    private var lastBackfillAt: Date?

    init(repository: WalkRepository = WalkRepository()) {
        self.repository = repository
    }

    /// 台帳を更新する。呼び出し側は好きなだけ呼んでよい(内部 throttle が効く)。
    func refresh() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        if lastTodayRefreshAt.map({ now.timeIntervalSince($0) >= todayThrottle }) ?? true {
            lastTodayRefreshAt = now
            updateDay(today)
        }
        if lastBackfillAt.map({ now.timeIntervalSince($0) >= backfillThrottle }) ?? true {
            lastBackfillAt = now
            for offset in 1...6 {
                if let day = calendar.date(byAdding: .day, value: -offset, to: today) {
                    updateDay(day)
                }
            }
        }
    }

    /// 指定日(startOfDay)の歩数を照会して台帳へ upsert する。
    private func updateDay(_ day: Date) {
        let end = min(Date(), Calendar.current.date(byAdding: .day, value: 1, to: day) ?? Date())
        // ハンドラは別キューで呼ばれ得るため @Sendable + MainActor hop(既存パターン)。
        pedometer.queryPedometerData(from: day, to: end) { @Sendable [weak self] data, error in
            guard let data, error == nil else { return }
            let steps = data.numberOfSteps.intValue
            Task { @MainActor in
                guard let self else { return }
                if day == Calendar.current.startOfDay(for: Date()) {
                    self.todaySteps = steps
                }
                try? await self.repository.upsertDailySteps(day: day, steps: steps)
            }
        }
    }
}
