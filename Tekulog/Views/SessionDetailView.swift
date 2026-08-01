import SwiftUI
import MapKit

/// セッション詳細。ルートを地図にポリラインで描画し、外出目的の分類(編集可能な
/// チップつき)・統計・探索ハイライトを並べる。
struct SessionDetailView: View {
    @ObservedObject var session: WalkSession
    private let repository = WalkRepository()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                routeMap
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                purposeCard
                statsGrid
                explorationHighlightCard
            }
            .padding()
        }
        .background(TekTheme.background)
        .navigationTitle(session.autoName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var routeMap: some View {
        let coords = session.coordinates
        if coords.count >= 2 {
            Map(initialPosition: .region(MapFitting.region(for: coords))) {
                MapPolyline(coordinates: coords)
                    .stroke(TekTheme.primary,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                if let start = coords.first {
                    Marker("開始", systemImage: "figure.walk", coordinate: start)
                        .tint(TekTheme.primary)
                }
                if let end = coords.last {
                    Marker("終了", systemImage: "flag.checkered", coordinate: end)
                        .tint(TekTheme.coral)
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

    // MARK: - 外出目的の分類 + チップ

    private var purposeCard: some View {
        let colors = session.purpose.tekColors
        return TekCard(radius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colors.background)
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: session.purpose.symbolName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(colors.icon)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.purposeIsUserSet ? "この外出のタイプ" : "この外出は自動でこう判定しました")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(TekTheme.sub)
                        Text(session.purpose.displayName)
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(TekTheme.ink)
                    }
                }
                Text("タイプを変更")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TekTheme.sub)
                HStack(spacing: 7) {
                    ForEach(OutingPurpose.allCases, id: \.self) { purpose in
                        purposeChip(purpose)
                    }
                }
            }
        }
    }

    private func purposeChip(_ purpose: OutingPurpose) -> some View {
        let selected = session.purpose == purpose
        let colors = purpose.tekColors
        return Button {
            let sessionID = session.objectID
            Task { try? await repository.setPurpose(sessionID: sessionID, purpose: purpose) }
        } label: {
            Text(purpose.displayName)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(selected ? .white : TekTheme.sub)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(selected ? colors.icon : TekTheme.background, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 統計

    private var statsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(title: "距離", value: Formatters.distance(session.totalDistance), symbol: "ruler")
            StatCard(title: "時間", value: Formatters.duration(session.duration), symbol: "clock")
            if session.activityKind.countsSteps {
                StatCard(title: "歩数", value: Formatters.steps(Int(session.totalSteps)), symbol: "shoeprints.fill")
                StatCard(title: "ペース", value: Formatters.pace(secondsPerMeter: session.avgPace), symbol: "speedometer")
            }
            StatCard(title: "消費", value: String(format: "%.0f kcal", session.energyBurned), symbol: "flame")
            StatCard(title: "開始", value: Formatters.dateTime(session.startedAt ?? Date()), symbol: "calendar")
        }
    }

    // MARK: - 探索ハイライト

    @ViewBuilder
    private var explorationHighlightCard: some View {
        if session.exploredNewCellCount > 0 {
            let areaKm2 = Double(session.exploredNewCellCount)
                * Tunables.explorationCellSizeMeters * Tunables.explorationCellSizeMeters / 1_000_000
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "location.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                    Text("この\(session.activityKind.displayName)で新しく開拓!")
                        .font(.system(size: 14, weight: .heavy))
                }
                .foregroundStyle(.white)
                HStack(spacing: 20) {
                    statPair(value: "\(session.exploredNewCellCount)", label: "新規セル")
                    Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 30)
                    statPair(value: String(format: "+%.2f", areaKm2), label: "km² 拡大")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
            .background(
                LinearGradient(colors: [TekTheme.amber, Color(hex: 0xB07A2A)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .shadow(color: TekTheme.amber.opacity(0.28), radius: 10, y: 5)
        }
    }

    private func statPair(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.tekNumber(22)).foregroundStyle(.white)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
    }
}
