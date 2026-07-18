import SwiftUI
import CoreData
import CoreLocation

/// マイページ(Claude Design 画面6)。プロフィール+生涯統計+設定グループ。
/// 旧 SettingsView を統合(権限ステータスもここに移植)。実績は push。
struct MyPageView: View {
    @ObservedObject var locationAuth: LocationAuthorization

    @AppStorage(TekTheme.Keys.nickname) private var nickname = "あなた"
    @AppStorage(TekTheme.Keys.stepGoal) private var stepGoal = TekTheme.defaultStepGoal
    @AppStorage(TekTheme.Keys.autoRecordEnabled) private var autoRecord = true
    @AppStorage(TekTheme.Keys.gpsHighAccuracy) private var gpsHighAccuracy = true

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DailyStat.day, ascending: false)]
    )
    private var dailyStats: FetchedResults<DailyStat>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WalkSession.startedAt, ascending: false)],
        predicate: NSPredicate(format: "endedAt != nil")
    )
    private var sessions: FetchedResults<WalkSession>

    @State private var editingName = false
    @State private var draftName = ""

    /// 歩数目標の選択肢。
    private let goalOptions = [6_000, 8_000, 10_000, 12_000, 15_000, 20_000]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("マイページ")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(TekTheme.ink)
                    .padding(.top, 6)

                profileCard
                lifetimeStats

                SectionLabel("記録").padding(.top, 6)
                recordGroup

                SectionLabel("アプリ設定")
                appGroup
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(TekTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .alert("ニックネーム", isPresented: $editingName) {
            TextField("ニックネーム", text: $draftName)
            Button("保存") {
                let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { nickname = trimmed }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - プロフィール

    private var totalPoints: Int {
        let steps = dailyStats.reduce(0) { $0 + Int($1.steps) }
        let running = sessions.filter { $0.activityKind == .running }.reduce(0) { $0 + Int($1.totalSteps) }
        return Motivation.points(daySteps: steps, runningSessionSteps: running)
    }

    private var profileCard: some View {
        let level = Achievements.level(points: totalPoints)
        return TekCard(radius: 24, padding: 20) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(TekTheme.primaryPale)
                    Text(String(nickname.prefix(1)))
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(TekTheme.primary)
                }
                .frame(width: 66, height: 66)

                VStack(alignment: .leading, spacing: 4) {
                    Text(nickname)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(TekTheme.ink)
                    NavigationLink {
                        AchievementsView()
                    } label: {
                        Text("Lv.\(level) \(Achievements.levelName(level))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TekTheme.primaryDark)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(TekTheme.primaryPale, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    draftName = nickname
                    editingName = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TekTheme.sub)
                        .frame(width: 34, height: 34)
                        .background(TekTheme.background, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 生涯統計

    private var lifetimeStats: some View {
        let totalDistanceKm = sessions.reduce(0) { $0 + $1.totalDistance } / 1000
        let totalSteps = dailyStats.reduce(0) { $0 + Int($1.steps) }
        let recordedDays = dailyStats.filter { $0.steps > 0 }.count
        return HStack(spacing: 10) {
            lifetimeCell(value: distanceText(totalDistanceKm), label: "総距離 km")
            lifetimeCell(value: compact(totalSteps), label: "総歩数")
            lifetimeCell(value: "\(recordedDays)", label: "記録日数")
        }
    }

    private func lifetimeCell(value: String, label: String) -> some View {
        TekCard(radius: 18, padding: 14) {
            VStack(spacing: 3) {
                Text(value).font(.tekNumber(20)).foregroundStyle(TekTheme.ink)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(TekTheme.sub)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 記録グループ

    private var recordGroup: some View {
        VStack(spacing: 0) {
            TekSettingRow(iconBackground: TekTheme.primaryPale, label: "自動記録") {
                Toggle("", isOn: $autoRecord).labelsHidden().tint(TekTheme.primary)
            }
            TekSettingRow(iconBackground: TekTheme.amberPale, label: "1日の歩数目標") {
                Menu {
                    Picker("歩数目標", selection: $stepGoal) {
                        ForEach(goalOptions, id: \.self) { goal in
                            Text("\(goal.formatted()) 歩").tag(goal)
                        }
                    }
                } label: {
                    trailingValue("\(stepGoal.formatted())歩")
                }
            }
            TekSettingRow(iconBackground: TekTheme.coralPale, label: "GPS精度", showsDivider: false) {
                Menu {
                    Picker("GPS精度", selection: $gpsHighAccuracy) {
                        Text("高(精度優先)").tag(true)
                        Text("標準(省電力)").tag(false)
                    }
                } label: {
                    trailingValue(gpsHighAccuracy ? "高" : "標準")
                }
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: TekTheme.cardShadow, radius: 8, y: 4)
    }

    // MARK: - アプリ設定グループ

    private var appGroup: some View {
        VStack(spacing: 0) {
            TekSettingRow(iconBackground: Color(hex: 0xEAECEA), label: "位置情報") {
                HStack(spacing: 6) {
                    Text(locationStatusText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TekTheme.sub)
                    chevron
                }
            }
            .overlay { Button("") { openSettings() }.opacity(0.001) }

            TekSettingRow(iconBackground: Color(hex: 0xEAECEA), label: "通知") {
                chevron
            }
            .overlay { Button("") { openSettings() }.opacity(0.001) }

            NavigationLink {
                AboutView()
            } label: {
                TekSettingRow(iconBackground: Color(hex: 0xEAECEA), label: "Teklogについて",
                              showsDivider: false) { chevron }
            }
            .buttonStyle(.plain)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: TekTheme.cardShadow, radius: 8, y: 4)
    }

    private func trailingValue(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(TekTheme.sub)
            chevron
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(TekTheme.disabled)
    }

    // MARK: - 補助

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

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func distanceText(_ km: Double) -> String {
        km >= 100 ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return n.formatted()
    }
}

/// Teklog について(バージョン+クラウドレス説明+サードパーティ表記)。
private struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TekCard(radius: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("バージョン").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(TekTheme.ink)
                            Spacer()
                            Text(appVersion).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(TekTheme.sub)
                        }
                        Divider().overlay(TekTheme.hairline)
                        Text("位置・運動データはすべてこの端末内にのみ保存され、開発者を含む外部サーバーには一切送信されません(完全クラウドレス設計)。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TekTheme.sub)
                        Text("地図タイルと「通った場所」の逆ジオコーディングでは、表示のため座標が Apple に送信されます(MapKit と同じ Apple のプライバシー管轄。開発者サーバーには送信しません)。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TekTheme.sub)
                    }
                }
                TekCard(radius: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("サードパーティ表記")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(TekTheme.sub)
                        Text("アプリアイコンの炎は Phosphor Icons(MIT)を使用しています。")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(TekTheme.ink)
                    }
                }
            }
            .padding(20)
        }
        .background(TekTheme.background)
        .navigationTitle("Teklogについて")
        .navigationBarTitleDisplayMode(.inline)
    }
}
