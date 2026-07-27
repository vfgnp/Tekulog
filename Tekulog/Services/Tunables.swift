import Foundation
import CoreLocation
import CoreMotion

/// 自動記録の挙動を決めるしきい値を一箇所に集約する。
/// 実機で歩いて/自転車に乗って調整する前提。SettingsView から一部を上書き可能にする想定。
enum Tunables {

    // MARK: - 開始条件(活動を継続検知したら記録開始)

    /// 開始判定に採用する CMMotionActivity の最低 confidence。
    static let minimumStartConfidence: CMMotionActivityConfidence = .medium

    /// 種別ごとの開始しきい時間。
    /// 家の広さ(玄関〜道路までの歩き出し距離)は人により異なり最適値も違うため、
    /// マイページで種別ごとに調整できる(未設定は `TekTheme.defaultStartDuration`)。
    /// `ActivityDetector.evaluate()` が毎評価で呼ぶので設定変更は次の判定から反映される。
    static func startDuration(for kind: ActivityKind) -> TimeInterval {
        let key: String
        switch kind {
        case .walking: key = TekTheme.Keys.startDurationWalking
        case .running: key = TekTheme.Keys.startDurationRunning
        case .cycling: key = TekTheme.Keys.startDurationCycling
        }
        let stored = UserDefaults.standard.object(forKey: key) as? Int ?? TekTheme.defaultStartDuration
        return TimeInterval(min(120, max(5, stored)))   // 不正値ガード(5〜120s)
    }

    // MARK: - 終了条件(移動が止まったら記録終了)

    /// stationary(休憩・立ち止まり)が継続したら記録を自動終了するまでの時間。
    static let stopDuration: TimeInterval = 3 * 60

    /// automotive(車・電車)を検知してから記録を終了するまでの猶予。
    /// 瞬間的な誤検知で散歩記録を切らないよう即時ではなく短い猶予を置く。
    static let vehicleStopDuration: TimeInterval = 60

    // MARK: - 評価間隔

    /// CMMotionActivity の更新が疎でもしきい時間経過を判定するための定期評価間隔。
    static let evaluationInterval: TimeInterval = 15

    /// ライブ検知(ActivityDetector.evaluate)が「生きている」とみなす鮮度。
    /// evaluate は evaluationInterval 毎に必ず動くため、これより古い =
    /// タイマーが凍結していた = アプリが suspend されていた、と判定できる。
    /// バックグラウンドウェイクの自動開始(sustained ゲートなしの即時再開)は
    /// この鮮度切れのときだけ許可する。evaluationInterval の数倍を取る。
    static let liveDetectionFreshWindow: TimeInterval = 60

    // MARK: - 位置取得(GPS)

    /// セッション中の希望精度。.fitness 用途のベスト。
    static let desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBestForNavigation

    /// この距離(m)以上移動するまで位置更新を間引く。バッテリー対策。
    static let distanceFilter: CLLocationDistance = 8

    /// 明らかに飛んだ精度の点を捨てる上限(m)。
    static let maxAcceptableHorizontalAccuracy: CLLocationDistance = 50

    /// GPSコールドスタート対策。開始直後は精度が収束するまで、通常より厳しい精度でのみ点を受理する。
    static let gpsWarmupAccuracy: CLLocationAccuracy = 20

    /// ウォームアップの上限時間(秒)。この時間内に高精度点が得られなければ通常基準(50m)にフォールバックする
    /// (市街地の谷間などで永久に空ルートにならないための保険)。
    static let gpsWarmupMaxDuration: TimeInterval = 20

    // MARK: - 候補バッファ(先行GPSバッファリング)

    /// 「歩行っぽい」候補検知〜sustained確定までの間、先行起動したGPS点を貯めるバッファの上限点数。
    /// distanceFilter=8m 固定下で、最大候補継続時間(startDuration上限120s + gpsWarmupMaxDuration 20s)
    /// を自転車の速い区間(~8-10m/s)で換算した点数に安全マージンを加えた値。
    /// 上限到達後は先頭(=確定時に startedAt として採用される最重要の点)を守るため、
    /// 新規サンプルの追加を止めるだけでバッファ自体は破棄しない。
    static let candidateBufferCap = 300

    /// 候補バッファ内の最新サンプルがこれより古ければ、GPS配信に途切れ(suspend等)があった
    /// とみなしバッファ全体を破棄する。suspend からの復帰は `ActivityDetector.evaluate()` の
    /// thaw検出と `SessionCoordinator.handleBackgroundWake()` の履歴照会という2経路があり、
    /// どちらが先に走るかは OS のスケジューリング次第で保証されない(既存コードの
    /// recoverAfterThaw のコメント参照)。thaw側の候補破棄より handleBackgroundWake が
    /// 先に確定処理へ進んだ場合の保険。`liveDetectionFreshWindow` と同程度の桁数を採用。
    static let candidateBufferMaxSampleAge: TimeInterval = 60

    // MARK: - アイドル中の生存(バックグラウンド常時起動)

    /// アイドル中(セッション外)にアプリを生かし続けるためのロケーション精度。
    /// ThreeKilometers はセル基地局主体の測位となり iOS がアプリを suspend してしまい、
    /// 生存線として機能しなかった(2026-07-09 実地ログ: ロック後約20秒で凍結)。
    /// HundredMeters は Wi-Fi 測位主体でセッションが実アクティブに保たれる。GPS チップは
    /// 基本温めないので消費は中程度。これでも凍結するなら kCLLocationAccuracyNearestTenMeters へ。
    static let idleKeepAliveAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters

    /// 生存用更新の配信間引き。「生存性は配信頻度に依存しない」は誤りだった —
    /// 500m に間引くと静止中は配信ゼロになり、更新セッションがアクティブでも
    /// iOS はアプリを suspend する(2026-07-10 実地ログ: ロック後 ~20秒〜数分で凍結、
    /// 目覚めは 500m 毎の配信時のみ = SLC と同等に退化)。配信そのものが生存線なので
    /// 間引かない。精度を上げても filter が粗いままでは静止中に配信されず直らない。
    static let idleKeepAliveDistanceFilter: CLLocationDistance = kCLDistanceFilterNone

    // MARK: - モチベーション(てくポイント/血流)

    /// 1歩あたりの基本ポイント。
    static let pointsPerStep: Double = 1
    /// ランニングセッション中の歩数に掛けるポイント倍率。
    static let runningPointMultiplier: Double = 2
    /// 歩数→活動分数の換算に使う仮定ケイデンス(歩/分)。
    static let assumedCadenceStepsPerMinute: Double = 100
    /// 歩行中の心拍出量(L/分)。安静時約5L/分に対する生理学的目安。
    static let cardiacOutputWalkingLitersPerMinute: Double = 11
    /// ランニング中の心拍出量(L/分)。
    static let cardiacOutputRunningLitersPerMinute: Double = 16
    /// 比喩換算に使うバスタブ1杯の容量(L)。
    static let bathtubLiters: Double = 200
    /// 血めぐりスコア(0〜100)の配点: 歩数の目標達成度ぶん。残りはランボーナス。
    static let scoreStepsWeight: Double = 80
    static let scoreRunBonusWeight: Double = 20
    /// ランボーナスが満点になる「1日歩数に占めるランセッション歩数」の比率。
    static let scoreRunShareForFullBonus: Double = 0.25

    // MARK: - 消費エネルギー推定

    /// 体重が取得できない場合のデフォルト体重(kg)。SettingsView で上書き想定。
    static let defaultBodyMassKg: Double = 60

    /// 種別ごとの MET(消費エネルギー = MET × 体重kg × 時間h)。
    static func metValue(for kind: ActivityKind) -> Double {
        switch kind {
        case .walking: return 3.5
        case .running: return 9.8
        case .cycling: return 6.0
        }
    }

    // MARK: - 永続化バッチ

    /// ルート点をまとめて Core Data に書き込むバッチサイズ。
    static let pointFlushBatchSize = 10

    /// バッチが溜まらなくても定期 flush する間隔(秒)。
    static let pointFlushInterval: TimeInterval = 20
}
