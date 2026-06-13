import SwiftUI

/// アプリのルート。記録一覧/設定タブ、記録中バナー、初回オンボーディングを束ねる。
struct RootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @ObservedObject var locationAuth: LocationAuthorization

    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false

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
        .fullScreenCover(isPresented: .constant(!didFinishOnboarding)) {
            PermissionsOnboardingView(locationAuth: locationAuth) {
                didFinishOnboarding = true
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
                    Text("\(Formatters.distance(live.distanceMeters)) ・ \(Formatters.duration(Date().timeIntervalSince(live.startedAt)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.tint.opacity(0.15))
        }
    }
}
