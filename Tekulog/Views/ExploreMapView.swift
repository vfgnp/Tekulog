import SwiftUI
import MapKit
import CoreLocation

/// 探索マップ(ホーム/探索マップ/マイページの3タブの1つ)。自宅を中心に、
/// 過去に歩いたエリアをフォグオブウォー風に可視化し、近い未開拓方向を提案する。
/// 自宅未設定なら CTA を表示する。
struct ExploreMapView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    @AppStorage(TekTheme.Keys.homeLocationIsSet) private var homeIsSet = false
    @AppStorage(TekTheme.Keys.homeLatitude) private var homeLat = 0.0
    @AppStorage(TekTheme.Keys.homeLongitude) private var homeLon = 0.0

    @State private var camera: MapCameraPosition = .automatic
    @State private var fogPoints: [CLLocationCoordinate2D] = []
    @State private var lastFetchedRegion: MKCoordinateRegion?
    @State private var explorationRate: Double = 0
    @State private var frontierCandidates: [FrontierCandidate] = []
    @State private var didInitialFit = false

    private struct FrontierCandidate: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let bearingDegrees: Double
        let distanceMeters: Double
        var name: String
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
            MapReader { proxy in
                ZStack {
                    Map(position: $camera) {
                        Marker("自宅", systemImage: "house.fill", coordinate: home)
                            .tint(TekTheme.primary)
                        ForEach(frontierCandidates) { candidate in
                            Marker(candidate.name, systemImage: "questionmark.circle", coordinate: candidate.coordinate)
                                .tint(TekTheme.amber)
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        refreshFogIfNeeded(region: context.region)
                    }
                    fogOverlay(proxy: proxy)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea(edges: .top)

            explorationRatePill
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { frontierSheet }
        .onAppear {
            if !didInitialFit {
                didInitialFit = true
                camera = .region(MKCoordinateRegion(
                    center: home, span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)))
            }
            Task { await loadExplorationRate(home: home) }
            Task { await loadFrontierCandidates(home: home) }
        }
    }

    // MARK: - フォグオーバーレイ(destinationOut ブレンドで開拓済みセルに穴を開ける)

    private func fogOverlay(proxy: MapProxy) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            context.blendMode = .destinationOut
            let radius: CGFloat = 46
            for coordinate in fogPoints {
                guard let point = proxy.convert(coordinate, to: .local) else { continue }
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(Gradient(colors: [.black, .black.opacity(0)]),
                                          center: point, startRadius: 0, endRadius: radius)
                )
            }
        }
    }

    private func refreshFogIfNeeded(region: MKCoordinateRegion) {
        if let last = lastFetchedRegion, overlapRatio(last, region) > 0.75 {
            return
        }
        lastFetchedRegion = region
        let margin = 1.3
        let minLat = region.center.latitude - region.span.latitudeDelta / 2 * margin
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2 * margin
        let minLon = region.center.longitude - region.span.longitudeDelta / 2 * margin
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2 * margin
        Task {
            if let cells = try? await coordinator.explorationService.fetchCells(
                minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon) {
                fogPoints = cells
            }
        }
    }

    /// 2領域の重なり具合(0〜1の目安、厳密な面積比ではない)。再取得の要否判定に使う。
    /// `internal`(テストから直接検証するため)。
    func overlapRatio(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Double {
        let latOverlap = max(0, min(a.center.latitude + a.span.latitudeDelta / 2, b.center.latitude + b.span.latitudeDelta / 2)
            - max(a.center.latitude - a.span.latitudeDelta / 2, b.center.latitude - b.span.latitudeDelta / 2))
        let lonOverlap = max(0, min(a.center.longitude + a.span.longitudeDelta / 2, b.center.longitude + b.span.longitudeDelta / 2)
            - max(a.center.longitude - a.span.longitudeDelta / 2, b.center.longitude - b.span.longitudeDelta / 2))
        let smallerLat = min(a.span.latitudeDelta, b.span.latitudeDelta)
        let smallerLon = min(a.span.longitudeDelta, b.span.longitudeDelta)
        guard smallerLat > 0, smallerLon > 0 else { return 0 }
        return (latOverlap / smallerLat) * (lonOverlap / smallerLon)
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

    private func loadExplorationRate(home: CLLocationCoordinate2D) async {
        explorationRate = (try? await coordinator.explorationService.explorationRate(
            home: home, radiusMeters: Tunables.explorationRateRadiusMeters)) ?? 0
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
            withAnimation {
                camera = .region(MKCoordinateRegion(
                    center: candidate.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            }
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

    private func loadFrontierCandidates(home: CLLocationCoordinate2D) async {
        guard let raw = try? await coordinator.explorationService.findFrontierCandidates(home: home) else { return }
        // 近い方位(45°未満)は距離が近い方だけ残し、最大5件を近い順で表示する。
        var kept: [(coordinate: CLLocationCoordinate2D, bearingDegrees: Double, distanceMeters: Double)] = []
        for candidate in raw.sorted(by: { $0.distanceMeters < $1.distanceMeters }) {
            if kept.contains(where: { angularDifference($0.bearingDegrees, candidate.bearingDegrees) < 45 }) { continue }
            kept.append(candidate)
            if kept.count >= 5 { break }
        }

        var resolved: [FrontierCandidate] = []
        for candidate in kept {
            let name = await PlaceLookupService.reverseGeocodeName(
                CLLocation(latitude: candidate.coordinate.latitude, longitude: candidate.coordinate.longitude))
                ?? "\(compassLabel(candidate.bearingDegrees))のエリア"
            resolved.append(FrontierCandidate(coordinate: candidate.coordinate,
                                              bearingDegrees: candidate.bearingDegrees,
                                              distanceMeters: candidate.distanceMeters,
                                              name: name))
        }
        frontierCandidates = resolved
    }

    func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(diff, 360 - diff)
    }
}
