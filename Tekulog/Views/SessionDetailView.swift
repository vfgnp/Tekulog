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
            Map(initialPosition: .region(MapFitting.region(for: coords))) {
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

}
