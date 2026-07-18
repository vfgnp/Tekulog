import SwiftUI
import MapKit

/// 記録中ライブ画面(Claude Design 画面2、fullScreenCover)。
/// 現在地追従の地図+進行中ルート、REC ピル、経過時間/距離、下部シートに
/// ペース/歩数/血めぐり評価語と「終了して保存」。一時停止は未実装のため置かない。
struct LiveRecordingView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                recPill
                topStats
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomSheet }
        .background(TekTheme.background)
        // 外部要因(自動停止など)で記録が終わったら自動で閉じる。
        .onChange(of: coordinator.isRecording) { _, recording in
            if !recording { dismiss() }
        }
    }

    // MARK: - 地図

    @ViewBuilder
    private var mapLayer: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let coords = coordinator.live?.coordinates, coords.count >= 2 {
                MapPolyline(coordinates: coords)
                    .stroke(TekTheme.primary,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
        }
        .mapControls { MapUserLocationButton() }
    }

    // MARK: - REC ピル

    private var recPill: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0xFF4D4D)).frame(width: 9, height: 9)
                .modifier(BlinkModifier())
            Text("記録中")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(TekTheme.ink.opacity(0.82), in: Capsule())
    }

    // MARK: - 上部ステータス(経過時間+距離)

    private var topStats: some View {
        // 1秒ごとに経過時間を更新。
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 12) {
                liveCard(title: "経過時間", value: elapsedText)
                liveCard(title: "距離", value: distanceValue, unit: "km")
            }
        }
    }

    private func liveCard(title: String, value: String, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TekTheme.sub)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.tekNumber(26))
                    .foregroundStyle(TekTheme.ink)
                    .minimumScaleFactor(0.6).lineLimit(1)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 13, weight: .bold)).foregroundStyle(TekTheme.sub)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    // MARK: - 下部シート

    private var bottomSheet: some View {
        VStack(spacing: 18) {
            Capsule().fill(TekTheme.hairline).frame(width: 40, height: 5)
                .padding(.top, 12)

            HStack {
                sheetStat(title: "ペース", value: paceText, color: TekTheme.ink)
                Spacer()
                sheetStat(title: "歩数", value: (coordinator.live?.steps ?? 0).formatted(), color: TekTheme.ink)
                Spacer()
                sheetStat(title: "血めぐり", value: bloodLabel, color: TekTheme.coral)
            }
            .padding(.horizontal, 22)

            Button {
                coordinator.stopManually()
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 18, height: 18)
                    Text("終了して保存")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(TekTheme.coral, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: TekTheme.coral.opacity(0.35), radius: 10, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.12), radius: 14, y: -6)
    }

    private func sheetStat(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(TekTheme.sub)
            Text(value).font(.system(size: 19, weight: .heavy)).foregroundStyle(color)
        }
    }

    // MARK: - 表示値

    private var elapsedText: String {
        guard let start = coordinator.live?.startedAt else { return "00:00:00" }
        let total = Int(max(0, Date().timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private var distanceValue: String {
        String(format: "%.2f", (coordinator.live?.distanceMeters ?? 0) / 1000)
    }

    /// 平均ペース(秒/メートル → m'ss"/km)。距離ゼロなら「--」。
    private var paceText: String {
        guard let live = coordinator.live, live.distanceMeters > 10 else { return "--" }
        let seconds = Date().timeIntervalSince(live.startedAt)
        let secPerKm = seconds / (live.distanceMeters / 1000)
        return String(format: "%d'%02d\"", Int(secPerKm) / 60, Int(secPerKm) % 60)
    }

    /// 血めぐり評価語。走行 or ケイデンスが高いほど好調。セッション強度ベース。
    private var bloodLabel: String {
        guard let live = coordinator.live else { return "これから" }
        if live.kind == .running { return "好調" }
        let minutes = max(1.0 / 60, Date().timeIntervalSince(live.startedAt) / 60)
        let cadence = Double(live.steps) / minutes   // 歩/分
        switch cadence {
        case 100...: return "好調"
        case 60..<100: return "まずまず"
        default: return "これから"
        }
    }
}

/// REC ドットの点滅(デザインの tekblink 相当)。
private struct BlinkModifier: ViewModifier {
    @State private var on = true
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0.15)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = false }
    }
}
