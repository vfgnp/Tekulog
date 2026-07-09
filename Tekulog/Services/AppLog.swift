import Foundation
import os

/// 実機での自動記録の挙動を裏取りするための診断ログ。
/// Console.app / `log stream --predicate 'subsystem == "com.vfgnp.Tekulog"'` で確認できる。
///
/// 調査が済んだら呼び出し側ごと削除してよい(記録挙動には影響しない)。
enum AppLog {
    private static let subsystem = "com.vfgnp.Tekulog"

    /// 活動検知(ActivityDetector)のライブ経路と評価判定。
    static let activity = Logger(subsystem: subsystem, category: "activity")
    /// セッションの開始/終了。
    static let session = Logger(subsystem: subsystem, category: "session")
    /// アプリのフォアグラウンド/バックグラウンド遷移。
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
