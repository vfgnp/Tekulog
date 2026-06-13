import Foundation
import CoreMotion

/// 記録対象の活動種別。散歩(walking)と自転車(cycling)のみを扱う。
/// `automotive`(車・電車)や `stationary` は記録対象外。
enum ActivityKind: String, CaseIterable, Sendable {
    case walking
    case cycling

    /// CMMotionActivity から記録対象の種別を判定する。対象外なら nil。
    /// 複数フラグが立つことは稀だが、立った場合は walking を優先する。
    init?(motionActivity activity: CMMotionActivity) {
        if activity.walking {
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
        case .cycling: return "自転車"
        }
    }

    /// 一覧などで使う SF Symbol 名。
    var symbolName: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        }
    }
}
