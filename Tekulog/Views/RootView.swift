import SwiftUI

/// アプリのルート。メインシェル(MainTabView)+初回オンボーディングゲート。
/// 記録の開始/停止は MainTabView 中央の記録FABが担う(旧上部バナーは廃止)。
struct RootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @ObservedObject var locationAuth: LocationAuthorization

    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MainTabView(locationAuth: locationAuth)
            // Claude Design の配色はライト前提(ダーク対応は将来課題)。
            .preferredColorScheme(.light)
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
}
