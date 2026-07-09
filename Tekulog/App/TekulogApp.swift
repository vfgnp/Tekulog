import SwiftUI

/// SLC(significant-location-change)による background relaunch のエントリポイント。
/// ヘッドレス(バックグラウンド)relaunch では UI シーンが接続されず WindowGroup の
/// `.task` が走らないことがあるため、SLC セーフティネットを実効化するには
/// ここで監視を再開する必要がある。coordinator は `SessionCoordinator.shared` で
/// SwiftUI 側と同一インスタンスに到達する。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if launchOptions?[.location] != nil {
            AppLog.lifecycle.notice("AppDelegate: location background relaunch を検知 → 監視再開")
            if UserDefaults.standard.bool(forKey: "didFinishOnboarding") {
                SessionCoordinator.shared.bootstrap()
                SessionCoordinator.shared.startMonitoring()
            }
        }
        return true
    }
}

@main
struct TekulogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let persistence = PersistenceController.shared
    // AppDelegate(ヘッドレス relaunch)と同じ実体を共有する。
    @StateObject private var coordinator = SessionCoordinator.shared
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
