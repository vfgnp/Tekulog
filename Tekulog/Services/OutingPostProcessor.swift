import CoreData
import CoreLocation

/// 確定済みの外出1件に対する後処理: 外出目的の自動判定(`OutingClassifier`)と、
/// 探索グリッドへの反映(`ExplorationService`)、その結果の保存。
/// ライブ確定(`SessionCoordinator.finalize`)・未分類バックフィル・グリッド再構築
/// (`ExplorationBackfillService`)の3経路が同じ処理を通る。
///
/// **入口と本体の2段構え**(`ExplorationService.outingGate` は再入不可):
/// - 入口(`processFinalized` / `processBackfill`)は自分でゲートを取る。
/// - 本体(`replayHoldingGate`)はゲートを取らない。グリッド再構築がゲートを保持したまま呼ぶ。
struct OutingPostProcessor: Sendable {
    private let repository: WalkRepository
    private let explorationService: ExplorationService
    private let classifier: OutingClassifier

    init(repository: WalkRepository, explorationService: ExplorationService) {
        self.repository = repository
        self.explorationService = explorationService
        self.classifier = OutingClassifier(repository: repository)
    }

    // MARK: - ゲートを取る入口

    /// ライブ確定用。ルート座標が取得できなければ何もしない(未分類のまま残り、次回起動の
    /// 未分類バックフィルが拾う)。
    func processFinalized(sessionID: NSManagedObjectID,
                          kind: ActivityKind,
                          startedAt: Date,
                          totalDistance: Double) async {
        await explorationService.outingGate.acquire()
        defer { explorationService.outingGate.release() }
        guard await needsProcessing(sessionID),
              let coordinates = try? await repository.fetchRouteCoordinates(for: sessionID) else { return }
        await classifyAndRecord(sessionID: sessionID, kind: kind, startedAt: startedAt,
                                totalDistance: totalDistance, coordinates: coordinates)
    }

    /// 未分類バックフィル用。ルート座標が取得できなくても空の経路として分類まで行う
    /// (未分類のまま残すと、バックフィルが同じセッションを拾い続ける)。
    func processBackfill(sessionID: NSManagedObjectID,
                         kind: ActivityKind,
                         startedAt: Date,
                         totalDistance: Double) async {
        await explorationService.outingGate.acquire()
        defer { explorationService.outingGate.release() }
        guard await needsProcessing(sessionID) else { return }
        let coordinates = (try? await repository.fetchRouteCoordinates(for: sessionID)) ?? []
        await classifyAndRecord(sessionID: sessionID, kind: kind, startedAt: startedAt,
                                totalDistance: totalDistance, coordinates: coordinates)
    }

    // MARK: - ゲートを取らない本体(グリッド再構築用)

    /// グリッド再構築が、確定済みセッションを古い順に1件ずつ再生する。
    /// **呼び出し側が `outingGate` を保持していること。**
    /// 分類済みなら新エリア数だけを書き直し(外出目的には触れない)、未分類なら分類も行う。
    /// 再生の途中で削除されたセッションは読み飛ばす。それ以外の失敗は投げる(再構築を中止させ、
    /// 誤った状態のままグリッドの版数が進まないようにする)。
    func replayHoldingGate(_ session: FinalizedSessionRef) async throws {
        guard let coordinates = try await repository.fetchRouteCoordinatesIfExists(for: session.id) else { return }
        let newCellCount = try await explorationService.recordVisited(coordinates: coordinates,
                                                                      firstSeenAt: session.startedAt)
        if session.isClassified {
            try await repository.setExploredNewCellCount(sessionID: session.id, count: newCellCount)
        } else {
            let purpose = await classify(sessionID: session.id, kind: session.kind, startedAt: session.startedAt,
                                         totalDistance: session.totalDistance, coordinates: coordinates)
            try await repository.finalizeClassification(sessionID: session.id, purpose: purpose,
                                                        newCellCount: newCellCount)
        }
    }

    // MARK: - 共通処理

    /// まだ処理していないセッションか。外出の保存(`endedAt`)はゲートの外で行われるので、
    /// 保存直後にグリッド再構築がゲートを取ると、そのセッションは再構築で処理された後に
    /// 自分の確定後処理がもう一度走る。2回目は何もしない(再分類のための通信も省ける)。
    /// 確認に失敗した場合も何もしない(未分類なら次回起動のバックフィルが拾う)。
    private func needsProcessing(_ sessionID: NSManagedObjectID) async -> Bool {
        (try? await repository.isClassified(sessionID: sessionID)) == false
    }

    private func classifyAndRecord(sessionID: NSManagedObjectID,
                                   kind: ActivityKind,
                                   startedAt: Date,
                                   totalDistance: Double,
                                   coordinates: [CLLocationCoordinate2D]) async {
        // 分類(店舗検索の通信で数秒かかりうる)を先に済ませ、セルの記録と新エリア数の保存を
        // 続けて行う。記録と保存の間が空くと、その間にプロセスが終了したとき「セルは保存済み・
        // 外出は未分類」で残り、次回のやり直しでは新規 0 件と数えられて新エリア数が失われる。
        let purpose = await classify(sessionID: sessionID, kind: kind, startedAt: startedAt,
                                     totalDistance: totalDistance, coordinates: coordinates)
        // 探索グリッドへの反映に失敗したら、分類済みにせず終える。未分類のまま残せば、次回起動の
        // 未分類バックフィルがやり直す(ここで分類済みにすると、歩いた場所が晴れないまま固定される)。
        guard let newCellCount = try? await explorationService.recordVisited(coordinates: coordinates,
                                                                             firstSeenAt: startedAt) else { return }
        // `classifiedAt` が未設定のときだけ書く(`WalkRepository.finalizeClassification` のガード)。
        try? await repository.finalizeClassification(sessionID: sessionID, purpose: purpose, newCellCount: newCellCount)
    }

    private func classify(sessionID: NSManagedObjectID,
                          kind: ActivityKind,
                          startedAt: Date,
                          totalDistance: Double,
                          coordinates: [CLLocationCoordinate2D]) async -> OutingPurpose {
        await classifier.classify(kind: kind,
                                  sessionID: sessionID,
                                  startedAt: startedAt,
                                  coordinates: coordinates,
                                  totalDistance: totalDistance,
                                  home: TekTheme.homeCoordinate())
    }
}
