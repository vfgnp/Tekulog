import Foundation
import UserNotifications

/// 自動記録の開始/保存をローカル通知で知らせる。
/// 保存通知には「破棄」アクションを付け、誤検知の記録をその場で削除できるようにする。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    nonisolated static let savedCategoryID = "SAVED_WALK"
    nonisolated static let discardActionID = "DISCARD_WALK"
    nonisolated static let sessionIDKey = "sessionID"

    private let center = UNUserNotificationCenter.current()

    /// 保存通知の「破棄」が押されたとき、対象セッションの UUID 文字列を渡す。
    var onDiscardRequested: ((UUID) -> Void)?

    func configure() {
        center.delegate = self
        let discard = UNNotificationAction(identifier: Self.discardActionID,
                                           title: "この記録を破棄",
                                           options: [.destructive, .authenticationRequired])
        let category = UNNotificationCategory(identifier: Self.savedCategoryID,
                                              actions: [discard],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// 記録開始を通知する。
    func notifyRecordingStarted(kind: ActivityKind) {
        let content = UNMutableNotificationContent()
        content.title = "\(kind.displayName)を記録中"
        content.body = "移動が止まると自動で保存します。"
        content.sound = .default
        post(content, id: "started")
    }

    /// 記録保存を通知する(破棄アクション付き)。
    func notifyRecordingSaved(kind: ActivityKind,
                              distanceMeters: Double,
                              steps: Int,
                              sessionID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "\(kind.displayName)を保存しました"
        content.body = summary(kind: kind, distanceMeters: distanceMeters, steps: steps)
        content.sound = .default
        content.categoryIdentifier = Self.savedCategoryID
        content.userInfo = [Self.sessionIDKey: sessionID.uuidString]
        post(content, id: "saved-\(sessionID.uuidString)")
    }

    private func summary(kind: ActivityKind, distanceMeters: Double, steps: Int) -> String {
        let km = String(format: "%.2f km", distanceMeters / 1000)
        switch kind {
        case .walking: return "\(km) ・ \(steps) 歩"
        case .cycling: return km
        }
    }

    private func post(_ content: UNNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        // フォアグラウンドでもバナー表示する。
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler:
                                            @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if response.actionIdentifier == Self.discardActionID,
           let raw = userInfo[Self.sessionIDKey] as? String,
           let uuid = UUID(uuidString: raw) {
            Task { @MainActor in self.onDiscardRequested?(uuid) }
        }
        completionHandler()
    }
}
