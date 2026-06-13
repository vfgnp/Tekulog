import SwiftUI
import MapKit

/// セッション詳細。ルートを地図にポリラインで描画し、統計を並べる。
struct SessionDetailView: View {
    @ObservedObject var session: WalkSession

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                routeMap
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                statsGrid
            }
            .padding()
        }
        .navigationTitle(session.activityKind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var routeMap: some View {
        let coords = session.coordinates
        if coords.count >= 2 {
            Map(initialPosition: .region(region(for: coords))) {
                MapPolyline(coordinates: coords)
                    .stroke(.tint, lineWidth: 5)
                if let start = coords.first {
                    Marker("開始", systemImage: "flag", coordinate: start)
                        .tint(.green)
                }
                if let end = coords.last {
                    Marker("終了", systemImage: "flag.checkered", coordinate: end)
                        .tint(.red)
                }
            }
            .mapControls { MapScaleView() }
        } else {
            ContentUnavailableView(
                "ルートがありません",
                systemImage: "map",
                description: Text("位置情報が記録されていないセッションです。")
            )
        }
    }

    private var statsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(title: "距離", value: Formatters.distance(session.totalDistance), symbol: "ruler")
            StatCard(title: "時間", value: Formatters.duration(session.duration), symbol: "clock")
            if session.activityKind == .walking {
                StatCard(title: "歩数", value: Formatters.steps(Int(session.totalSteps)), symbol: "shoeprints.fill")
                StatCard(title: "ペース", value: Formatters.pace(secondsPerMeter: session.avgPace), symbol: "speedometer")
            }
            StatCard(title: "消費", value: String(format: "%.0f kcal", session.energyBurned), symbol: "flame")
            StatCard(title: "開始", value: Formatters.dateTime(session.startedAt ?? Date()), symbol: "calendar")
        }
    }

    /// ルート全体が収まる領域を計算する。
    private func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
                                    longitudeDelta: max((maxLon - minLon) * 1.4, 0.005))
        return MKCoordinateRegion(center: center, span: span)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
