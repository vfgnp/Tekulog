import SwiftUI
import MapKit
import CoreData

/// 1日のまとめ。全セッションのルートを1枚の地図に色分け描画し、
/// 合計統計とタイムラインを並べる。タイムラインの行タップで該当ルートへ
/// ズーム/強調、再タップ(または全体表示ボタン)で全体に戻る。
struct DaySummaryView: View {
    private let day: Date

    @FetchRequest private var sessions: FetchedResults<WalkSession>
    /// 自前歩数台帳のその日ぶん(0件 or 1件)。総歩数カードの正はこちら。
    @FetchRequest private var dayStats: FetchedResults<DailyStat>

    /// 選択中セッション。nil なら全体表示(.automatic が全ルートを収める)。
    @State private var selectedID: NSManagedObjectID?
    @State private var camera: MapCameraPosition = .automatic

    init(day: Date) {
        self.day = day
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

    /// ルート色分け用パレット(セッションの時刻順インデックスで循環)。
    private static let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo]

    private func color(at index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    /// 描画対象(2点以上のルートを持つセッション)とその色。
    private var routes: [(session: WalkSession, coords: [CLLocationCoordinate2D], color: Color)] {
        sessions.enumerated().compactMap { index, session in
            let coords = session.coordinates
            guard coords.count >= 2 else { return nil }
            return (session, coords, color(at: index))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                dayMap
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                totalsGrid
                timeline
            }
            .padding()
        }
        .navigationTitle(Formatters.day(day))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 地図

    @ViewBuilder
    private var dayMap: some View {
        let routes = self.routes
        if routes.isEmpty {
            ContentUnavailableView(
                "ルートがありません",
                systemImage: "map",
                description: Text("位置情報が記録されていないセッションです。")
            )
        } else {
            Map(position: $camera) {
                ForEach(routes, id: \.session.objectID) { route in
                    let isSelected = selectedID == route.session.objectID
                    let isDimmed = selectedID != nil && !isSelected
                    MapPolyline(coordinates: route.coords)
                        .stroke(route.color.opacity(isDimmed ? 0.3 : 1), lineWidth: isSelected ? 6 : 5)
                }
                // 開始/終了マーカーは選択中ルートのみ(複数ルートで散らからないように)。
                if let selected = routes.first(where: { $0.session.objectID == selectedID }) {
                    if let start = selected.coords.first {
                        Marker("開始", systemImage: "flag", coordinate: start)
                            .tint(.green)
                    }
                    if let end = selected.coords.last {
                        Marker("終了", systemImage: "flag.checkered", coordinate: end)
                            .tint(.red)
                    }
                }
            }
            .mapControls { MapScaleView() }
            .overlay(alignment: .bottomTrailing) {
                if selectedID != nil {
                    Button("全体表示") {
                        deselect()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .padding(10)
                }
            }
        }
    }

    // MARK: - 合計統計

    private var totalsGrid: some View {
        let totalDistance = sessions.reduce(0) { $0 + $1.totalDistance }
        let totalDuration = sessions.reduce(0) { $0 + $1.duration }
        let sessionSteps = sessions.reduce(0) { $0 + Int($1.totalSteps) }
        let totalEnergy = sessions.reduce(0) { $0 + $1.energyBurned }
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(title: "総距離", value: Formatters.distance(totalDistance), symbol: "ruler")
            StatCard(title: "総時間", value: Formatters.duration(totalDuration), symbol: "clock")
            // 総歩数は自前台帳(24h)を正とする(台帳未整備の日はセッション合計)。
            let ledgerSteps = dayStats.first.map { Int($0.steps) }
            StatCard(title: ledgerSteps != nil ? "総歩数(1日)" : "総歩数(記録分)",
                     value: Formatters.steps(ledgerSteps ?? sessionSteps),
                     symbol: "shoeprints.fill")
            StatCard(title: "総消費", value: String(format: "%.0f kcal", totalEnergy), symbol: "flame")
        }
    }

    // MARK: - タイムライン

    private var timeline: some View {
        VStack(spacing: 8) {
            ForEach(Array(sessions.enumerated()), id: \.element.objectID) { index, session in
                DayTimelineRow(session: session,
                               color: color(at: index),
                               isSelected: selectedID == session.objectID) {
                    toggleSelection(session)
                }
            }
        }
    }

    private func toggleSelection(_ session: WalkSession) {
        if selectedID == session.objectID {
            deselect()
            return
        }
        selectedID = session.objectID
        let coords = session.coordinates
        if coords.count >= 2 {
            withAnimation {
                camera = .region(MapFitting.region(for: coords))
            }
        }
    }

    private func deselect() {
        selectedID = nil
        withAnimation {
            camera = .automatic
        }
    }
}

/// タイムラインの1行。行タップで地図の選択、info からセッション詳細へ。
private struct DayTimelineRow: View {
    @ObservedObject var session: WalkSession
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Image(systemName: session.activityKind.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(timeRange)
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    Text(Formatters.distance(session.totalDistance))
                    Text("・")
                    Text(Formatters.duration(session.duration))
                    if session.activityKind.countsSteps {
                        Text("・")
                        Text(Formatters.steps(Int(session.totalSteps)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink {
                SessionDetailView(session: session)
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tint)
            }
        }
        .padding(12)
        .background(isSelected ? AnyShapeStyle(color.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var timeRange: String {
        let start = session.startedAt.map(Formatters.time) ?? "--:--"
        let end = session.endedAt.map(Formatters.time) ?? "--:--"
        return "\(start) – \(end)"
    }
}
