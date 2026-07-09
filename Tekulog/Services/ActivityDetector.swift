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

    /// ライブ検知が最後に動いた時刻(evaluate 実行時に更新)。evaluationTimer は
    /// 15 秒毎に回るので、これが古い = タイマーが凍結していた = アプリが suspend
    /// されていた証拠になる。バックグラウンドウェイク経路がライブ検知と競合しない
    /// よう、この鮮度で「生きているか」を判定する。
    private(set) var lastEvaluatedAt: Date?

    /// 最後に setMode した時刻。活動セグメントの startDate はモード変更より
    /// 前に遡り得る(継続中のセグメント)ため、経過時間の起点はこの時刻で
    /// クランプする。これがないと「手動開始直後に古い stationary セグメントで
    /// 即・自動停止」「起動直後に古い walking セグメントで即・自動開始」が起きる。
    private var modeChangedAt = Date()

    private let manager = CMMotionActivityManager()
    private var evaluationTimer: Timer?

    /// 直近に観測した「記録対象の活動種別」と、その状態が始まった時刻。
    private var movingKind: ActivityKind?
    private var movingSince: Date?

    /// 直近に観測した「停止(stationary=休憩・立ち止まり)」が始まった時刻。
    private var stoppedSince: Date?

    /// 直近に観測した「automotive(車・電車)」が始まった時刻。記録から除外するため
    /// stationary とは別管理し、短い猶予で終了させる。
    private var automotiveSince: Date?

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    /// 監視を開始する。アプリ起動時 / 権限取得後に呼ぶ。
    func start() {
        guard Self.isAvailable else {
            AppLog.activity.error("start: CMMotionActivity 利用不可(端末非対応/権限なし)")
            return
        }
        AppLog.activity.notice("start: 活動更新の監視開始 mode=\(String(describing: self.mode), privacy: .public)")
        // ハンドラは @MainActor 隔離。メインキューで受けることで「期待 executor=メイン /
        // 実行=バックグラウンド」の不一致による Swift 6 ランタイム SIGTRAP を回避する。
        // 活動種別の更新は状態変化時のみで低頻度なのでメイン実行で問題ない。
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            self?.handle(activity)
        }
        startEvaluationTimer()
    }

    func stop() {
        AppLog.activity.notice("stop: 活動更新の監視停止")
        manager.stopActivityUpdates()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }

    /// 直近 `minutes` 分の活動履歴を照会する共通ボイラープレート(可用性ガード +
    /// エラーハンドリング + アンラップ)。失敗時は空配列で completion を呼ぶ。
    /// クロージャは別キューで呼ばれ得るので .main 受け(Swift 6 対応)。
    private func queryRecentActivities(minutes: Double,
                                       label: String,
                                       completion: @escaping ([CMMotionActivity]) -> Void) {
        guard Self.isAvailable else {
            AppLog.activity.error("\(label, privacy: .public): CMMotionActivity 利用不可")
            completion([])
            return
        }
        let now = Date()
        AppLog.activity.notice("\(label, privacy: .public): 直近\(Int(minutes), privacy: .public)分の活動履歴を照会")
        manager.queryActivityStarting(from: now.addingTimeInterval(-minutes * 60), to: now, to: .main) { activities, error in
            if let error {
                AppLog.activity.error("\(label, privacy: .public): 照会失敗 \(error.localizedDescription, privacy: .public)")
                completion([])
                return
            }
            completion(activities ?? [])
        }
    }

    /// 調査ログ用の短い活動種別ラベル。
    private nonisolated static func shortLabel(_ a: CMMotionActivity) -> String {
        if a.walking { return "walk" }
        if a.cycling { return "cycle" }
        if a.automotive { return "auto" }
        if a.stationary { return "stat" }
        if a.unknown { return "unknown" }
        return "?"
    }

    /// 開始判定に足る confidence か。ライブ検知(handle)と履歴検知(detectOngoingActivity)で共用。
    private nonisolated static func isConfident(_ a: CMMotionActivity) -> Bool {
        a.confidence.rawValue >= Tunables.minimumStartConfidence.rawValue
    }

    /// 直近 `minutes` 分の活動履歴を遡って取得しログに列挙する(調査用)。
    /// suspend 中にライブ更新が途切れていても、Core Motion 側は履歴を保持しているため、
    /// 「権限はあり Core Motion は歩行を記録していたが、ライブ検知が動いていなかった」を
    /// フォアグラウンド復帰時に裏取りできる。
    func logRecentHistory(minutes: Int = 20) {
        queryRecentActivities(minutes: Double(minutes), label: "history") { activities in
            AppLog.activity.notice("history: \(activities.count, privacy: .public)件")
            for a in activities {
                AppLog.activity.notice("""
                history: \(Self.shortLabel(a), privacy: .public) conf=\(a.confidence.rawValue, privacy: .public) \
                start=\(a.startDate.timeIntervalSince1970, privacy: .public)
                """)
            }
        }
    }

    /// 直近履歴を見て、現在継続中の記録対象活動があれば種別を返す(バックグラウンドウェイク用)。
    /// 最後のセグメントが walking/cycling で confidence が十分なら、その種別を返す。
    /// 最後のセグメントが stationary/automotive ならもう動いていないとみなし nil を返す。
    ///
    /// 注意: これは「suspend/終了からの復帰」専用のリカバリ経路で、ライブ検知の
    /// sustained(startDuration)ゲートを持たない。呼び出し側(SessionCoordinator)が
    /// `lastEvaluatedAt` の鮮度でライブ検知の生死を確認し、生きている間は呼ばないこと。
    func detectOngoingActivity(completion: @escaping (ActivityKind?) -> Void) {
        queryRecentActivities(minutes: 5, label: "detectOngoingActivity") { activities in
            guard let last = activities.last else {
                AppLog.activity.notice("detectOngoingActivity: 履歴なし")
                completion(nil)
                return
            }
            if let kind = ActivityKind(motionActivity: last), Self.isConfident(last) {
                AppLog.activity.notice("detectOngoingActivity: kind=\(kind.rawValue, privacy: .public) を検知")
                completion(kind)
            } else {
                AppLog.activity.notice("detectOngoingActivity: 移動中でない(最終セグメントが stationary/automotive/低confidence)")
                completion(nil)
            }
        }
    }

    /// セッション開始/終了が確定したら Coordinator から内部状態を同期する。
    func setMode(_ newMode: Mode) {
        mode = newMode
        modeChangedAt = Date()
        movingKind = nil
        movingSince = nil
        stoppedSince = nil
        automotiveSince = nil
    }

    // MARK: - 内部

    private func handle(_ activity: CMMotionActivity) {
        let confident = Self.isConfident(activity)

        // ライブ更新が届いた = この瞬間アプリは前面 or 何らかの理由で実行中。
        // suspend されているとこのログ自体が出ない(=検知が動いていない証拠になる)。
        AppLog.activity.notice("""
        handle: walk=\(activity.walking, privacy: .public) cycle=\(activity.cycling, privacy: .public) \
        auto=\(activity.automotive, privacy: .public) stat=\(activity.stationary, privacy: .public) \
        unknown=\(activity.unknown, privacy: .public) conf=\(activity.confidence.rawValue, privacy: .public) \
        confident=\(confident, privacy: .public)
        """)

        // セグメントの startDate はモード変更前まで遡り得るため modeChangedAt で
        // クランプする(手動開始直後の古い stationary で即・自動停止しない /
        // 起動直後の古い walking で sustained 判定を飛ばさない)。
        let clampedStart = max(activity.startDate, modeChangedAt)

        if let kind = ActivityKind(motionActivity: activity), confident {
            // 散歩 / 自転車を観測。
            if movingKind != kind {
                movingKind = kind
                movingSince = clampedStart
            }
            stoppedSince = nil
            automotiveSince = nil
        } else if activity.automotive {
            // 車・電車。記録対象外。stationary より優先して扱い、短い猶予で終了させる。
            if automotiveSince == nil {
                automotiveSince = clampedStart
            }
            movingKind = nil
            movingSince = nil
            stoppedSince = nil
        } else if activity.stationary {
            // 停止(休憩・立ち止まり)。
            if stoppedSince == nil {
                stoppedSince = clampedStart
            }
            movingKind = nil
            movingSince = nil
            automotiveSince = nil
        }
        // unknown / 低 confidence は状態を据え置き(ノイズで状態を壊さない)。

        evaluate()
    }

    private func evaluate(now: Date = Date()) {
        // suspend 解凍の検出。evaluationTimer は evaluationInterval 毎に必ず動くため、
        // 前回からこれほど空く = タイマーが凍結していた(= suspend されていた)。
        // 凍結中の …Since は現状を反映しないので捨て、クランプ起点(modeChangedAt)も
        // 今に進める。これがないと、解凍一発目の evaluate や直後の handle が何十分も
        // 前の startDate を使って sustained ゲートを素通りし、外出の終わり際に無意味な
        // セッションを開始する(2026-07-09 実地ログ: elapsed=4805s で暴発)。
        // 進行中の活動の拾い直しは履歴照会(recoverAfterThaw)が担う。
        if let last = lastEvaluatedAt, now.timeIntervalSince(last) > Tunables.liveDetectionFreshWindow {
            AppLog.activity.notice("evaluate: suspend 解凍を検知(空白 \(Int(now.timeIntervalSince(last)), privacy: .public)s) → 状態リセット+履歴照会")
            movingKind = nil
            movingSince = nil
            stoppedSince = nil
            automotiveSince = nil
            modeChangedAt = now
            lastEvaluatedAt = now
            recoverAfterThaw()
            return
        }
        // ライブ検知の生存証明(タイマー凍結 = suspend の検出に使う)。
        lastEvaluatedAt = now
        switch mode {
        case .idle:
            guard let kind = movingKind, let since = movingSince else { return }
            let elapsed = now.timeIntervalSince(since)
            let threshold = Tunables.startDuration(for: kind)
            AppLog.activity.notice("""
            evaluate(idle): kind=\(kind.rawValue, privacy: .public) \
            elapsed=\(Int(elapsed), privacy: .public)s / threshold=\(Int(threshold), privacy: .public)s
            """)
            if elapsed >= threshold {
                AppLog.activity.notice("evaluate: → onShouldStart(\(kind.rawValue, privacy: .public))")
                setMode(.tracking)
                onShouldStart?(kind)
            }
        case .tracking:
            // 車・電車は短い猶予で終了(乗り換え区間を記録しない)。stationary より先に判定。
            if let since = automotiveSince,
               now.timeIntervalSince(since) >= Tunables.vehicleStopDuration {
                AppLog.activity.notice("evaluate: → onShouldStop(automotive)")
                setMode(.idle)
                onShouldStop?(since)
                return
            }
            // 休憩・立ち止まりは stopDuration 経過で終了。
            if let since = stoppedSince,
               now.timeIntervalSince(since) >= Tunables.stopDuration {
                AppLog.activity.notice("evaluate: → onShouldStop(stationary)")
                setMode(.idle)
                onShouldStop?(since)
            }
        }
    }

    /// suspend 解凍直後のリカバリ。ライブ検知の状態は捨てた直後なので、進行中の
    /// 散歩/自転車があれば履歴照会で拾い、sustained ゲートなしで即時再開する
    /// (`handleBackgroundWake` と同じ思想。あちらは onWake が解凍後の evaluate より
    /// 遅れて届くと lastEvaluatedAt が新しく見えて動かないため、解凍側でも行う)。
    private func recoverAfterThaw() {
        guard mode == .idle else { return }
        detectOngoingActivity { [weak self] kind in
            guard let self, let kind, self.mode == .idle else { return }
            AppLog.activity.notice("recoverAfterThaw: kind=\(kind.rawValue, privacy: .public) → 即時再開")
            self.setMode(.tracking)
            self.onShouldStart?(kind)
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
