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

    /// 記録時間(秒)。終了前は現在時刻までの経過。
    var duration: TimeInterval {
        let end = endedAt ?? Date()
        guard let start = startedAt else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    /// 時系列順のルート座標。地図描画・距離計算に使う。
    var orderedPoints: [RoutePoint] {
        let set = points as? Set<RoutePoint> ?? []
        return set.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    /// 地図ポリライン用の座標配列。
    var coordinates: [CLLocationCoordinate2D] {
        orderedPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

extension RoutePoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
