import Foundation
import CoreMotion

/// セッション中の歩数・距離・ペース・ケイデンスのスナップショット。
struct PedometerSnapshot: Sendable {
    var steps: Int = 0
    var distance: Double = 0        // メートル(歩行のみ。自転車では nil 相当の 0)
    var averagePace: Double = 0     // 秒/メートル
    var currentCadence: Double = 0  // 歩/秒

    /// 秒/km に変換したペース(0 のときは未算出)。
    var paceSecondsPerKm: Double { averagePace * 1000 }
}

/// CMPedometer で歩数・距離・ペースをライブ取得する。
/// 歩数計なので主に散歩で有効。自転車では距離は GPS 側を正とする。
@MainActor
final class PedometerService {

    @Published private(set) var snapshot = PedometerSnapshot()

    /// 更新のたびに通知(任意)。
    var onUpdate: ((PedometerSnapshot) -> Void)?

    private let pedometer = CMPedometer()
    private var isRunning = false

    static var isStepCountingAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    /// 指定時刻からの計測を開始する。
    func start(from startDate: Date) {
        guard Self.isStepCountingAvailable, !isRunning else { return }
        isRunning = true
        snapshot = PedometerSnapshot()
        pedometer.startUpdates(from: startDate) { [weak self] data, _ in
            guard let data else { return }
            let snapshot = Self.makeSnapshot(from: data)
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    /// 計測を停止し、最終スナップショットを返す。
    @discardableResult
    func stop() -> PedometerSnapshot {
        guard isRunning else { return snapshot }
        isRunning = false
        pedometer.stopUpdates()
        return snapshot
    }

    private func apply(_ snapshot: PedometerSnapshot) {
        self.snapshot = snapshot
        onUpdate?(snapshot)
    }

    private static func makeSnapshot(from data: CMPedometerData) -> PedometerSnapshot {
        PedometerSnapshot(
            steps: data.numberOfSteps.intValue,
            distance: data.distance?.doubleValue ?? 0,
            averagePace: data.averageActivePace?.doubleValue ?? 0,
            currentCadence: data.currentCadence?.doubleValue ?? 0
        )
    }
}
