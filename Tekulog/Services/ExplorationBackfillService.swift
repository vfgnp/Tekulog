import Foundation

/// 探索マップ機能を追加する前から存在する確定済みセッションには、`ExploredCell` の記録も
/// 外出目的の分類もまだない。アプリ起動のたびに未処理セッション(`classifiedAt == nil`)を
/// `startedAt` 昇順で少しずつ再生し、追いつくまで処理する。
///
/// `classifiedAt` ベースの判定を使うため(UserDefaults のカーソル日時ではなく)、
/// 処理中にライブ確定が新しいセッションを先に処理しても衝突しない
/// (`WalkRepository.finalizeClassification` の `classifiedAt` ガードと、
/// `ExplorationService` の単一 context 直列化を参照)。中断しても再開時に重複処理しない。
final class ExplorationBackfillService {
    private static let completedKey = "explorationBackfillCompleted"

    private let repository: WalkRepository
    private let classifier: OutingClassifier
    private let explorationService: ExplorationService

    /// `explorationService` はライブ確定経路(`SessionCoordinator`)と同じインスタンスを
    /// 呼び出し側から渡すこと(`ExplorationService` のドキュメント参照)。
    init(explorationService: ExplorationService, repository: WalkRepository = WalkRepository()) {
        self.repository = repository
        self.explorationService = explorationService
        self.classifier = OutingClassifier(repository: repository)
    }

    /// 未処理セッションがなくなるまで1件ずつ処理する。既に完了済みなら即座に戻る。
    func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
        while let next = try? await repository.fetchOldestUnclassifiedSession() {
            let coordinates = (try? await repository.fetchRouteCoordinates(for: next.id)) ?? []
            let home = TekTheme.homeCoordinate()
            let purpose = await classifier.classify(kind: next.kind,
                                                     sessionID: next.id,
                                                     startedAt: next.startedAt,
                                                     coordinates: coordinates,
                                                     totalDistance: next.totalDistance,
                                                     home: home)
            let newCellCount = (try? await explorationService.recordVisited(
                coordinates: coordinates, firstSeenAt: next.startedAt)) ?? 0
            try? await repository.finalizeClassification(sessionID: next.id, purpose: purpose, newCellCount: newCellCount)
        }
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }
}
