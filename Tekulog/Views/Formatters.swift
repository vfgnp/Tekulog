import Foundation

/// 表示用フォーマッタ群。
enum Formatters {

    /// 距離(m)→「1.23 km」/「840 m」。
    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    /// 時間(秒)→「1:23:45」/「12:05」。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// 平均ペース(秒/メートル)→「12'30\"/km」。0 は「--」。
    static func pace(secondsPerMeter: Double) -> String {
        guard secondsPerMeter > 0 else { return "--" }
        let secPerKm = secondsPerMeter * 1000
        let m = Int(secPerKm) / 60
        let s = Int(secPerKm) % 60
        return String(format: "%d'%02d\"/km", m, s)
    }

    /// 歩数→「2,850 歩」。
    static func steps(_ count: Int) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return "\(formatted) 歩"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E) HH:mm"
        return f
    }()

    static func dateTime(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E)"
        return f
    }()

    /// 日付のみ→「7月11日(金)」。日別セクション/日別まとめ用。
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 時刻のみ→「08:23」。タイムラインの開始–終了表示用。
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
