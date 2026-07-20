import SwiftUI
import CoreData

/// ホーム(Claude Design 画面1)。挨拶+マスコット、歩数リング(目標比)、
/// 今日の統計行、血めぐりスコアカード。
struct HomeView: View {
    /// 今日歩数のライブ供給元(SessionCoordinator.stepLedger を渡す)。
    @ObservedObject var ledger: StepLedgerService

    @AppStorage(TekTheme.Keys.nickname) private var nickname = "あなた"
    @AppStorage(TekTheme.Keys.stepGoal) private var stepGoal = TekTheme.defaultStepGoal

    /// 歩数台帳(今日のフォールバックに使用)。
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DailyStat.day, ascending: false)],
        animation: .default
    )
    private var dailyStats: FetchedResults<DailyStat>

    /// 終了済みセッション(今日の距離/消費/時間とランボーナスの算出用)。
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WalkSession.startedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default
    )
    private var sessions: FetchedResults<WalkSession>

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                greeting
                ringCard
                statRow
                bloodScoreCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(TekTheme.background)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - 今日の値

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private var todaySteps: Int {
        if ledger.todaySteps > 0 { return ledger.todaySteps }
        return dailyStats.first { $0.day == today }.map { Int($0.steps) } ?? 0
    }

    private var todaySessions: [WalkSession] {
        sessions.filter { ($0.startedAt ?? .distantPast) >= today }
    }

    private var todayRunningSteps: Int {
        todaySessions.filter { $0.activityKind == .running }.reduce(0) { $0 + Int($1.totalSteps) }
    }

    // MARK: - 挨拶

    private var greeting: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("こんにちは、\(nickname)さん")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(TekTheme.ink)
                Text(Formatters.day(Date()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TekTheme.sub)
            }
            Spacer()
            MascotView(size: 52)
        }
        .padding(.top, 10)
    }

    // MARK: - 歩数リング

    private var ringCard: some View {
        let remaining = max(0, stepGoal - todaySteps)
        return TekCard(radius: 28, padding: 20) {
            VStack(spacing: 8) {
                ZStack {
                    RingGauge(progress: stepGoal > 0 ? Double(todaySteps) / Double(stepGoal) : 0)
                    VStack(spacing: 2) {
                        Text("今日の歩数")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(TekTheme.primary)
                        Text(todaySteps.formatted())
                            .font(.tekNumber(46))
                            .foregroundStyle(TekTheme.ink)
                            .contentTransition(.numericText())
                        Text("目標 \(stepGoal.formatted()) 歩")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TekTheme.sub)
                    }
                }
                .frame(maxWidth: .infinity)
                Text(remaining > 0 ? "目標まであと \(remaining.formatted()) 歩!" : "今日の目標を達成!🎉")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TekTheme.primaryDark)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(TekTheme.primaryPale, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - 統計行(今日のセッション合計)

    private var statRow: some View {
        let distance = todaySessions.reduce(0) { $0 + $1.totalDistance }
        let energy = todaySessions.reduce(0) { $0 + $1.energyBurned }
        let duration = todaySessions.reduce(0) { $0 + $1.duration }
        return HStack(spacing: 10) {
            StatTile(title: "距離", value: String(format: "%.1f", distance / 1000), unit: "km")
            StatTile(title: "消費", value: String(format: "%.0f", energy), unit: "kcal")
            StatTile(title: "時間", value: Self.hourMinute(duration))
        }
    }

    /// 「1:12」/「12分」形式の短い時間表示。
    private static func hourMinute(_ seconds: TimeInterval) -> String {
        let total = Int(seconds) / 60
        let h = total / 60, m = total % 60
        return h > 0 ? String(format: "%d:%02d", h, m) : "\(m)分"
    }

    // MARK: - 血めぐりスコア

    private var bloodScoreCard: some View {
        let score = Motivation.score(daySteps: todaySteps, goal: stepGoal,
                                     runningSessionSteps: todayRunningSteps)
        let liters = Motivation.bloodLiters(daySteps: todaySteps,
                                            runningSessionSteps: todayRunningSteps)
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(.white.opacity(0.22)).frame(width: 46, height: 46)
                Image(systemName: "heart.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("血めぐりスコア")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score)")
                        .font(.tekNumber(28))
                    Text(Motivation.scoreLabel(score))
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                TekProgressBar(fraction: Double(score) / 100)
                Text("血液を約\(Int(liters))Lポンプ・\(Motivation.bloodMetaphor(liters: liters))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            LinearGradient(colors: [TekTheme.coral, TekTheme.coralLight],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .shadow(color: TekTheme.coral.opacity(0.28), radius: 10, y: 5)
    }
}
