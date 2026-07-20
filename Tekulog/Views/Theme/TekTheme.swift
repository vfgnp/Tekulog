import SwiftUI

/// Claude Design モック(Teklog.dc.html)から抽出したデザイントークン。
/// ライト固定の世界観(root で .preferredColorScheme(.light))。
enum TekTheme {
    // MARK: 色
    static let primary = Color(hex: 0x18B368)
    static let primaryDark = Color(hex: 0x0C7A48)
    static let primaryPale = Color(hex: 0xE7F6EE)
    static let paleGreen = Color(hex: 0xA6E3C4)
    static let coral = Color(hex: 0xFF6F61)
    static let coralLight = Color(hex: 0xFF8A6B)
    static let coralPale = Color(hex: 0xFFEEEB)
    static let background = Color(hex: 0xF3F6F1)
    static let ink = Color(hex: 0x232B26)
    static let sub = Color(hex: 0x8A938C)
    static let faint = Color(hex: 0xA8B0AA)
    static let disabled = Color(hex: 0xC5CCC6)
    static let hairline = Color(hex: 0xEEF1EC)
    static let amber = Color(hex: 0xF5A623)
    static let amberPale = Color(hex: 0xFFF2D9)
    static let blue = Color(hex: 0x5B8DEF)
    static let bluePale = Color(hex: 0xEAF0FB)

    /// カードの柔らかい影。
    static let cardShadow = Color(hex: 0x232B26).opacity(0.06)

    // MARK: AppStorage キー
    enum Keys {
        static let nickname = "nickname"
        static let stepGoal = "stepGoal"
        static let autoRecordEnabled = "autoRecordEnabled"
        static let gpsHighAccuracy = "gpsHighAccuracy"
    }
    /// 歩数目標の既定値。
    static let defaultStepGoal = 10_000
}

extension Color {
    /// 0xRRGGBB からの生成。
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// 数値表示用の丸み(SF Rounded)。デザインの M PLUS Rounded の代用。
    static func tekNumber(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
