import CoreData

/// アプリ起動時(画面を伴う起動の `.task`)に、探索グリッドと外出目的の分類を
/// 「保存済みのセッションから導ける正しい状態」へ追いつかせる。仕事は2つ:
///
/// 1. **グリッド再構築**: グリッドの定義(`ExplorationGrid`)が変わった版へ更新された最初の起動で、
///    `ExploredCell` を全削除し、確定済みの全セッションを `startedAt` 昇順で再生して、セルと
///    各セッションの新エリア数を作り直す。分類済みの外出目的(手動変更を含む)には触れない。
///    完了時にだけグリッドの版数を保存するので、途中で中断・失敗しても次回起動で最初から
///    やり直す(冪等)。
/// 2. **未分類バックフィル**: 未分類のセッション(`classifiedAt == nil`)を、古い順に分類・反映する。
///    探索マップ機能を追加する前から存在するセッションと、ライブ確定で後処理が完了しなかった
///    セッションがここで拾われる。
///
/// どちらも `ExplorationService.outingGate` でライブ確定(`SessionCoordinator.finalize`)と
/// 直列化される(`OutingPostProcessor` 参照)。`explorationService` はライブ確定経路と同じ
/// インスタンスを呼び出し側から渡すこと(`ExplorationService` のドキュメント参照)。
///
/// `@unchecked Sendable`: 保持するのは不変の参照だけで、それぞれが自身でスレッド安全
/// (`WalkRepository` / `ExplorationService` / `OutingPostProcessor`。`UserDefaults` は
/// スレッド安全と文書化されているが、この SDK では `Sendable` に印付けされていない)。
final class ExplorationBackfillService: @unchecked Sendable {
    static let gridVersionKey = "explorationGridVersion"
    /// 1 = 点自身の緯度で経度セル幅を決めていた旧グリッド(キー未設定も 1 とみなす)。
    /// 2 = 緯度行ごとに経度セル幅を固定したグリッド(`ExplorationGrid`)。
    static let currentGridVersion = 2

    private let repository: WalkRepository
    private let explorationService: ExplorationService
    private let postProcessor: OutingPostProcessor
    private let defaults: UserDefaults
    /// 再構築でセッション1件を再生する処理。既定は `OutingPostProcessor.replayHoldingGate`。
    /// 差し替えられるのは、再生の失敗を単体テストで起こすため。
    private let replay: @Sendable (FinalizedSessionRef) async throws -> Void

    init(explorationService: ExplorationService,
         repository: WalkRepository = WalkRepository(),
         defaults: UserDefaults = .standard,
         replay: (@Sendable (FinalizedSessionRef) async throws -> Void)? = nil) {
        let postProcessor = OutingPostProcessor(repository: repository, explorationService: explorationService)
        self.repository = repository
        self.explorationService = explorationService
        self.postProcessor = postProcessor
        self.defaults = defaults
        self.replay = replay ?? { try await postProcessor.replayHoldingGate($0) }
    }

    func runIfNeeded() async {
        if defaults.integer(forKey: Self.gridVersionKey) < Self.currentGridVersion {
            await rebuildGrid()
            // 再構築に失敗した(版数が進んでいない)ら、今回はここまで。次回起動で再試行する。
            guard defaults.integer(forKey: Self.gridVersionKey) >= Self.currentGridVersion else { return }
        }
        await backfillUnclassified()
    }

    // MARK: - グリッド再構築

    private func rebuildGrid() async {
        await explorationService.outingGate.acquire()
        defer { explorationService.outingGate.release() }
        // 版数の確認はゲート取得後に行う(`runIfNeeded` が重ねて呼ばれても、再構築は1回だけ)。
        guard defaults.integer(forKey: Self.gridVersionKey) < Self.currentGridVersion else { return }

        explorationService.rebuildState.send(true)
        defer { explorationService.rebuildState.send(false) }
        do {
            try await explorationService.resetAllCells()
            let sessions = try await repository.fetchFinalizedSessions()
            AppLog.lifecycle.notice("探索グリッド再構築: 開始 セッション数=\(sessions.count, privacy: .public)")
            for session in sessions {
                try await replay(session)
            }
            // 全件成功したときだけ版数を進める。
            defaults.set(Self.currentGridVersion, forKey: Self.gridVersionKey)
            AppLog.lifecycle.notice("探索グリッド再構築: 完了")
        } catch {
            AppLog.lifecycle.error("探索グリッド再構築: 失敗(次回起動で再試行) \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 未分類バックフィル

    /// 未分類セッション(`classifiedAt == nil`)がなくなるまで、古い順に1件ずつ処理する。
    ///
    /// **起動のたびに確認する**(「一度完了したら以後は見ない」フラグは持たない)。未分類は
    /// 探索機能の導入前のセッションだけでなく、確定後処理の途中でプロセスが終了した・経路の
    /// 取得に失敗した、といった場合にも後から生じる。拾わないと、その外出は探索マップに
    /// 晴れとして出ないまま残る。未分類が無ければ fetch 1回で終わる。
    ///
    /// `classifiedAt` ベースの判定なので、処理中にライブ確定が新しいセッションを先に処理しても
    /// 衝突せず、中断しても再開時に重複処理しない。
    private func backfillUnclassified() async {
        var lastID: NSManagedObjectID?
        while true {
            // 未分類が無ければ終わり。取得に失敗した場合も中断する(次回起動で再試行)。
            guard let next = try? await repository.fetchOldestUnclassifiedSession() else { return }
            // 直前と同じセッションが返ってきた = 処理が進んでいない(保存に失敗し続けている)。
            // 同じセッションを拾い続けないよう中断し、次回起動で再試行する。
            if next.id == lastID { return }
            lastID = next.id
            await postProcessor.processBackfill(sessionID: next.id,
                                                kind: next.kind,
                                                startedAt: next.startedAt,
                                                totalDistance: next.totalDistance)
        }
    }
}
