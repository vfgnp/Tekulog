import SwiftUI
import CoreLocation

/// 設定とプライバシー説明。しきい値の常時編集は将来対応とし、現状は状態確認とポリシー表示。
struct SettingsView: View {
    @ObservedObject var locationAuth: LocationAuthorization

    var body: some View {
        Form {
            Section("権限の状態") {
                statusRow(title: "位置情報", value: locationStatusText)
                Button("設定アプリを開く") { openSettings() }
            }

            Section("自動記録の条件") {
                LabeledContent("散歩の開始", value: "\(Int(Tunables.walkingStartDuration / 60)) 分の歩行で開始")
                LabeledContent("自転車の開始", value: "\(Int(Tunables.cyclingStartDuration / 60)) 分の走行で開始")
                LabeledContent("自動終了", value: "\(Int(Tunables.stopDuration / 60)) 分の停止で保存")
            }

            Section("プライバシー") {
                Text("位置・運動データはすべてこの端末内にのみ保存され、開発者を含む外部サーバーには一切送信されません(完全クラウドレス設計)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("バージョン", value: appVersion)
            }
        }
        .navigationTitle("設定")
    }

    private func statusRow(title: String, value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private var locationStatusText: String {
        switch locationAuth.status {
        case .authorizedAlways: return "常に許可"
        case .authorizedWhenInUse: return "使用中のみ"
        case .denied: return "拒否"
        case .restricted: return "制限"
        case .notDetermined: return "未設定"
        @unknown default: return "不明"
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        return v
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
