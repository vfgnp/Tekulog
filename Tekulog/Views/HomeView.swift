import SwiftUI
import CoreData

/// ホーム(行動ログ)。挨拶+マスコット、歩数リング(目標比)、今日の統計行、
/// 週間の外出目的サマリー、探索ナッジカード、血めぐりスコアカード、今日のログ一覧。
/// 記録中は右下に手動停止ボタンが出る(開始は全自動検出のみ、FABは廃止)。
struct HomeView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
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

    /// 終了済みセッション(今日の集計・週間サマリー・ログ一覧に使う)。
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WalkSession.startedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default
    )
    private var sessions: FetchedResults<WalkSession>

    // List を使わないので NavigationLink の意図しないディスクロージャ問題は起きないが、
    // CalendarView と同じ item ベースの遷移パターンに揃える。
    private struct NavSession: Identifiable, Hashable {
        let session: WalkSession
        var id: NSManagedObjectID { session.objectID }
    }
    @State private var navSession: NavSession?
    @State private var showLive = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                greeting
                ringCard
                statRow
                weeklyPurposeCard
                explorationNudgeCard
                bloodScoreCard
                todayLogSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(TekTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $navSession) { SessionDetailView(session: $0.session) }
        .overlay(alignment: .bottomTrailing) {
            if coordinator.isRecording {
                stopButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        .fullScreenCover(isPresented: $showLive) {
            LiveRecordingView()
                .environmentObject(coordinator)
        }
        #if DEBUG
        // スクショ検証用: `-liveDemo 1` で散歩セッションを開始し記録中画面を表示。
        .onAppear {
            if UserDefaults.standard.object(forKey: "liveDemo") != nil, !coordinator.isRecording {
                coordinator.startManually(kind: .walking)
                showLive = true
            }
        }
        #endif
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

    private var weekSessions: [WalkSession] {
        guard let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return sessions.filter { ($0.startedAt ?? .distantPast) >= weekStart }
    }

    // MARK: - 挨拶

    private var greeting: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("こんにちは、\(nickname)さん")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(TekTheme.ink)
                    if coordinator.isRecording {
                        recordingPill
                    }
                }
                Text(Formatters.day(Date()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TekTheme.sub)
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private var recordingPill: some View {
        HStack(spacing: 5) {
            Circle().fill(TekTheme.primary).frame(width: 7, height: 7)
            Text("記録中")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TekTheme.primaryDark)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(TekTheme.primaryPale, in: Capsule())
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

    // MARK: - 週間の外出目的サマリー

    private var weeklyPurposeCard: some View {
        let counts = Dictionary(grouping: weekSessions, by: \.purpose).mapValues(\.count)
        let entries = OutingPurpose.allCases.map { WeeklyPurposeBar.Entry(purpose: $0, count: counts[$0] ?? 0) }
        let totalCount = weekSessions.count
        let totalDistanceKm = weekSessions.reduce(0) { $0 + $1.totalDistance } / 1000
        return TekCard(radius: 22, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline) {
                    Text("今週の外出")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(TekTheme.ink)
                    Spacer()
                    Text("\(totalCount)回・\(String(format: "%.1f", totalDistanceKm))km")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TekTheme.sub)
                }
                if totalCount > 0 {
                    WeeklyPurposeBar(entries: entries)
                } else {
                    Text("今週はまだ記録がありません")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TekTheme.sub)
                }
            }
        }
    }

    // MARK: - 探索ナッジカード

    private var explorationNudgeCard: some View {
        let newAreaCount = weekSessions.reduce(0) { $0 + Int($1.exploredNewCellCount) }
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("今週の新エリア +\(newAreaCount)")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                Text("探索マップでまだ歩いていない場所を見てみよう")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            LinearGradient(colors: [TekTheme.primary, TekTheme.primaryDark],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .shadow(color: TekTheme.primary.opacity(0.25), radius: 10, y: 5)
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

    // MARK: - 今日のログ

    private var todayLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("きょうのログ")
            if todaySessions.isEmpty {
                Text("今日の記録はまだありません")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TekTheme.sub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 11) {
                    ForEach(todaySessions) { session in
                        logRow(session)
                    }
                }
            }
        }
    }

    private func logRow(_ session: WalkSession) -> some View {
        let colors = session.purpose.tekColors
        return Button {
            navSession = NavSession(session: session)
        } label: {
            TekCard(radius: 18, padding: 13) {
                HStack(spacing: 13) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(colors.background)
                        .frame(width: 46, height: 46)
                        .overlay {
                            Image(systemName: session.purpose.symbolName)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(colors.icon)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.autoName)
                            .font(.system(size: 15.5, weight: .heavy))
                            .foregroundStyle(TekTheme.ink)
                        HStack(spacing: 8) {
                            Text(session.purpose.displayName)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(colors.icon)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(colors.background, in: RoundedRectangle(cornerRadius: 6))
                            Text("\(Formatters.day(session.startedAt ?? Date()))・\(Formatters.distance(session.totalDistance))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(TekTheme.faint)
                        }
                    }
                    Spacer()
                    if session.exploredNewCellCount > 0 {
                        VStack(spacing: 1) {
                            Text("+\(session.exploredNewCellCount)")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(TekTheme.amber)
                            Text("新エリア")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(TekTheme.amber)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(TekTheme.amberPale, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 手動停止ボタン(記録中のみ表示)

    private var stopButton: some View {
        Button {
            showLive = true
        } label: {
            ZStack {
                Circle()
                    .fill(TekTheme.coral)
                    .frame(width: 56, height: 56)
                    .shadow(color: TekTheme.coral.opacity(0.4), radius: 9, y: 5)
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                Image(systemName: "stop.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: true)
            }
        }
        .buttonStyle(.plain)
    }
}
