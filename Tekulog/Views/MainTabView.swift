import SwiftUI

/// メインシェル。自前ボトムバー(ホーム/カレンダー/中央の記録FAB/マップ/マイページ)。
/// 記録状態は中央FABが担う(緑+play=待機、コーラル+stop=記録中)。
struct MainTabView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @ObservedObject var locationAuth: LocationAuthorization

    enum Tab: Int {
        case home = 0, calendar, map, myPage
    }

    @State private var tab: Tab = .home
    @State private var showKindDialog = false
    @State private var showLive = false

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
        .confirmationDialog("記録を開始", isPresented: $showKindDialog, titleVisibility: .visible) {
            ForEach(ActivityKind.allCases, id: \.self) { kind in
                Button(kind.displayName) {
                    coordinator.startManually(kind: kind)
                    showLive = true
                }
            }
        }
        .fullScreenCover(isPresented: $showLive) {
            LiveRecordingView()
                .environmentObject(coordinator)
        }
        #if DEBUG
        // スクショ検証用: `-liveDemo 1` で散歩セッションを開始し記録中画面を表示。
        .onAppear {
            if UserDefaults.standard.object(forKey: "liveDemo") != nil, !coordinator.isRecording {
                coordinator.startManually(kind: .walking)
                showLive = true
            }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home:
            NavigationStack { HomeView(ledger: coordinator.stepLedger) }
        case .calendar:
            NavigationStack { CalendarView() }
        case .map:
            NavigationStack { DayRouteScreen() }
        case .myPage:
            NavigationStack { SettingsView(locationAuth: locationAuth) }
        }
    }

    // MARK: - ボトムバー

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            tabButton(.home, icon: "house", label: "ホーム")
            tabButton(.calendar, icon: "calendar", label: "カレンダー")
            recordButton
            tabButton(.map, icon: "mappin.and.ellipse", label: "マップ")
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

    /// 中央の記録FAB。待機=緑play(種目選択)、記録中=コーラルstop(終了確認)。
    private var recordButton: some View {
        let recording = coordinator.isRecording
        return Button {
            if recording {
                showLive = true
            } else {
                showKindDialog = true
            }
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(recording ? TekTheme.coral : TekTheme.primary)
                        .frame(width: 56, height: 56)
                        .shadow(color: (recording ? TekTheme.coral : TekTheme.primary).opacity(0.4),
                                radius: 9, y: 5)
                        .overlay(Circle().stroke(.white, lineWidth: 4))
                    Image(systemName: recording ? "stop.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: recording)
                }
                .offset(y: -20)
                Text(recording ? "記録中" : "記録")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(recording ? TekTheme.coral : TekTheme.primary)
                    .offset(y: -18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44, alignment: .top)
        }
        .buttonStyle(.plain)
    }
}
