import SwiftUI
import MapKit
import CoreLocation

/// 自宅位置の設定(マイページから遷移)。住所検索でおおまかな地点を選び、
/// 地図をパンして中心ピンで微調整してから確定する。
/// 探索マップの基準点、および外出目的の自動判定(通勤/お買い物/散歩)に使われる。
/// 検索は MKLocalSearch(Apple のサービス)のみを使い、開発者サーバへは何も送らない。
struct HomeLocationSettingView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TekTheme.Keys.homeLatitude) private var storedLatitude = 0.0
    @AppStorage(TekTheme.Keys.homeLongitude) private var storedLongitude = 0.0
    @AppStorage(TekTheme.Keys.homeAddressLabel) private var storedLabel = ""
    @AppStorage(TekTheme.Keys.homeLocationIsSet) private var storedIsSet = false

    @StateObject private var completer = AddressSearchCompleter()
    @State private var query = ""
    @State private var camera: MapCameraPosition
    @State private var currentCenter: CLLocationCoordinate2D
    @State private var pinLabel: String

    private static let fallbackCenter = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671) // 東京駅

    init() {
        let home = TekTheme.homeCoordinate()
        let center = home ?? Self.fallbackCenter
        _camera = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))))
        _currentCenter = State(initialValue: center)
        _pinLabel = State(initialValue: UserDefaults.standard.string(forKey: TekTheme.Keys.homeAddressLabel) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !completer.results.isEmpty {
                resultsList
            } else {
                mapArea
                confirmButton
            }
        }
        .background(TekTheme.background)
        .navigationTitle("自宅位置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, newValue in completer.update(query: newValue) }
    }

    // MARK: - 検索

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TekTheme.sub)
            TextField("住所や建物名で検索", text: $query)
                .font(.system(size: 15, weight: .medium))
            if !query.isEmpty {
                Button {
                    query = ""
                    completer.update(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TekTheme.disabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .padding(16)
    }

    private var resultsList: some View {
        List(completer.results, id: \.self) { result in
            Button {
                select(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TekTheme.ink)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TekTheme.sub)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        Task {
            guard let resolved = await Self.resolve(completion) else { return }
            currentCenter = resolved.coordinate
            camera = .region(MKCoordinateRegion(
                center: resolved.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
            pinLabel = resolved.name ?? completion.title
            query = ""
            completer.update(query: "")
        }
    }

    /// 完了ハンドラ版を継続でラップし、Sendable な値だけを返す
    /// (`MKLocalSearch.Response` は Sendable ではないため async 版をそのまま await できない。
    /// `PlaceLookupService.reverseGeocodeName` と同じパターン)。
    private static func resolve(_ completion: MKLocalSearchCompletion) async -> (coordinate: CLLocationCoordinate2D, name: String?)? {
        await withCheckedContinuation { continuation in
            let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
            search.start { response, _ in
                withExtendedLifetime(search) {}
                guard let item = response?.mapItems.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (item.placemark.coordinate, item.name))
            }
        }
    }

    // MARK: - 地図(中心固定ピンでパン調整)

    private var mapArea: some View {
        ZStack {
            Map(position: $camera)
                .onMapCameraChange(frequency: .onEnd) { context in
                    currentCenter = context.region.center
                }
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(TekTheme.coral)
                .shadow(radius: 3, y: 2)
                .offset(y: -17)
            Circle()
                .fill(TekTheme.coral.opacity(0.3))
                .frame(width: 8, height: 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
    }

    private var confirmButton: some View {
        VStack(spacing: 6) {
            if !pinLabel.isEmpty {
                Text(pinLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TekTheme.sub)
            }
            Button {
                storedLatitude = currentCenter.latitude
                storedLongitude = currentCenter.longitude
                storedLabel = pinLabel.isEmpty ? "自宅" : pinLabel
                storedIsSet = true
                dismiss()
            } label: {
                Text("この場所を自宅に設定")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TekTheme.primary, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
    }
}

/// `MKLocalSearchCompleter` の SwiftUI 向けラッパー。
@MainActor
final class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // `completer.results`([MKLocalSearchCompletion])は Sendable ではないため、
        // nonisolated 側で取り出さず MainActor に戻ってから self.completer 経由で読む。
        Task { @MainActor in
            self.results = self.completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.results = []
        }
    }
}
