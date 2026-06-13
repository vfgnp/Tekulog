import CoreLocation

/// セッション中のみ高精度 GPS を回し、ルート点を流すトラッカー。
/// iOS 17+ の `CLLocationUpdate.liveUpdates()`(async sequence)を使用する。
/// バックグラウンドでも更新を継続するため `CLBackgroundActivitySession` を保持する。
@MainActor
final class LocationTracker {

    /// 受理したルート点を通知する。
    var onSample: ((RouteSample) -> Void)?

    private(set) var isTracking = false

    private var updatesTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?

    /// GPS セッションを開始する。
    func start() {
        guard !isTracking else { return }
        isTracking = true

        // バックグラウンドでも liveUpdates を継続させる。
        backgroundSession = CLBackgroundActivitySession()

        updatesTask = Task { [weak self] in
            await self?.consumeUpdates()
        }
    }

    /// GPS セッションを停止する。停止検知時に必ず呼んでバッテリーを守る。
    func stop() {
        isTracking = false
        updatesTask?.cancel()
        updatesTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    private func consumeUpdates() async {
        do {
            let updates = CLLocationUpdate.liveUpdates(.fitness)
            for try await update in updates {
                if Task.isCancelled { break }
                guard let location = update.location else { continue }
                guard isAcceptable(location) else { continue }
                onSample?(RouteSample(location: location))
            }
        } catch {
            // 権限失効・一時停止など。トラッキング状態を畳む。
            isTracking = false
        }
    }

    /// 精度が悪すぎる/座標が無効な点を捨てる。
    private func isAcceptable(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Tunables.maxAcceptableHorizontalAccuracy else {
            return false
        }
        return CLLocationCoordinate2DIsValid(location.coordinate)
    }
}
