import SwiftUI

/// 統計値1つ分のカード。セッション詳細・日別まとめで共用。
struct StatCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TekTheme.sub)
            Text(value)
                .font(.tekNumber(18))
                .foregroundStyle(TekTheme.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: TekTheme.cardShadow, radius: 8, y: 4)
    }
}
