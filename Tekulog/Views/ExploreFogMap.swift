import SwiftUI
import MapKit
import os

/// 探索マップの地図本体。`MKMapView` に「世界全体を覆うフォグのオーバーレイ」を1枚載せ、
/// 開拓済みセルを抜いて描く(描画の中身は `FogPainter`)。
///
/// **SwiftUI の `Map` に `Canvas` を重ねる方式に戻さないこと。** 重ねた描画は地図の描画と同じ
/// フレームに同期せず、画面座標で描くので、拡大・縮小・移動の操作中に晴れが地図からズレる
/// (実際に起きた不具合。`design/explore-map/01-requirements.md` の原因 A〜D)。オーバーレイは
/// 地図座標で描かれ、パン・ズーム・回転・ピッチへの追従を MapKit が行うので、アプリ側には
/// カメラ変更に反応するコードが一切ない。iOS 18 の SwiftUI `Map` はカスタム描画の
/// オーバーレイを持たないため、この部分だけ UIKit をラップしている。
struct ExploreFogMap: UIViewRepresentable {
    struct Pin: Identifiable, Equatable {
        let id: String
        let latitude: Double
        let longitude: Double
        let title: String
    }

    /// 地図を指定の地点へアニメーション移動させる要求。`id` が前回と変わったときだけ適用する。
    struct CameraRequest: Equatable {
        let id: Int
        let latitude: Double
        let longitude: Double
        let spanDegrees: Double
    }

    let home: CLLocationCoordinate2D
    let frontierPins: [Pin]
    let fogIndex: FogCellIndex
    /// `fogIndex` を差し替えるたびに増やす番号(索引そのものは比較しない)。
    let fogGeneration: Int
    let cameraRequest: CameraRequest?

    /// 初期表示の範囲(度)。自宅を中心に約 3km 四方。
    private static let initialSpanDegrees = 0.03

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        // 大きさ 0 のまま領域を設定すると縮尺が決まらないので、仮の大きさを与えておく
        // (SwiftUI が実際の大きさに直すとき、中心と縮尺は保たれる)。
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.register(MKMarkerAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: Coordinator.pinReuseIdentifier)
        // 地名ラベルより上に置く(フォグは地名ごと覆う)。注釈は常にオーバーレイより手前に描かれる。
        mapView.addOverlay(context.coordinator.overlay, level: .aboveLabels)
        var spanDegrees = Self.initialSpanDegrees
        #if DEBUG
        // スクショ・縮尺確認用: `-demoMapSpanDegrees X` で初期表示の範囲を変える(simctl は地図を操作できないため)。
        let demoSpan = UserDefaults.standard.double(forKey: "demoMapSpanDegrees")
        if demoSpan > 0 { spanDegrees = demoSpan }
        #endif
        let span = MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
        mapView.setRegion(MKCoordinateRegion(center: home, span: span), animated: false)
        context.coordinator.apply(self, to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.apply(self, to: mapView)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        static let pinReuseIdentifier = "ExplorePin"

        let overlay = FogOverlay()
        private var renderer: FogOverlayRenderer?
        private var appliedFogGeneration: Int?
        private var appliedCameraRequestID: Int?
        private var homeAnnotation: ExplorePinAnnotation?
        private var frontierAnnotations: [String: ExplorePinAnnotation] = [:]

        /// SwiftUI 側の最新の値を地図へ反映する(変わった部分だけ)。
        func apply(_ map: ExploreFogMap, to mapView: MKMapView) {
            if appliedFogGeneration != map.fogGeneration {
                appliedFogGeneration = map.fogGeneration
                overlay.index = map.fogIndex
                renderer?.setNeedsDisplay()
            }

            if homeAnnotation?.coordinate.latitude != map.home.latitude
                || homeAnnotation?.coordinate.longitude != map.home.longitude {
                if let homeAnnotation { mapView.removeAnnotation(homeAnnotation) }
                let annotation = ExplorePinAnnotation(kind: .home, coordinate: map.home, title: "自宅")
                homeAnnotation = annotation
                mapView.addAnnotation(annotation)
            }

            // 無くなった候補と、題名(地名)が変わった候補のマーカーを外す。後者は下で付け直す。
            let wanted = Dictionary(map.frontierPins.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            for (id, annotation) in frontierAnnotations where wanted[id] != annotation.title {
                mapView.removeAnnotation(annotation)
                frontierAnnotations[id] = nil
            }
            for pin in map.frontierPins where frontierAnnotations[pin.id] == nil {
                let annotation = ExplorePinAnnotation(
                    kind: .frontier,
                    coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude),
                    title: pin.title)
                frontierAnnotations[pin.id] = annotation
                mapView.addAnnotation(annotation)
            }

            if let request = map.cameraRequest, request.id != appliedCameraRequestID {
                appliedCameraRequestID = request.id
                let region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: request.latitude, longitude: request.longitude),
                    span: MKCoordinateSpan(latitudeDelta: request.spanDegrees, longitudeDelta: request.spanDegrees))
                mapView.setRegion(region, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let fog = overlay as? FogOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = FogOverlayRenderer(overlay: fog)
            self.renderer = renderer
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? ExplorePinAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.pinReuseIdentifier, for: pin)
            if let marker = view as? MKMarkerAnnotationView {
                switch pin.kind {
                case .home:
                    marker.markerTintColor = UIColor(TekTheme.primary)
                    marker.glyphImage = UIImage(systemName: "house.fill")
                case .frontier:
                    marker.markerTintColor = UIColor(TekTheme.amber)
                    marker.glyphImage = UIImage(systemName: "questionmark.circle")
                }
                // 他の注釈や地名との衝突回避で隠されないようにする。
                marker.displayPriority = .required
            }
            return view
        }

        #if DEBUG
        /// タイルの縮尺(`draw` に渡る `zoomScale`)と実際の表示縮尺の関係を確認するためのログ。
        /// `FogPainter.tileScaleMargin` の根拠になる。
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard mapView.bounds.width > 0, mapView.visibleMapRect.width > 0 else { return }
            let displayScale = Double(mapView.bounds.width) / mapView.visibleMapRect.width
            let tileScale = overlay.lastDrawnZoomScale
            AppLog.lifecycle.debug("探索マップ縮尺: 表示=\(displayScale, privacy: .public) タイル=\(tileScale, privacy: .public) 比(表示/タイル)=\(tileScale > 0 ? displayScale / tileScale : 0, privacy: .public) 画面幅=\(mapView.region.span.longitudeDelta * 111_320 * cos(mapView.region.center.latitude * .pi / 180), privacy: .public)m")
        }
        #endif
    }
}

/// 世界全体を覆うフォグのオーバーレイ。描画に使うセル索引を保持する。
///
/// `@unchecked Sendable`: 可変状態は `state` だけで、ロックで保護している。索引は MainActor
/// (`ExploreFogMap.Coordinator`)が差し替え、描画スレッド(`FogOverlayRenderer.draw`)が読む。
final class FogOverlay: NSObject, MKOverlay, @unchecked Sendable {
    private struct State {
        var index = FogCellIndex.empty
        var lastDrawnZoomScale = 0.0
    }

    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    /// 原点が世界原点なので、レンダラの描画座標は地図ポイント(`MKMapPoint`)そのものになる。
    let boundingMapRect = MKMapRect.world

    private let state = OSAllocatedUnfairLock(initialState: State())

    var index: FogCellIndex {
        get { state.withLock { $0.index } }
        set { state.withLock { $0.index = newValue } }
    }

    /// 最後に描いたタイルの縮尺(DEBUG の確認ログ用)。
    var lastDrawnZoomScale: Double {
        get { state.withLock { $0.lastDrawnZoomScale } }
        set { state.withLock { $0.lastDrawnZoomScale = newValue } }
    }
}

/// フォグをタイル単位で描く。`draw` は MapKit のバックグラウンドスレッドから複数同時に
/// 呼ばれるので、触るのは不変の `FogCellIndex`(スナップショット)と引数の `context` だけにする。
final class FogOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fog = overlay as? FogOverlay else { return }
        #if DEBUG
        fog.lastDrawnZoomScale = Double(zoomScale)
        #endif
        FogPainter.draw(index: fog.index, mapRect: mapRect, zoomScale: Double(zoomScale),
                        style: .standard, in: context)
    }
}

/// 探索マップのマーカー(自宅 / 未開拓方向の候補)。
final class ExplorePinAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case home
        case frontier
    }

    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(kind: Kind, coordinate: CLLocationCoordinate2D, title: String) {
        self.kind = kind
        self.coordinate = coordinate
        self.title = title
    }
}
