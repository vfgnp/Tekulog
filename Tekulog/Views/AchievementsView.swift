import SwiftUI
import CoreData

/// 実績画面(Claude Design 画面5)。レベルヒーロー+連続記録/獲得バッジ+
/// バッジグリッド。マイページから push(タブには置かない)。
struct AchievementsView: View {
    @AppStorage(TekTheme.Keys.stepGoal) private var stepGoal = TekTheme.defaultStepGoal

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DailyStat.day, ascending: false)],
        animation: .default
    )
    private var dailyStats: FetchedResults<DailyStat>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WalkSession.startedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil"),
        animation: .default
    )
    private var sessions: FetchedResults<WalkSession>

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                levelHero
                streakRow
                SectionLabel("バッジコレクション")
                    .padding(.top, 4)
                badgeGrid
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(TekTheme.background)
        .navigationTitle("実績")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 集計

    private var totalSteps: Int { dailyStats.reduce(0) { $0 + Int($1.steps) } }
    private var runningSteps: Int {
        sessions.filter { $0.activityKind == .running }.reduce(0) { $0 + Int($1.totalSteps) }
    }
    private var totalPoints: Int {
        Motivation.points(daySteps: totalSteps, runningSessionSteps: runningSteps)
    }
    private var totalDistance: Double { sessions.reduce(0) { $0 + $1.totalDistance } }

    private var recordedDays: Set<Date> {
        Set(dailyStats.compactMap { $0.steps > 0 ? $0.day.map { Calendar.current.startOfDay(for: $0) } : nil })
    }
    private var streakDays: Int { Achievements.streak(recordedDays: recordedDays) }

    private var hasEarlyStart: Bool {
        sessions.contains { session in
            guard let start = session.startedAt else { return false }
            return Calendar.current.component(.hour, from: start) < 7
        }
    }

    /// 血めぐり好調(スコア70以上)の日があるか。ラン込みの厳密計算は重いので
    /// 「歩数が目標の 0.875 倍以上=歩数だけで stepPart≧70」で近似する。
    private var hasGoodScoreDay: Bool {
        let threshold = Double(stepGoal) * 0.875
        return dailyStats.contains { Double($0.steps) >= threshold }
    }

    private var stats: Achievements.Stats {
        Achievements.Stats(sessionCount: sessions.count,
                           totalSteps: totalSteps,
                           totalDistanceMeters: totalDistance,
                           streakDays: streakDays,
                           hasEarlyStart: hasEarlyStart,
                           hasGoodScoreDay: hasGoodScoreDay)
    }

    // MARK: - レベルヒーロー

    private var levelHero: some View {
        let level = Achievements.level(points: totalPoints)
        let progress = Achievements.levelProgress(points: totalPoints)
        let toNext = Achievements.pointsToNext(points: totalPoints)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                MascotView(size: 60, onDark: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("現在のレベル")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Lv.\(level)")
                            .font(.tekNumber(30))
                        Text(Achievements.levelName(level))
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(.white)
                }
            }
            TekProgressBar(fraction: progress, tint: .white, track: .white.opacity(0.25), height: 8)
                .padding(.top, 16)
            Text("次のレベルまで あと \(toNext.formatted()) pt")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [TekTheme.primary, TekTheme.primaryDark],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26)
        )
        .shadow(color: TekTheme.primaryDark.opacity(0.3), radius: 12, y: 6)
    }

    // MARK: - 連続記録・獲得バッジ

    private var streakRow: some View {
        let earned = Achievements.earnedCount(Achievements.badges(stats))
        let total = Achievements.badges(stats).count
        return HStack(spacing: 12) {
            miniCard(title: "連続記録", value: "\(streakDays)", unit: "日", color: TekTheme.coral)
            miniCard(title: "獲得バッジ", value: "\(earned)", unit: "/ \(total)", color: TekTheme.primary)
        }
    }

    private func miniCard(title: String, value: String, unit: String, color: Color) -> some View {
        TekCard(radius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TekTheme.sub)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.tekNumber(28)).foregroundStyle(color)
                    Text(unit).font(.system(size: 14, weight: .bold)).foregroundStyle(TekTheme.ink)
                }
            }
        }
    }

    // MARK: - バッジグリッド

    private var badgeGrid: some View {
        let badges = Achievements.badges(stats)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(badges) { badge in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(badge.earned ? badge.tint.opacity(0.16) : TekTheme.hairline)
                        .frame(width: 58, height: 58)
                        .overlay {
                            Text(badge.icon)
                                .font(.system(size: 24))
                                .grayscale(badge.earned ? 0 : 1)
                                .opacity(badge.earned ? 1 : 0.45)
                        }
                        .shadow(color: TekTheme.cardShadow, radius: 6, y: 3)
                    Text(badge.name)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(badge.earned ? TekTheme.ink : TekTheme.faint)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
        }
    }
}
