import Foundation

/// てくポイント・血流ポンプ量の推定(純粋関数)。
///
/// 値は保存せず、歩数台帳(DailyStat)とセッションから毎回計算する —
/// Tunables の式・係数を変えても過去分まで一貫した値になる。
/// 血流は「心拍出量(安静約5L/分、歩行約11L/分、ラン約16L/分)」という
/// 生理学的目安から、歩数を仮定ケイデンスで活動分数に換算して推定する。
enum Motivation {

    /// その日のてくポイント。
    /// 日別歩数 × 基本pt + ランニングセッション歩数 × (倍率−1)pt。
    /// ラン歩数は日別歩数にも含まれるため、上乗せぶんだけ加算する。
    static func points(daySteps: Int, runningSessionSteps: Int) -> Int {
        let base = Double(daySteps) * Tunables.pointsPerStep
        let bonus = Double(min(runningSessionSteps, daySteps))
            * Tunables.pointsPerStep * (Tunables.runningPointMultiplier - 1)
        return Int(base + bonus)
    }

    /// その日の血流ポンプ量(L)。ランニングぶんは高い心拍出量との差を上乗せ。
    static func bloodLiters(daySteps: Int, runningSessionSteps: Int) -> Double {
        let walkMinutes = Double(daySteps) / Tunables.assumedCadenceStepsPerMinute
        let base = walkMinutes * Tunables.cardiacOutputWalkingLitersPerMinute
        let runMinutes = Double(min(runningSessionSteps, daySteps))
            / Tunables.assumedCadenceStepsPerMinute
        let extra = runMinutes
            * (Tunables.cardiacOutputRunningLitersPerMinute - Tunables.cardiacOutputWalkingLitersPerMinute)
        return base + extra
    }

    /// 血めぐりスコア(0〜100)。歩数の目標達成度が主配点で、
    /// 1日歩数に占めるランセッション歩数の比率でボーナスを上乗せする。
    static func score(daySteps: Int, goal: Int, runningSessionSteps: Int) -> Int {
        guard goal > 0 else { return 0 }
        let stepPart = min(1, Double(daySteps) / Double(goal)) * Tunables.scoreStepsWeight
        let runShare = daySteps > 0
            ? Double(min(runningSessionSteps, daySteps)) / Double(daySteps)
            : 0
        let runPart = min(1, runShare / Tunables.scoreRunShareForFullBonus) * Tunables.scoreRunBonusWeight
        return Int((stepPart + runPart).rounded())
    }

    /// スコアの評価語。
    static func scoreLabel(_ score: Int) -> String {
        switch score {
        case 70...: return "好調!"
        case 40..<70: return "まずまず"
        default: return "これから"
        }
    }

    /// 血流量の楽しい比喩(バスタブ約200L換算)。
    static func bloodMetaphor(liters: Double) -> String {
        let bathtubs = liters / Tunables.bathtubLiters
        if bathtubs >= 10 {
            return String(format: "タンクローリー級! バスタブ約%.0f杯分", bathtubs)
        }
        if bathtubs >= 1 {
            return String(format: "バスタブ約%.1f杯分", bathtubs)
        }
        return String(format: "バスタブの約%.0f%%", bathtubs * 100)
    }
}
