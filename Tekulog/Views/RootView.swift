import SwiftUI

/// アプリのルート。実装フェーズ9で一覧/詳細/設定タブに置き換える。
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.system(size: 48))
            Text("Tekulog")
                .font(.largeTitle.bold())
            Text("散歩・自転車を自動で記録します")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    RootView()
}
