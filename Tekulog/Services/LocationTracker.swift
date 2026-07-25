import CoreLocation

/// セッション中のみ GPS を回し、ルート点を流すトラッカー。
///
/// **古典的 `CLLocationManager` + `startUpdatingLocation()` を使う**(iOS 17 の
/// `CLLocationUpdate.liveUpdates()` ではない)。実地ログ(2026-07-19 解析)で、
/// **ロック中に自動開始したセッションでは liveUpdates が背景で1点も配信しない**ことが
/// 判明した(プロセス自体は keep-alive で生存し 30 秒ごとにログが出ていたのに、ルート点は
/// フォアグラウンド復帰後の数十秒ぶんのみ。07-13〜16 の全セッションが 0 点だったのも同根)。
/// 最有力の機序: `CLBackgroundActivitySession` は**フォアグラウンドで生成しないと効力を
/// 持たない**(Apple 文書化仕様)ため、ロック中の自動開始 = 背景生成では背景配信の資格が
/// 得られない。並行する keep-alive の古典マネージャとの競合の可能性も排除はできないが、
/// いずれにせよ古典マネージャは同条件で背景配信できることが実証済みなので、こちらに揃える。
///
/// バックグラウンド配信は `configureForBackgroundFitness()` の
/// `allowsBackgroundLocationUpdates = true` が担う(CLBackgroundActivitySession は不要。
/// 背景で start しても機能する — BackgroundWakeService の SLC relaunch 経路で実証済み)。
@MainActor
final class LocationTracker: NSObject, CLLocationManagerDelegate {

    /// 受理したルート点を通知する。
    var onSample: ((RouteSample) -> Void)?

    private(set) var isTracking = false

    private let manager = CLLocationManager()

    /// start() した時刻。古典マネージャは開始直後に**キャッシュされた古い位置**
    /// (数分〜数十分前の座標)を即配信することがあり、混入すると開始地点のスパイクと
    /// 距離水増しになるため、これより古いタイムスタンプの点は捨てる。
    private var startedTrackingAt: Date?

    /// ウォームアップ完了フラグ。開始直後(GPSチップが冷えている間)は精度が悪くブレた点が届くため、
    /// 最初の高精度点を受理するまで(または上限時間まで)は厳しめ精度で判定する。
    private var warmedUp = false

    override init() {
        super.init()
        manager.delegate = self
        // バックグラウンド配信・静止中も止めないための共通設定。
        manager.configureForBackgroundFitness()
        manager.distanceFilter = Tunables.distanceFilter
    }

    /// GPS セッションを開始する。
    func start() {
        guard !isTracking else { return }
        isTracking = true
        startedTrackingAt = Date()
        warmedUp = false
        // 精度設定(マイページ)は開始時に読む。高=ナビ用ベスト/標準=10m 級で省電力。
        let high = UserDefaults.standard.object(forKey: TekTheme.Keys.gpsHighAccuracy) as? Bool ?? true
        manager.desiredAccuracy = high ? Tunables.desiredAccuracy : kCLLocationAccuracyNearestTenMeters
        manager.startUpdatingLocation()
    }

    /// GPS セッションを停止する。停止検知時に必ず呼んでバッテリーを守る。
    func stop() {
        isTracking = false
        startedTrackingAt = nil
        warmedUp = false
        manager.stopUpdatingLocation()
    }

    // Core Location のデリゲートは別キューで呼ばれ得るため nonisolated 受けし、
    // メインへホップする(Swift 6 の @MainActor 隔離違反を避けるパターン。
    // BackgroundWakeService と同様)。
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                guard self.isTracking else { break }
                guard self.isAcceptable(location) else { continue }
                self.onSample?(RouteSample(location: location))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            AppLog.session.error("LocationTracker: エラー \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 精度が悪すぎる/座標が無効/開始前のキャッシュ点を捨てる。
    /// さらに開始直後は、GPS精度が収束するまでのブレた点(コールドスタート)をウォームアップ・ゲートで捨てる。
    private func isAcceptable(_ location: CLLocation) -> Bool {
        // 座標妥当性 + 開始前のキャッシュ位置(startUpdatingLocation 直後に届く古い点)を除外。
        guard location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate),
              let startedAt = startedTrackingAt,
              location.timestamp >= startedAt else {
            return false
        }
        if !warmedUp {
            // 最初の高精度点を受理するまで(または上限時間経過まで)は厳しめ精度で判定する。
            // 収束しなければ通常基準(50m)へフォールバックして空ルートを避ける。
            let elapsed = location.timestamp.timeIntervalSince(startedAt)
            let limit = elapsed < Tunables.gpsWarmupMaxDuration
                ? Tunables.gpsWarmupAccuracy
                : Tunables.maxAcceptableHorizontalAccuracy
            guard location.horizontalAccuracy <= limit else { return false }
            warmedUp = true
            return true
        }
        return location.horizontalAccuracy <= Tunables.maxAcceptableHorizontalAccuracy
    }
}
