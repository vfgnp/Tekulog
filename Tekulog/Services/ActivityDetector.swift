import Foundation
import CoreMotion

/// Core Motion の活動種別を監視し、「散歩/自転車を継続検知 → 開始すべき」
/// 「停止/車移動が継続 → 終了すべき」というイベントを発火する低消費電力トリガー層。
///
/// CMMotionActivity の更新は状態変化時にしか届かないため、しきい時間の経過は
/// 定期評価タイマー(`Tunables.evaluationInterval`)で判定する。
@MainActor
final class ActivityDetector {

    enum Mode {
        case idle      // セッション外。開始検知を待つ。
        case tracking  // セッション中。終了検知を待つ。
    }

    /// 記録を開始すべき種別を検知したとき。
    var onShouldStart: ((ActivityKind) -> Void)?
    /// 記録を終了すべきと判定したとき。引数は「動きが止まった時刻」(停止が始まった時刻)。
    var onShouldStop: ((Date) -> Void)?

    private(set) var mode: Mode = .idle

    private let manager = CMMotionActivityManager()
    private let queue = OperationQueue()
    private var evaluationTimer: Timer?

    /// 直近に観測した「記録対象の活動種別」と、その状態が始まった時刻。
    private var movingKind: ActivityKind?
    private var movingSince: Date?

    /// 直近に観測した「停止相当(stationary / automotive / 不明)」が始まった時刻。
    private var stoppedSince: Date?

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    /// 監視を開始する。アプリ起動時 / 権限取得後に呼ぶ。
    func start() {
        guard Self.isAvailable else { return }
        manager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor in self?.handle(activity) }
        }
        startEvaluationTimer()
    }

    func stop() {
        manager.stopActivityUpdates()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }

    /// セッション開始/終了が確定したら Coordinator から内部状態を同期する。
    func setMode(_ newMode: Mode) {
        mode = newMode
        movingKind = nil
        movingSince = nil
        stoppedSince = nil
    }

    // MARK: - 内部

    private func handle(_ activity: CMMotionActivity) {
        let confident = activity.confidence.rawValue >= Tunables.minimumStartConfidence.rawValue

        if let kind = ActivityKind(motionActivity: activity), confident {
            // 散歩 / 自転車を観測。
            if movingKind != kind {
                movingKind = kind
                movingSince = activity.startDate
            }
            stoppedSince = nil
        } else if activity.stationary || activity.automotive {
            // 停止 or 車・電車。記録対象外。
            if stoppedSince == nil {
                stoppedSince = activity.startDate
            }
            movingKind = nil
            movingSince = nil
        }
        // unknown / 低 confidence は状態を据え置き(ノイズで状態を壊さない)。

        evaluate()
    }

    private func evaluate(now: Date = Date()) {
        switch mode {
        case .idle:
            guard let kind = movingKind, let since = movingSince else { return }
            if now.timeIntervalSince(since) >= Tunables.startDuration(for: kind) {
                setMode(.tracking)
                onShouldStart?(kind)
            }
        case .tracking:
            guard let since = stoppedSince else { return }
            if now.timeIntervalSince(since) >= Tunables.stopDuration {
                // setMode が stoppedSince を nil クリアする前に停止時刻を退避。
                let stoppedAt = since
                setMode(.idle)
                onShouldStop?(stoppedAt)
            }
        }
    }

    private func startEvaluationTimer() {
        evaluationTimer?.invalidate()
        let timer = Timer(timeInterval: Tunables.evaluationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // 共通モードでスクロール中等でも発火。
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }
}
