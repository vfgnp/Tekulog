import Foundation
import CoreLocation

// `WalkSession` / `RoutePoint` の NSManagedObject クラスは
// Tekulog.xcdatamodeld の codeGenerationType="class" により自動生成される。
// ここではドメイン向けの便利アクセサのみを追加する。

extension WalkSession {
    /// 文字列で保存している活動種別を型安全に扱う。
    var activityKind: ActivityKind {
        get { ActivityKind(rawValue: activityTypeRaw ?? "") ?? .walking }
        set { activityTypeRaw = newValue.rawValue }
    }

    /// 文字列で保存している外出目的を型安全に扱う。`OutingClassifier` が確定時に設定し、
    /// ユーザーがチップで上書きすると `purposeIsUserSet` も立つ。
    var purpose: OutingPurpose {
        get { OutingPurpose(rawValue: purposeRaw ?? "") ?? .outing }
        set { purposeRaw = newValue.rawValue }
    }

    /// 記録時間(秒)。終了前は現在時刻までの経過。
    var duration: TimeInterval {
        let end = endedAt ?? Date()
        guard let start = startedAt else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    /// 時系列順のルート座標。地図描画・距離計算に使う。
    /// `points` は ordered リレーションなので NSOrderedSet。挿入順=時系列だが
    /// 念のため timestamp で安定ソートする。
    var orderedPoints: [RoutePoint] {
        let array = (points?.array as? [RoutePoint]) ?? []
        return array.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    /// 地図ポリライン用の座標配列。
    var coordinates: [CLLocationCoordinate2D] {
        orderedPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// ルートの自動命名(時間帯+種目):「朝の散歩」「夜のランニング」など。
    var autoName: String {
        let hour = Calendar.current.component(.hour, from: startedAt ?? Date())
        let timeLabel: String
        switch hour {
        case 5..<11: timeLabel = "朝"
        case 11..<15: timeLabel = "昼"
        case 15..<19: timeLabel = "夕方"
        default: timeLabel = "夜"
        }
        return "\(timeLabel)の\(activityKind.displayName)"
    }
}

extension RoutePoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
