import SwiftUI
import Charts
import CoreData

/// ホーム。今日の歩数(ライブ)+てくポイント+血流ポンプ量と、
/// 直近14日の歩数グラフ(バータップでその日の日別まとめへ)。
struct HomeView: View {
    /// 今日歩数のライブ供給元(SessionCoordinator.stepLedger を渡す)。
    @ObservedObject var ledger: StepLedgerService

    /// 歩数台帳。グラフと累計ポイントに使う。
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DailyStat.day, ascending: false)],
        animation: .default
    )
    private var dailyStats: FetchedResults<DailyStat>

    /// 終了済みランニングセッション(ポイント/血流の上乗せ計算用)。
    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(format: "endedAt != nil AND activityTypeRaw == %@",
                               ActivityKind.running.rawValue)
    )
    private var runningSessions: FetchedResults<WalkSession>

    /// グラフのバータップ→日別まとめ遷移。
    @State private var chartSelection: Date?
    @State private var navDay: NavDay?

    private struct NavDay: Identifiable, Hashable {
        let date: Date
        var id: Date { date }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                todayCard
                motivationCards
                stepsChartCard
            }
            .padding()
        }
        .navigationTitle("ホーム")
        .navigationDestination(item: $navDay) { nav in
            DaySummaryView(day: nav.date)
        }
    }

    // MARK: - 今日の値

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// 今日の歩数。台帳のライブ値を正とし、未取得なら永続化済みの値。
    private var todaySteps: Int {
        if ledger.todaySteps > 0 { return ledger.todaySteps }
        return dailyStats.first { $0.day == today }.map { Int($0.steps) } ?? 0
    }

    /// 指定日のランニングセッション歩数合計。
    private func runningSteps(on day: Date) -> Int {
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return 0 }
        return runningSessions
            .filter { ($0.startedAt ?? .distantPast) >= day && ($0.startedAt ?? .distantPast) < end }
            .reduce(0) { $0 + Int($1.totalSteps) }
    }

    /// 累計てくポイント(台帳全期間+ラン上乗せ。今日はライブ値で置き換え)。
    private var totalPoints: Int {
        let pastSteps = dailyStats.filter { $0.day != today }.reduce(0) { $0 + Int($1.steps) }
        let allRunningSteps = runningSessions.reduce(0) { $0 + Int($1.totalSteps) }
        return Motivation.points(daySteps: pastSteps + todaySteps,
                                 runningSessionSteps: allRunningSteps)
    }

    // MARK: - カード

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("今日の歩数", systemImage: "shoeprints.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(todaySteps)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("歩")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var motivationCards: some View {
        let todayRunning = runningSteps(on: today)
        let todayPoints = Motivation.points(daySteps: todaySteps, runningSessionSteps: todayRunning)
        let liters = Motivation.bloodLiters(daySteps: todaySteps, runningSessionSteps: todayRunning)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(title: "今日のてくポイント",
                         value: "+\(todayPoints) pt",
                         symbol: "star.fill")
                StatCard(title: "累計ポイント",
                         value: "\(totalPoints) pt",
                         symbol: "trophy.fill")
            }
            // 血流は比喩も見せたいので専用レイアウト。
            VStack(alignment: .leading, spacing: 6) {
                Label("今日の血流ポンプ量", systemImage: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "約 %.0f L", liters))
                        .font(.title3.bold())
                    Text(Motivation.bloodMetaphor(liters: liters))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("歩くほど心臓が血液を送り出します。ランニングならさらに増えます。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - 直近14日グラフ

    /// 直近14日(欠測日は0)を昇順で。
    private var chartData: [(day: Date, steps: Int)] {
        let calendar = Calendar.current
        let byDay = Dictionary(uniqueKeysWithValues: dailyStats.map { ($0.day ?? .distantPast, Int($0.steps)) })
        return (0..<14).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let steps = day == today ? todaySteps : (byDay[day] ?? 0)
            return (day: day, steps: steps)
        }
    }

    private var stepsChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("直近14日の歩数", systemImage: "chart.bar.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(chartData, id: \.day) { item in
                BarMark(
                    x: .value("日", item.day, unit: .day),
                    y: .value("歩数", item.steps)
                )
                // 今日を強調、過去日は同一色相の控えめな濃度(系列は1つ=凡例不要)。
                .foregroundStyle(item.day == today ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.45)))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day(), centered: true)
                }
            }
            .chartXSelection(value: $chartSelection)
            .frame(height: 180)
            Text("バーをタップするとその日のまとめが開きます")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: chartSelection) { _, newValue in
            guard let newValue else { return }
            navDay = NavDay(date: Calendar.current.startOfDay(for: newValue))
            chartSelection = nil
        }
    }
}
