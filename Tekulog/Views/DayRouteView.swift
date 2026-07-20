import SwiftUI
import MapKit
import CoreData

/// 地図タブ/カレンダーからの日別ルート表示のホスト。
/// `DayRouteView` の @FetchRequest は init で固定されるため、日送りは
/// ここで day を持ち `.id(day)` で作り直す(DayMapTab から踏襲した方式)。
struct DayRouteScreen: View {
    @State private var day: Date

    init(initialDay: Date = Calendar.current.startOfDay(for: Date())) {
        _day = State(initialValue: Calendar.current.startOfDay(for: initialDay))
    }

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        DayRouteView(day: day, canGoNext: day < today) { delta in
            if let shifted = Calendar.current.date(byAdding: .day, value: delta, to: day) {
                day = min(shifted, today)
            }
        }
        .id(day)
    }
}

/// 1日のルートをフルスクリーン地図+下部シートで表示(Claude Design 画面3)。
/// 上部ピルにルート名+日時、日送り chevron。シートに距離/時間/歩数/高低差と
/// 逆ジオコーディングした「通った場所」。複数セッションは色分け+選択で強調。
struct DayRouteView: View {
    let day: Date
    let canGoNext: Bool
    let onShiftDay: (Int) -> Void

    @FetchRequest private var sessions: FetchedResults<WalkSession>
    @FetchRequest private var dayStats: FetchedResults<DailyStat>

    @State private var selectedID: NSManagedObjectID?
    @State private var camera: MapCameraPosition = .automatic
    @StateObject private var places = PlaceLookupService()

    init(day: Date, canGoNext: Bool, onShiftDay: @escaping (Int) -> Void) {
        self.day = day
        self.canGoNext = canGoNext
        self.onShiftDay = onShiftDay
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _sessions = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \WalkSession.startedAt, ascending: true)],
            predicate: NSPredicate(format: "endedAt != nil AND startedAt >= %@ AND startedAt < %@",
                                   start as NSDate, end as NSDate)
        )
        _dayStats = FetchRequest(
            sortDescriptors: [],
            predicate: NSPredicate(format: "day == %@", start as NSDate)
        )
    }

    /// ルート色分けパレット(時刻順インデックスで循環)。
    private static let palette: [Color] = [
        TekTheme.primary, TekTheme.coral, TekTheme.blue,
        TekTheme.amber, Color(hex: 0x8E7BEF), Color(hex: 0x18B3A6)
    ]
    private func color(at index: Int) -> Color { Self.palette[index % Self.palette.count] }

    /// 描画対象(2点以上のルートを持つセッション)。
    private var routes: [(session: WalkSession, coords: [CLLocationCoordinate2D], color: Color)] {
        sessions.enumerated().compactMap { index, session in
            let coords = session.coordinates
            guard coords.count >= 2 else { return nil }
            return (session, coords, color(at: index))
        }
    }

    /// 全ルートの座標(カメラのフィッティング用)。
    private var allCoords: [CLLocationCoordinate2D] {
        routes.flatMap { $0.coords }
    }

    /// 全ルートが収まるようカメラを合わせる。`.automatic` はポリラインのみだと
    /// ズームしないので、明示的に region を計算する。
    private func fitAllRoutes(animated: Bool) {
        let coords = allCoords
        guard !coords.isEmpty else { return }
        let region = MapFitting.region(for: coords)
        if animated {
            withAnimation { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
                .ignoresSafeArea(edges: .top)
            titlePill
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomSheet }
        .background(TekTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { fitAllRoutes(animated: false) }
        .task(id: selectedID) {
            await places.lookup(waypoints: waypoints)
        }
    }

    // MARK: - 地図

    @ViewBuilder
    private var mapLayer: some View {
        Map(position: $camera) {
            ForEach(routes, id: \.session.objectID) { route in
                let isSelected = selectedID == route.session.objectID
                let isDimmed = selectedID != nil && !isSelected
                MapPolyline(coordinates: route.coords)
                    .stroke(route.color.opacity(isDimmed ? 0.28 : 1),
                            style: StrokeStyle(lineWidth: isSelected ? 7 : 5,
                                               lineCap: .round, lineJoin: .round))
            }
            if let selected = routes.first(where: { $0.session.objectID == selectedID }) {
                if let start = selected.coords.first {
                    Marker("開始", systemImage: "figure.walk", coordinate: start).tint(TekTheme.primary)
                }
                if let end = selected.coords.last {
                    Marker("終了", systemImage: "flag.checkered", coordinate: end).tint(TekTheme.coral)
                }
            }
        }
        .overlay {
            if routes.isEmpty {
                ContentUnavailableView {
                    Label("ルートがありません", systemImage: "map")
                } description: {
                    Text("この日は位置情報が記録されていません。")
                }
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - 上部ピル(ルート名+日送り)

    private var titlePill: some View {
        HStack(spacing: 10) {
            pillCircleButton(system: "chevron.left") { onShiftDay(-1) }
            VStack(alignment: .leading, spacing: 1) {
                Text(routeTitle)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(TekTheme.ink)
                Text(routeSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TekTheme.sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            pillCircleButton(system: "chevron.right", disabled: !canGoNext) { onShiftDay(1) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func pillCircleButton(system: String, disabled: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(disabled ? TekTheme.disabled : TekTheme.ink)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }

    // MARK: - 下部シート

    private var bottomSheet: some View {
        VStack(spacing: 0) {
            Capsule().fill(TekTheme.hairline)
                .frame(width: 40, height: 5)
                .padding(.top, 10).padding(.bottom, 14)

            statRow
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
                .overlay(alignment: .bottom) { TekTheme.hairline.frame(height: 1) }

            if routes.count > 1 { routeSelector }

            placeSection
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.08), radius: 12, y: -6)
        .padding(.horizontal, -1)   // 影の左右欠けを避ける
    }

    private var statRow: some View {
        HStack(alignment: .top) {
            statCell(title: "距離", value: String(format: "%.1f", statDistance / 1000), unit: "km")
            Spacer()
            statCell(title: "時間", value: Self.hourMinute(statDuration))
            Spacer()
            statCell(title: "歩数", value: statSteps.formatted())
            Spacer()
            statCell(title: "高低差", value: String(format: "%.0f", statAscent), unit: "m")
        }
    }

    private func statCell(title: String, value: String, unit: String = "") -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TekTheme.sub)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.tekNumber(20))
                    .foregroundStyle(TekTheme.ink)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 11, weight: .bold)).foregroundStyle(TekTheme.sub)
                }
            }
        }
    }

    /// 複数セッション時の色分けセレクタ(タップで強調/解除)。
    private var routeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(routes.enumerated()), id: \.element.session.objectID) { _, route in
                    let selected = selectedID == route.session.objectID
                    Button {
                        toggle(route.session, coords: route.coords)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(route.color).frame(width: 9, height: 9)
                            Text(timeRange(route.session))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(selected ? .white : TekTheme.ink)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selected ? route.color : TekTheme.hairline,
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
        }
    }

    private var placeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("通った場所")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TekTheme.sub)
                if places.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.bottom, 4)

            if places.places.isEmpty && !places.isLoading {
                Text(routes.isEmpty ? "—" : "場所を特定できませんでした")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TekTheme.faint)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(places.places.enumerated()), id: \.element.id) { index, place in
                    HStack(spacing: 12) {
                        Circle().fill(placeDotColor(index)).frame(width: 10, height: 10)
                        Text(place.name)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(TekTheme.ink)
                        Spacer()
                        Text(Formatters.time(place.time))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TekTheme.sub)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeDotColor(_ index: Int) -> Color {
        if index == 0 { return TekTheme.primary }
        if index == places.places.count - 1 { return TekTheme.coral }
        return TekTheme.faint
    }

    // MARK: - 選択

    private func toggle(_ session: WalkSession, coords: [CLLocationCoordinate2D]) {
        if selectedID == session.objectID {
            selectedID = nil
            fitAllRoutes(animated: true)
        } else {
            selectedID = session.objectID
            withAnimation { camera = .region(MapFitting.region(for: coords)) }
        }
    }

    // MARK: - 集計

    private var selectedSession: WalkSession? {
        guard let id = selectedID else { return nil }
        return sessions.first { $0.objectID == id }
    }

    private var statDistance: Double {
        selectedSession?.totalDistance ?? sessions.reduce(0) { $0 + $1.totalDistance }
    }
    private var statDuration: TimeInterval {
        selectedSession?.duration ?? sessions.reduce(0) { $0 + $1.duration }
    }
    private var statSteps: Int {
        if let s = selectedSession { return Int(s.totalSteps) }
        if let ledger = dayStats.first { return Int(ledger.steps) }
        return sessions.reduce(0) { $0 + Int($1.totalSteps) }
    }
    private var statAscent: Double {
        let targets: [WalkSession] = selectedSession.map { [$0] } ?? Array(sessions)
        return targets.reduce(0) { $0 + ascent(of: $1) }
    }

    /// 上り累積標高(m)。1m 未満の上下動はノイズとして無視。
    private func ascent(of session: WalkSession) -> Double {
        var gain = 0.0
        var prev: Double?
        for point in session.orderedPoints {
            if let p = prev {
                let delta = point.altitude - p
                if delta > 1 { gain += delta }
            }
            prev = point.altitude
        }
        return gain
    }

    /// 逆ジオコーディング対象の (座標, 時刻)。選択中はそのセッション、なければ全体を時系列で。
    private var waypoints: [(coord: CLLocationCoordinate2D, time: Date)] {
        let targets: [WalkSession] = selectedSession.map { [$0] } ?? Array(sessions)
        return targets.flatMap { $0.orderedPoints }
            .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
            .compactMap { point in point.timestamp.map { (point.coordinate, $0) } }
    }

    // MARK: - 表示文言

    private var routeTitle: String {
        if let s = selectedSession { return s.autoName }
        switch sessions.count {
        case 0: return "記録なし"
        case 1: return sessions.first?.autoName ?? "記録"
        default: return "\(sessions.count)件の記録"
        }
    }

    private var routeSubtitle: String {
        let base = Formatters.day(day)
        if let start = (selectedSession ?? sessions.first)?.startedAt {
            return "\(base) \(Formatters.time(start))"
        }
        return base
    }

    private func timeRange(_ session: WalkSession) -> String {
        let start = session.startedAt.map(Formatters.time) ?? "--:--"
        return start
    }

    private static func hourMinute(_ seconds: TimeInterval) -> String {
        let total = Int(seconds) / 60
        let h = total / 60, m = total % 60
        return h > 0 ? String(format: "%d:%02d", h, m) : "\(m)分"
    }
}
