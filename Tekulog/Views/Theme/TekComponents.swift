import SwiftUI

// Claude Design モックの共通ビジュアル部品。

/// 白カード(角丸+柔らかい影)。
struct TekCard<Content: View>: View {
    var radius: CGFloat = 24
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: radius))
            .shadow(color: TekTheme.cardShadow, radius: 12, y: 6)
    }
}

/// 小さな統計タイル(タイトル+大きい数値+単位)。
struct StatTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var valueColor: Color = TekTheme.ink

    var body: some View {
        TekCard(radius: 18, padding: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TekTheme.sub)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.tekNumber(22))
                        .foregroundStyle(valueColor)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TekTheme.sub)
                    }
                }
            }
        }
    }
}

/// セクション見出し(小さいグレー太字)。
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(TekTheme.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// 横棒プログレスバー。
struct TekProgressBar: View {
    let fraction: Double
    var tint: Color = .white
    var track: Color = .white.opacity(0.3)
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// 歩数リング(円弧ゲージ)。
struct RingGauge: View {
    let progress: Double     // 0...1
    var size: CGFloat = 196
    var lineWidth: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .stroke(TekTheme.primaryPale, lineWidth: lineWidth)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: min(1, progress))
                    .stroke(TekTheme.primary,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: progress)
            }
        }
        .frame(width: size, height: size)
    }
}

/// マスコット(コーラルの丸顔)。モックのアバターをシェイプで再現。
struct MascotView: View {
    var size: CGFloat = 52
    /// レベルヒーロー等、緑地に置くときは白目スタイル。
    var onDark: Bool = false

    var body: some View {
        let face = onDark ? Color.white.opacity(0.2) : TekTheme.coral
        let feature = onDark ? Color.white : Color(hex: 0x2B2B2B)
        ZStack {
            Circle().fill(face)
            // 目
            HStack(spacing: size * 0.24) {
                Ellipse().fill(feature).frame(width: size * 0.12, height: size * 0.16)
                Ellipse().fill(feature).frame(width: size * 0.12, height: size * 0.16)
            }
            .offset(y: -size * 0.04)
            // 口(下向きの弧)
            Circle()
                .trim(from: 0.05, to: 0.45)
                .stroke(feature, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round))
                .frame(width: size * 0.24, height: size * 0.24)
                .offset(y: size * 0.1)
            // 頬
            if !onDark {
                HStack(spacing: size * 0.52) {
                    Ellipse().fill(Color(hex: 0xFF9D93)).frame(width: size * 0.16, height: size * 0.1)
                    Ellipse().fill(Color(hex: 0xFF9D93)).frame(width: size * 0.16, height: size * 0.1)
                }
                .offset(y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: onDark ? .clear : TekTheme.coral.opacity(0.35), radius: 7, y: 3)
    }
}

/// 外出目的ごとのアイコン色・背景色。ログ一覧・分類チップなど複数箇所で共通に使う。
extension OutingPurpose {
    var tekColors: (icon: Color, background: Color) {
        switch self {
        case .commute: return (TekTheme.blue, TekTheme.bluePale)
        case .walk: return (TekTheme.primary, TekTheme.primaryPale)
        case .run: return (TekTheme.coral, TekTheme.coralPale)
        case .outing: return (Color(hex: 0x8A6BB0), Color(hex: 0xEBE2F3))
        case .shopping: return (TekTheme.amber, TekTheme.amberPale)
        }
    }
}

/// 週間の外出目的サマリー(割合バー+件数つき凡例)。ホーム画面で使用。
struct WeeklyPurposeBar: View {
    struct Entry: Identifiable {
        let purpose: OutingPurpose
        let count: Int
        var id: OutingPurpose { purpose }
    }
    let entries: [Entry]

    private var total: Int { entries.reduce(0) { $0 + $1.count } }
    private var nonZero: [Entry] { entries.filter { $0.count > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(nonZero) { entry in
                        entry.purpose.tekColors.icon
                            .frame(width: max(4, geo.size.width * CGFloat(entry.count) / CGFloat(max(total, 1))))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .frame(height: 14)

            HStack(spacing: 12) {
                ForEach(nonZero) { entry in
                    HStack(spacing: 5) {
                        Circle().fill(entry.purpose.tekColors.icon).frame(width: 8, height: 8)
                        Text(entry.purpose.displayName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(TekTheme.ink)
                        Text("\(entry.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TekTheme.faint)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

/// 設定行(アイコン角丸+ラベル+トレーリング)。マイページで使用。
struct TekSettingRow<Trailing: View>: View {
    let iconBackground: Color
    let label: String
    var showsDivider: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconBackground)
                    .frame(width: 28, height: 28)
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TekTheme.ink)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            if showsDivider {
                Divider().overlay(TekTheme.hairline).padding(.leading, 56)
            }
        }
    }
}
