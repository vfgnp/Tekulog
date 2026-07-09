import Foundation
import CoreLocation

/// アイドル中(セッション外)も常時回る、アプリを生かし続ける生存層。
///
/// 二段構え:
///  1. 連続 `startUpdatingLocation()`(低精度) — アプリを suspend させず走らせ続ける。
///     これによりロック中も `ActivityDetector` の CMMotionActivity ライブ検知と評価
///     タイマーが凍結せず、SLC の約500m を待たずに散歩/自転車を自動開始できる。
///     低精度(ThreeKilometers)なのでセル/Wi-Fi 主体＝GPS チップは温めず低消費。
///  2. `startMonitoringSignificantLocationChanges()` — アプリが強制終了/メモリ回収
///     された後に OS が relaunch してくれるセーフティネット。
///
/// GPS(CLBackgroundActivitySession)はセッション中にしか使わないため、アイドル中の
/// 生存はこの層が担う。いずれも常時許可(Always)がないと機能しない。
@MainActor
final class BackgroundWakeService: NSObject, CLLocationManagerDelegate {

    /// 位置更新が届いた(=起こされた/生きている)とき。終了後 relaunch 時の
    /// `handleBackgroundWake` バックアップ経路を兼ねる。
    var onWake: (() -> Void)?

    private let manager = CLLocationManager()

    /// 連続更新で `onWake` が過剰発火しないよう、最短発火間隔を設ける。
    private var lastWakeAt: Date?
    private let wakeThrottle: TimeInterval = 30

    /// start() 済みか。権限が後から Always に変わったときの再起動判定に使う。
    private var wantsMonitoring = false

    override init() {
        super.init()
        manager.delegate = self
        // バックグラウンド起動・生存のための共通設定。
        // pausesLocationUpdatesAutomatically=false が「静止しても更新を止めない
        // =suspend されない」生存の要。
        manager.configureForBackgroundFitness()
        // アイドル生存は低精度で十分(点は使わない)。消費を抑える。
        manager.desiredAccuracy = Tunables.idleKeepAliveAccuracy
        manager.distanceFilter = Tunables.idleKeepAliveDistanceFilter
    }

    /// 生存監視を開始する。常時許可がないと機能しない(許可が後から付与された場合は
    /// `locationManagerDidChangeAuthorization` が再起動する)。
    func start() {
        wantsMonitoring = true
        AppLog.activity.notice("BackgroundWakeService: 常時生存(連続更新+SLC)開始")
        // 連続更新でアプリを生かし続ける(主経路)。
        manager.startUpdatingLocation()
        // 終了後 relaunch のセーフティネット。
        manager.startMonitoringSignificantLocationChanges()
    }

    func stop() {
        wantsMonitoring = false
        AppLog.activity.notice("BackgroundWakeService: 常時生存 停止")
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
    }

    // Core Location のデリゲートは別キューで呼ばれ得るため nonisolated 受けし、
    // メインへホップする(Swift 6 の @MainActor 隔離違反を避けるパターン。
    // LocationAuthorization.swift と同様)。
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            // 連続更新で頻発し得るのでスロットル。生存の主目的(＝アプリが走り続ける)は
            // ここを通らなくても達成される。onWake は終了後 relaunch のバックアップ。
            let now = Date()
            if let last = self.lastWakeAt, now.timeIntervalSince(last) < self.wakeThrottle {
                return
            }
            self.lastWakeAt = now
            AppLog.activity.notice("BackgroundWakeService: 位置更新で起床/生存確認")
            self.onWake?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            AppLog.activity.error("BackgroundWakeService: エラー \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 権限変化への追従。オンボーディングは拒否でも先へ進めるため、start() 時点で
    /// Always が無いことがある。後から設定アプリで Always が付与されたときに
    /// ここで監視を再起動しないと、生存線が黙って死んだままになる。
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            AppLog.activity.notice("BackgroundWakeService: 権限変化 status=\(status.rawValue, privacy: .public)")
            guard self.wantsMonitoring else { return }
            if status == .authorizedAlways {
                // 冪等: 既に動いていても start し直して害はない。
                self.manager.startUpdatingLocation()
                self.manager.startMonitoringSignificantLocationChanges()
                AppLog.activity.notice("BackgroundWakeService: Always 付与 → 生存監視を再起動")
            } else {
                AppLog.activity.error("BackgroundWakeService: Always 権限なし(バックグラウンド生存は機能しない)")
            }
        }
    }
}
