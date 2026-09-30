import SwiftUI

/// メインシェル。自前ボトムバー(ホーム/カレンダー/探索マップ/マイページの4タブ)。
/// 記録は全自動検出のみ(手動開始UIは廃止)。手動停止はホーム画面右下のボタンが担う。
/// カレンダー(過去のログを見る導線)はタブから直接開く。
struct MainTabView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @ObservedObject var locationAuth: LocationAuthorization

    /// rawValue はタブの並び順で、DEBUG の `-initialTab N` 起動引数がそのまま指す番号でもある。
    enum Tab: Int {
        case home = 0, calendar, exploreMap, myPage
    }

    @State private var tab: Tab = .home

    init(locationAuth: LocationAuthorization) {
        self.locationAuth = locationAuth
        #if DEBUG
        // スクショ検証用: `-initialTab N` 起動引数で初期タブを選べる(DEBUG限定)。
        // 引数ドメインは値を文字列で持つことがあるので Int/String 双方を許容する。
        let raw = UserDefaults.standard.object(forKey: "initialTab")
        if let index = (raw as? Int) ?? (raw as? String).flatMap({ Int($0) }),
           let initial = Tab(rawValue: index) {
            _tab = State(initialValue: initial)
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabBar
        }
        .background(TekTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home:
            NavigationStack { HomeView(ledger: coordinator.stepLedger) }
        case .calendar:
            NavigationStack { CalendarView() }
        case .exploreMap:
            NavigationStack { ExploreMapView() }
        case .myPage:
            NavigationStack { MyPageView(locationAuth: locationAuth) }
        }
    }

    // MARK: - ボトムバー

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            tabButton(.home, icon: "house", label: "ホーム")
            tabButton(.calendar, icon: "calendar", label: "カレンダー")
            tabButton(.exploreMap, icon: "map", label: "探索マップ")
            tabButton(.myPage, icon: "person", label: "マイページ")
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
        .background(
            Rectangle()
                .fill(.white.opacity(0.96))
                .overlay(alignment: .top) { TekTheme.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(_ target: Tab, icon: String, label: String) -> some View {
        let selected = tab == target
        return Button {
            tab = target
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: selected ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: selected ? .bold : .medium))
            }
            .foregroundStyle(selected ? TekTheme.primary : TekTheme.faint)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
