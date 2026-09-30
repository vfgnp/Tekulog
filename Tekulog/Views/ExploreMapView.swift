import SwiftUI
import Combine
import CoreLocation

/// 探索マップ(タブの1つ)。自宅を中心に、過去に歩いたエリアをフォグオブウォー風に可視化し、
/// 近い未開拓方向を提案する。自宅未設定なら CTA を表示する。
///
/// 地図とフォグは `ExploreFogMap`(MKMapView のオーバーレイ)が描く。このビューの役目は
/// データの読み込みと、地図の上に載るピル・シートだけ。開拓済みセルは表示範囲に依らず
/// 全件を読み込む(表示範囲ごとに取得し直す方式は、取得の判定漏れで晴れが欠ける不具合の
/// 原因だった)。読み込みの契機は、タブ表示・フォアグラウンド復帰・グリッド再構築の完了。
struct ExploreMapView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(TekTheme.Keys.homeLocationIsSet) private var homeIsSet = false
    @AppStorage(TekTheme.Keys.homeLatitude) private var homeLat = 0.0
    @AppStorage(TekTheme.Keys.homeLongitude) private var homeLon = 0.0

    @State private var fogIndex = FogCellIndex.empty
    /// `fogIndex` を差し替えるたびに増やす(`ExploreFogMap` が再描画の要否を判定する)。
    @State private var fogGeneration = 0
    @State private var cameraRequest: ExploreFogMap.CameraRequest?
    @State private var cameraRequestSequence = 0
    @State private var isRebuilding = false
    /// 読み込みの連番。読み込みは重なりうる(タブ表示の直後に再構築が完了する、など)ので、
    /// 結果を反映するときに「自分が最新の要求か」を確かめる(古い結果で新しい結果を上書きしない)。
    @State private var reloadSequence = 0
    /// 最後に地図へ渡した索引のセル数。セルは増える一方なので、件数が同じなら中身も同じ
    /// (グリッド再構築の後を除く)。変化がなければ索引の差し替え(=全タイルの再描画)を省く。
    @State private var shownCellCount: Int?
    @State private var explorationRate: Double = 0
    @State private var frontierCandidates: [FrontierCandidate] = []

    private struct FrontierCandidate: Identifiable {
        /// 方位と距離で決まる。読み込み直しても同じ地点なら同じ ID になり、地図のマーカーが付け直されない。
        var id: String { "\(Int(bearingDegrees.rounded()))-\(Int(distanceMeters.rounded()))" }
        let coordinate: CLLocationCoordinate2D
        let bearingDegrees: Double
        let distanceMeters: Double
        var name: String
        /// 地名を逆ジオコーディングで取得できたか(できなかった場合は方位名の代替表示)。
        var nameIsResolved: Bool
    }

    private var home: CLLocationCoordinate2D? {
        homeIsSet ? CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon) : nil
    }

    var body: some View {
        Group {
            if let home {
                mapContent(home: home)
            } else {
                emptyState
            }
        }
        .background(TekTheme.background)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - 自宅未設定時の CTA

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "location.slash")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(TekTheme.faint)
            Text("探索マップを使うには\n自宅の位置を設定してください")
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TekTheme.sub)
            NavigationLink {
                HomeLocationSettingView()
            } label: {
                Text("自宅を設定")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(TekTheme.primary, in: Capsule())
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - 本体

    @ViewBuilder
    private func mapContent(home: CLLocationCoordinate2D) -> some View {
        ZStack(alignment: .top) {
            ExploreFogMap(home: home,
                          frontierPins: frontierCandidates.map {
                              ExploreFogMap.Pin(id: $0.id, latitude: $0.coordinate.latitude,
                                                longitude: $0.coordinate.longitude, title: $0.name)
                          },
                          fogIndex: fogIndex,
                          fogGeneration: fogGeneration,
                          cameraRequest: cameraRequest)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 8) {
                explorationRatePill
                if isRebuilding { rebuildingPill }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { frontierSheet }
        // タブを表示するたびに読み込む(MainTabView はタブ切替のたびにこのビューを作り直す)。
        .task { await reloadAll(home: home) }
        // 常駐アプリなので、探索マップを開いたまま歩いて戻ってくることがある。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reloadAll(home: home) } }
        }
        // グリッド再構築の状態。購読した時点で現在値が届く(既に再構築中でも取りこぼさない)。
        // RunLoop.main ではなく DispatchQueue.main で受ける(地図のスクロール中も届く)。
        .onReceive(coordinator.explorationService.rebuildState.receive(on: DispatchQueue.main)) { rebuilding in
            let finished = isRebuilding && !rebuilding
            isRebuilding = rebuilding
            // 再構築でセルが入れ替わっている(件数が同じでも中身が違いうる)ので、必ず差し替える。
            if finished { Task { await reloadAll(home: home, forceFog: true) } }
        }
    }

    // MARK: - データの読み込み

    private func reloadAll(home: CLLocationCoordinate2D, forceFog: Bool = false) async {
        reloadSequence += 1
        let sequence = reloadSequence
        async let fog: Void = loadFog(home: home, sequence: sequence, force: forceFog)
        async let rate: Void = loadExplorationRate(home: home, sequence: sequence)
        async let frontier: Void = loadFrontierCandidates(home: home, sequence: sequence)
        _ = await (fog, rate, frontier)
    }

    /// 開拓済みセルを全件読み、フォグ描画用の索引に固めて地図へ渡す。
    /// 読み込みに失敗したら、表示中の索引をそのまま使い続ける。
    private func loadFog(home: CLLocationCoordinate2D, sequence: Int, force: Bool) async {
        guard let stored = try? await coordinator.explorationService.fetchAllCells() else { return }
        #if DEBUG
        // 性能確認用: `-demoFogCells N` で、自宅の周囲に N 個の合成セルをメモリ上だけで足す
        // (Core Data には書かないので実データは変わらない。開拓率・未開拓方向にも影響しない)。
        let demoCount = UserDefaults.standard.integer(forKey: "demoFogCells")
        let coordinates = demoCount > 0
            ? stored + ExplorationGrid.denseBlock(around: home, count: demoCount) : stored
        #else
        let coordinates = stored
        #endif
        // フォアグラウンドへ戻っただけで何も増えていないときは、地図を描き直さない。
        if !force, coordinates.count == shownCellCount { return }
        let index = await Task.detached(priority: .userInitiated) {
            FogCellIndex(coordinates: coordinates)
        }.value
        guard sequence == reloadSequence else { return }
        fogIndex = index
        fogGeneration += 1
        shownCellCount = coordinates.count
    }

    private var rebuildingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("開拓データを更新中…")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: Capsule())
    }

    // MARK: - 開拓率ピル

    private var explorationRatePill: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("自宅まわりの開拓率")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(explorationRate * 100))")
                        .font(.tekNumber(20))
                    Text("%").font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
            }
            TekProgressBar(fraction: explorationRate, tint: TekTheme.primary, track: .white.opacity(0.25))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private func loadExplorationRate(home: CLLocationCoordinate2D, sequence: Int) async {
        let rate = (try? await coordinator.explorationService.explorationRate(
            home: home, radiusMeters: Tunables.explorationRateRadiusMeters)) ?? 0
        guard sequence == reloadSequence else { return }
        explorationRate = rate
    }

    // MARK: - フロンティア(未開拓方向)ボトムシート

    private var frontierSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(TekTheme.hairline)
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10).padding(.bottom, 14)

            HStack {
                Text("まだ歩いていないエリア")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(TekTheme.ink)
                Spacer()
                Text("近い順")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TekTheme.amber)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(TekTheme.amberPale, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)

            if frontierCandidates.isEmpty {
                Text("周辺はほぼ開拓済みです。範囲を広げて探索してみましょう。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TekTheme.sub)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
            } else {
                VStack(spacing: 10) {
                    ForEach(frontierCandidates) { candidate in
                        frontierRow(candidate)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.08), radius: 12, y: -6)
        .padding(.horizontal, -1)   // 影の左右欠けを避ける
    }

    private func frontierRow(_ candidate: FrontierCandidate) -> some View {
        Button {
            // 地図をその地点へ移動させる(アニメーションは MKMapView 側が行う)。
            cameraRequestSequence += 1
            cameraRequest = ExploreFogMap.CameraRequest(id: cameraRequestSequence,
                                                       latitude: candidate.coordinate.latitude,
                                                       longitude: candidate.coordinate.longitude,
                                                       spanDegrees: 0.01)
        } label: {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(TekTheme.amber, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Text(compassLabel(candidate.bearingDegrees))
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(TekTheme.amber)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(TekTheme.ink)
                    Text("未踏エリア")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TekTheme.faint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(distanceLabel(candidate.distanceMeters))
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(TekTheme.primary)
                    Text("自宅から")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TekTheme.faint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    func compassLabel(_ bearing: Double) -> String {
        let labels = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]
        let index = Int((bearing / 45).rounded()) % 8
        return labels[(index + 8) % 8]
    }

    func distanceLabel(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1fkm", meters / 1000) : String(format: "%.0fm", meters)
    }

    private func loadFrontierCandidates(home: CLLocationCoordinate2D, sequence: Int) async {
        guard let raw = try? await coordinator.explorationService.findFrontierCandidates(home: home) else { return }
        // 近い方位(45°未満)は距離が近い方だけ残し、最大5件を近い順で表示する。
        var kept: [(coordinate: CLLocationCoordinate2D, bearingDegrees: Double, distanceMeters: Double)] = []
        for candidate in raw.sorted(by: { $0.distanceMeters < $1.distanceMeters }) {
            if kept.contains(where: { angularDifference($0.bearingDegrees, candidate.bearingDegrees) < 45 }) { continue }
            kept.append(candidate)
            if kept.count >= 5 { break }
        }

        // 同じ地点の地名が前回取得できていれば使い回す(再読込はフォアグラウンドへ戻るたびに走る。
        // そのたびに逆ジオコーディングし直すと、回数制限に当たって地名が代替表示に落ちる)。
        let known = Dictionary(frontierCandidates.filter(\.nameIsResolved).map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        var resolved: [FrontierCandidate] = []
        for candidate in kept {
            var entry = FrontierCandidate(coordinate: candidate.coordinate,
                                          bearingDegrees: candidate.bearingDegrees,
                                          distanceMeters: candidate.distanceMeters,
                                          name: "\(compassLabel(candidate.bearingDegrees))のエリア",
                                          nameIsResolved: false)
            if let name = known[entry.id] {
                entry.name = name
                entry.nameIsResolved = true
            } else if let name = await PlaceLookupService.reverseGeocodeName(
                CLLocation(latitude: candidate.coordinate.latitude, longitude: candidate.coordinate.longitude)) {
                entry.name = name
                entry.nameIsResolved = true
            }
            resolved.append(entry)
        }
        guard sequence == reloadSequence else { return }
        frontierCandidates = resolved
    }

    func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(diff, 360 - diff)
    }
}
