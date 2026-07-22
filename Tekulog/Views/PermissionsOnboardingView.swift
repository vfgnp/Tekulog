import SwiftUI
import CoreLocation

/// 初回起動時の権限取得フロー。位置(常時)・モーション・通知・HealthKit を案内する。
struct PermissionsOnboardingView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @ObservedObject var locationAuth: LocationAuthorization
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Tekulog へようこそ")
                .font(.largeTitle.bold())
            Text("散歩や自転車を検知して自動で記録します。データは端末内にのみ保存され、外部には一切送信されません。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 14) {
                permissionRow(symbol: "location.fill", title: "位置情報(常時)",
                              detail: "バックグラウンドでもルートを記録するため。")
                permissionRow(symbol: "figure.walk", title: "モーションとフィットネス",
                              detail: "歩行・自転車を検知し歩数を計測するため。")
                permissionRow(symbol: "bell.fill", title: "通知",
                              detail: "記録の開始・保存をお知らせするため。")
                permissionRow(symbol: "heart.fill", title: "ヘルスケア",
                              detail: "ワークアウトとして保存するため。")
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Spacer()

            Button(action: requestAll) {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .onChange(of: locationAuth.status) { _, _ in advanceLocationIfNeeded() }
    }

    private var buttonTitle: String {
        switch locationAuth.status {
        case .notDetermined: return "続ける"
        case .authorizedWhenInUse: return "続ける"
        default: return "始める"
        }
    }

    private func permissionRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func requestAll() {
        switch locationAuth.status {
        case .notDetermined:
            locationAuth.requestWhenInUse()
        case .authorizedWhenInUse:
            locationAuth.requestAlways()
        default:
            break
        }
        Task {
            await coordinator.requestNotificationAuthorization()
            await coordinator.requestHealthKitAuthorization()
        }
        advanceLocationIfNeeded()
    }

    /// 位置が「常時」まで揃った、または明示的に拒否されたらオンボーディングを終える。
    private func advanceLocationIfNeeded() {
        switch locationAuth.status {
        case .authorizedAlways:
            onFinish()
        case .denied, .restricted:
            onFinish() // 拒否時もアプリ自体は使えるよう先へ進める。
        default:
            break
        }
    }
}
