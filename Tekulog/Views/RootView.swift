import SwiftUI

/// アプリのルート。記録一覧/設定タブ、記録中バナー、初回オンボーディングを束ねる。
struct RootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @ObservedObject var locationAuth: LocationAuthorization

    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            NavigationStack {
                SessionListView()
                    .safeAreaInset(edge: .top) { recordingBanner }
            }
            .tabItem { Label("記録", systemImage: "list.bullet") }

            NavigationStack {
                SettingsView(locationAuth: locationAuth)
            }
            .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .onAppear { showOnboarding = !didFinishOnboarding }
        .fullScreenCover(isPresented: $showOnboarding) {
            PermissionsOnboardingView(locationAuth: locationAuth) {
                didFinishOnboarding = true
                showOnboarding = false
                coordinator.startMonitoring()
            }
            .environmentObject(coordinator)
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
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.tint.opacity(0.15))
        }
    }
}
