import Foundation
import CoreMotion

/// 記録対象の活動種別。散歩(walking)・ランニング(running)・自転車(cycling)を扱う。
/// `automotive`(車・電車)や `stationary` は記録対象外。
enum ActivityKind: String, CaseIterable, Sendable {
    case walking
    case running
    case cycling

    /// CMMotionActivity から記録対象の種別を判定する。対象外なら nil。
    /// 複数フラグが立つことは稀だが、立った場合は running > walking を優先する
    /// (走行中に walking も立つことがあるため強度の高い方を採る)。
    init?(motionActivity activity: CMMotionActivity) {
        if activity.running {
            self = .running
        } else if activity.walking {
            self = .walking
        } else if activity.cycling {
            self = .cycling
        } else {
            return nil
        }
    }

    /// ローカライズ済み表示名。
    var displayName: String {
        switch self {
        case .walking: return "散歩"
        case .running: return "ランニング"
        case .cycling: return "自転車"
        }
    }

    /// 一覧などで使う SF Symbol 名。
    var symbolName: String {
        switch self {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        }
    }

    /// 歩数計(CMPedometer)が意味を持つ種目か。歩数・ペースの表示条件に使う。
    var countsSteps: Bool {
        switch self {
        case .walking, .running: return true
        case .cycling: return false
        }
    }
}
