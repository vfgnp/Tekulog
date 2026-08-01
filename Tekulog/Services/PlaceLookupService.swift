import Foundation
import CoreLocation

/// ルート上の代表点を逆ジオコーディングして「通った場所」を得る。
///
/// ⚠️ プライバシー: `CLGeocoder` はルート座標を **Apple のサーバーに送信** する
/// (MapKit のタイル取得と同じ Apple のプライバシー管轄)。アプリ自身のサーバーには
/// 一切送らないので「データ収集なし」の建付けは維持されるが、逆ジオコーディングを
/// 使う=座標が Apple に渡る、という事実は README/CLAUDE.md に明記している。
///
/// CLGeocoder は同時に1リクエストしか捌けずレート制限(約50回/分)もあるため、
/// 代表点を数点に間引いて逐次照会し、粗い格子でメモリキャッシュする。失敗は黙って省略。
@MainActor
final class PlaceLookupService: ObservableObject {

    struct Place: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let time: Date
    }

    @Published private(set) var places: [Place] = []
    @Published private(set) var isLoading = false

    /// 粗い格子(小数3桁≒100m)→ 地名。同じ辺りの再照会を避ける。
    private var cache: [String: String] = [:]
    /// 最新の照会だけを反映するためのトークン(日送りで古い結果が来ても捨てる)。
    private var currentToken = UUID()

    /// 最大この件数まで代表点を間引く。
    private let maxPoints = 5

    /// waypoints: (座標, 時刻) の時系列。start / 等間隔の中間 / end を抜き出して照会する。
    func lookup(waypoints: [(coord: CLLocationCoordinate2D, time: Date)]) async {
        let token = UUID()
        currentToken = token

        let samples = sample(waypoints)
        guard !samples.isEmpty else {
            places = []
            return
        }

        isLoading = true
        var result: [Place] = []
        for sample in samples {
            guard currentToken == token else { return }   // 新しい照会に追い抜かれた
            if let name = await name(for: sample.coord) {
                // 直前と同じ地名なら重複させない。
                if result.last?.name != name {
                    result.append(Place(name: name, time: sample.time))
                }
            }
        }
        guard currentToken == token else { return }
        places = result
        isLoading = false
    }

    // MARK: - 内部

    /// 先頭・末尾を必ず含めつつ等間隔で最大 maxPoints 点を抜き出す。
    private func sample(_ waypoints: [(coord: CLLocationCoordinate2D, time: Date)])
        -> [(coord: CLLocationCoordinate2D, time: Date)] {
        guard waypoints.count > maxPoints else { return waypoints }
        var picked: [(coord: CLLocationCoordinate2D, time: Date)] = []
        for i in 0..<maxPoints {
            let idx = Int(Double(i) / Double(maxPoints - 1) * Double(waypoints.count - 1))
            picked.append(waypoints[idx])
        }
        return picked
    }

    /// 散歩で意味のある粒度で地名を作る(POI名 → 地区 → 通り → 市区町村)。
    private func name(for coord: CLLocationCoordinate2D) async -> String? {
        let key = String(format: "%.3f,%.3f", coord.latitude, coord.longitude)
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }

        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        // CLGeocoder は非 Sendable。ローカルに作り、await の受け手として一度だけ使って
        // 以後参照しないことで Swift 6 の region 分離(sending)を満たす。
        let name = await Self.reverseGeocodeName(location)
        cache[key] = name ?? ""   // 失敗(nil)も覚えてリトライ地獄を避ける
        return name
    }

    /// 完了ハンドラ版を継続でラップし、Sendable な String だけを主アクターへ返す。
    /// `private` ではない: 探索マップのフロンティア候補地名にも同じロジックを再利用する
    /// (`ExploreMapView`)。
    static func reverseGeocodeName(_ location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location,
                                            preferredLocale: Locale(identifier: "ja_JP")) { placemarks, _ in
                withExtendedLifetime(geocoder) {}   // 完了まで geocoder を生かす
                continuation.resume(returning: placemarks?.first.flatMap(displayName))
            }
        }
    }

    /// 逆ジオコーダーが areasOfInterest として広域に返してくる島名。地名としては無意味なので除外。
    private nonisolated static let islandNames: Set<String> = ["本州", "北海道", "九州", "四国", "沖縄本島", "淡路島", "佐渡島"]

    /// 散歩で意味のある粒度で地名を作る: POI名(島名除く)→ 町名 → 通り → 市区町村。
    private nonisolated static func displayName(_ p: CLPlacemark) -> String? {
        p.areasOfInterest?.first(where: { !islandNames.contains($0) })
            ?? p.subLocality
            ?? p.thoroughfare
            ?? p.locality
    }
}
