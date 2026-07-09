import CoreLocation

extension CLLocationManager {
    /// バックグラウンド記録/生存のための共通設定(spec §5)。
    /// LocationAuthorization と BackgroundWakeService で共用し、設定ドリフトを防ぐ。
    func configureForBackgroundFitness() {
        allowsBackgroundLocationUpdates = true
        pausesLocationUpdatesAutomatically = false
        activityType = .fitness
    }
}

/// 位置情報の権限取得とステータス監視を担う。
/// liveUpdates 自体は権限要求をしないため、CLLocationManager で要求する。
@MainActor
final class LocationAuthorization: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.configureForBackgroundFitness()
    }

    /// 使用中許可を要求する。Always への昇格は使用中許可取得後に行う。
    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// 常時許可へ昇格を要求する(バックグラウンド自動記録に必要)。
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    var isAuthorized: Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    var hasAlways: Bool { status == .authorizedAlways }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in self.status = newStatus }
    }
}
