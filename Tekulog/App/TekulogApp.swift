import SwiftUI

@main
struct TekulogApp: App {
    private let persistence = PersistenceController.shared
    @StateObject private var coordinator = SessionCoordinator()
    @StateObject private var locationAuth = LocationAuthorization()

    init() {
        // 通知カテゴリ/デリゲートを起動直後に設定(破棄アクションのため)。
        // StateObject はまだ参照できないため一時インスタンスは使わず、
        // bootstrap は onAppear 相当の .task で行う。
    }

    var body: some Scene {
        WindowGroup {
            RootView(locationAuth: locationAuth)
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .environmentObject(coordinator)
                .task {
                    coordinator.bootstrap()
                    // すでにオンボーディング済みなら監視を再開する。
                    if UserDefaults.standard.bool(forKey: "didFinishOnboarding") {
                        coordinator.startMonitoring()
                    }
                }
        }
    }
}
