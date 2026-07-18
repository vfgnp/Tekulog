import SwiftUI

/// アプリのルート。記録一覧/設定タブ、記録中バナー、初回オンボーディングを束ねる。
struct RootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @ObservedObject var locationAuth: LocationAuthorization

    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            // 記録中バナー/開始ボタンは全タブ共通(TabView の上に積む。
            // safeAreaInset だと各 NavigationStack の大タイトルに重なる)。
            recordingBanner
            tabs
        }
        .onAppear { showOnboarding = !didFinishOnboarding }
        .onChange(of: scenePhase) { _, phase in
            AppLog.lifecycle.notice("scenePhase → \(String(describing: phase), privacy: .public)")
            // フォアグラウンド復帰時に suspend 中の活動履歴を遡って出す(調査用)+
            // 歩数台帳を最新化(ホームの今日歩数をすぐ正しくする)。
            if phase == .active, didFinishOnboarding {
                coordinator.logMotionHistory()
                coordinator.refreshStepLedger()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            PermissionsOnboardingView(locationAuth: locationAuth) {
                didFinishOnboarding = true
                showOnboarding = false
                coordinator.startMonitoring()
            }
            .environmentObject(coordinator)
        }
    }

    private var tabs: some View {
        TabView {
            NavigationStack {
                HomeView(ledger: coordinator.stepLedger)
            }
            .tabItem { Label("ホーム", systemImage: "house") }

            NavigationStack {
                DayMapTab()
            }
            .tabItem { Label("地図", systemImage: "map") }

            NavigationStack {
                SessionListView()
            }
            .tabItem { Label("記録", systemImage: "list.bullet") }

            NavigationStack {
                SettingsView(locationAuth: locationAuth)
            }
            .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }

    @ViewBuilder
    private var recordingBanner: some View {
        if let live = coordinator.live {
            HStack(spacing: 12) {
                Image(systemName: live.kind.symbolName)
                    .font(.title3)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(live.kind.displayName)を記録中")
                        .font(.subheadline.bold())
                    // 経過時間を毎秒更新する(静止中も時間が進む)。
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(Formatters.distance(live.distanceMeters)) ・ \(Formatters.duration(context.date.timeIntervalSince(live.startedAt)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("停止") {
                    coordinator.stopManually()
                }
                .font(.subheadline.bold())
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.tint.opacity(0.15))
        } else if didFinishOnboarding {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("記録を開始")
                    .font(.subheadline.bold())
                Spacer()
                Menu {
                    ForEach(ActivityKind.allCases, id: \.self) { kind in
                        Button {
                            coordinator.startManually(kind: kind)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("開始", systemImage: "play.fill")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.thinMaterial)
        }
    }
}
