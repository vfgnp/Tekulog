import Foundation
import CoreLocation
import CoreMotion

/// 自動記録の挙動を決めるしきい値を一箇所に集約する。
/// 実機で歩いて/自転車に乗って調整する前提。SettingsView から一部を上書き可能にする想定。
enum Tunables {

    // MARK: - 開始条件(活動を継続検知したら記録開始)

    /// 散歩(walking)を連続検知して記録を開始するまでの時間。
    static let walkingStartDuration: TimeInterval = 3 * 60

    /// 自転車(cycling)を連続検知して記録を開始するまでの時間。
    /// 自転車は短時間で距離が出るため walking より短く。
    static let cyclingStartDuration: TimeInterval = 2 * 60

    /// 開始判定に採用する CMMotionActivity の最低 confidence。
    static let minimumStartConfidence: CMMotionActivityConfidence = .medium

    /// 種別ごとの開始しきい時間。
    static func startDuration(for kind: ActivityKind) -> TimeInterval {
        switch kind {
        case .walking: return walkingStartDuration
        case .cycling: return cyclingStartDuration
        }
    }

    // MARK: - 終了条件(移動が止まったら記録終了)

    /// stationary(休憩・立ち止まり)が継続したら記録を自動終了するまでの時間。
    static let stopDuration: TimeInterval = 10 * 60

    /// automotive(車・電車)を検知してから記録を終了するまでの猶予。
    /// 瞬間的な誤検知で散歩記録を切らないよう即時ではなく短い猶予を置く。
    static let vehicleStopDuration: TimeInterval = 60

    // MARK: - 評価間隔

    /// CMMotionActivity の更新が疎でもしきい時間経過を判定するための定期評価間隔。
    static let evaluationInterval: TimeInterval = 15

    // MARK: - 位置取得(GPS)

    /// セッション中の希望精度。.fitness 用途のベスト。
    static let desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBestForNavigation

    /// この距離(m)以上移動するまで位置更新を間引く。バッテリー対策。
    static let distanceFilter: CLLocationDistance = 8

    /// 明らかに飛んだ精度の点を捨てる上限(m)。
    static let maxAcceptableHorizontalAccuracy: CLLocationDistance = 50

    // MARK: - 消費エネルギー推定

    /// 体重が取得できない場合のデフォルト体重(kg)。SettingsView で上書き想定。
    static let defaultBodyMassKg: Double = 60

    /// 種別ごとの MET(消費エネルギー = MET × 体重kg × 時間h)。
    static func metValue(for kind: ActivityKind) -> Double {
        switch kind {
        case .walking: return 3.5
        case .cycling: return 6.0
        }
    }

    // MARK: - 永続化バッチ

    /// ルート点をまとめて Core Data に書き込むバッチサイズ。
    static let pointFlushBatchSize = 10

    /// バッチが溜まらなくても定期 flush する間隔(秒)。
    static let pointFlushInterval: TimeInterval = 20
}
