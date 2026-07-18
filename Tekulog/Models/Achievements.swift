import SwiftUI

/// 実績(レベル・連続記録・バッジ)のドメイン計算。すべて純関数で、
/// `DailyStat` とセッションから毎回再計算する(永続化しない=係数変更に追随)。
enum Achievements {

    // MARK: - レベル(累計ポイント制)

    /// 1レベルぶんのポイント。
    static let pointsPerLevel = 10_000

    /// 段階名。最上位は「血めぐりマスター」。レベルが配列長を超えたら最上位で頭打ち。
    private static let levelNames = [
        "てくてく見習い", "さんぽビギナー", "まちあるき人", "血めぐり修行中",
        "血めぐり中級者", "血めぐり上級者", "血めぐり達人", "血めぐりマスター"
    ]

    /// 累計ポイントからレベル(1始まり)。
    static func level(points: Int) -> Int { max(1, points / pointsPerLevel + 1) }

    static func levelName(_ level: Int) -> String {
        levelNames[min(max(0, level - 1), levelNames.count - 1)]
    }

    /// 現在レベル内の進捗(0...1)。
    static func levelProgress(points: Int) -> Double {
        Double(points % pointsPerLevel) / Double(pointsPerLevel)
    }

    /// 次のレベルまでの残りポイント。
    static func pointsToNext(points: Int) -> Int {
        pointsPerLevel - (points % pointsPerLevel)
    }

    // MARK: - 連続記録

    /// 今日から遡って歩数>0が続く日数。`recordedDays` は startOfDay の集合。
    static func streak(recordedDays: Set<Date>, today: Date = Calendar.current.startOfDay(for: Date())) -> Int {
        let calendar = Calendar.current
        var count = 0
        var day = today
        while recordedDays.contains(day) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    // MARK: - バッジ

    /// バッジ判定の入力。View が集計して渡す。
    struct Stats {
        var sessionCount: Int
        var totalSteps: Int
        var totalDistanceMeters: Double
        var streakDays: Int
        var hasEarlyStart: Bool       // 7時前に開始したセッションがある
        var hasGoodScoreDay: Bool     // 血めぐりスコア70以上の日がある
    }

    struct Badge: Identifiable {
        let id: String
        let name: String
        let icon: String
        let tint: Color
        let earned: Bool
    }

    /// 8種のバッジを判定して返す(未獲得も含む)。
    static func badges(_ s: Stats) -> [Badge] {
        [
            Badge(id: "first",    name: "初めの一歩",  icon: "👣", tint: TekTheme.primary,
                  earned: s.sessionCount >= 1),
            Badge(id: "steps100k", name: "10万歩",     icon: "🚶", tint: TekTheme.primary,
                  earned: s.totalSteps >= 100_000),
            Badge(id: "streak7",  name: "7日連続",    icon: "🔥", tint: TekTheme.coral,
                  earned: s.streakDays >= 7),
            Badge(id: "early",    name: "早起き",      icon: "🌅", tint: TekTheme.amber,
                  earned: s.hasEarlyStart),
            Badge(id: "goodblood", name: "血めぐり好調", icon: "❤️", tint: TekTheme.coral,
                  earned: s.hasGoodScoreDay),
            Badge(id: "dist100",  name: "100km",      icon: "🏃", tint: TekTheme.blue,
                  earned: s.totalDistanceMeters >= 100_000),
            Badge(id: "streak30", name: "30日連続",   icon: "📅", tint: TekTheme.coral,
                  earned: s.streakDays >= 30),
            Badge(id: "steps1m",  name: "100万歩",    icon: "👑", tint: TekTheme.amber,
                  earned: s.totalSteps >= 1_000_000)
        ]
    }

    static func earnedCount(_ badges: [Badge]) -> Int { badges.filter(\.earned).count }
}
