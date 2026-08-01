import Foundation

/// 外出の目的分類。`ActivityKind`(walking/running/cycling、モーション検出用)とは別軸で、
/// ユーザーに見せる「なんの外出か」を表す。ランニングは常に `.run`。
/// それ以外(walking/cycling)は `OutingClassifier` が自動判定し、ユーザーがチップで上書きできる。
enum OutingPurpose: String, CaseIterable, Sendable {
    case commute
    case walk
    case run
    case outing
    case shopping

    /// ローカライズ済み表示名。
    var displayName: String {
        switch self {
        case .commute: return "通勤"
        case .walk: return "散歩"
        case .run: return "ランニング"
        case .outing: return "お出かけ"
        case .shopping: return "お買い物"
        }
    }

    /// 一覧などで使う SF Symbol 名。
    var symbolName: String {
        switch self {
        case .commute: return "briefcase.fill"
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .outing: return "figure.walk.motion"
        case .shopping: return "cart.fill"
        }
    }
}
