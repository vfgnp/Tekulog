import Foundation
import CoreData
import CoreLocation
import Combine

/// アプリの中核。低電力トリガー(ActivityDetector)を購読し、検知後だけ
/// GPS と歩数計を回し、停止検知でセッションを確定保存する。
///
/// 状態は `@Published` で UI に公開する。
@MainActor
final class SessionCoordinator: ObservableObject {

    /// プロセス唯一のインスタンス。SwiftUI(`TekulogApp`)と AppDelegate(SLC による
    /// ヘッドレス background relaunch)の両方から同じ実体に到達するために共有する。
    static let shared = SessionCoordinator()

    /// 記録中の進行状況(UI 表示用)。
    struct LiveStats {
        var kind: ActivityKind
        var startedAt: Date
        var distanceMeters: Double = 0
        var steps: Int = 0
        /// 進行中ルート(記録中画面のポリライン用、インメモリ)。上限で先頭を間引く。
        var coordinates: [CLLocationCoordinate2D] = []
    }

    /// 記録中画面のポリラインが際限なく伸びないための上限点数。
    private let liveCoordinateCap = 5000

    @Published private(set) var live: LiveStats?

    /// 記録中かどうか(`live != nil` と等価の便利アクセサ)。
    var isRecording: Bool { live != nil }

    private let detector: ActivityDetector
    private let locationTracker: LocationTracker
    private let pedometer: PedometerService
    private let healthKit: HealthKitService
    private let notifications: NotificationService
    private let repository: WalkRepository
    private let backgroundWake: BackgroundWakeService
    /// 24時間歩数台帳。ホーム画面が todaySteps を直接 observe するため公開。
    let stepLedger: StepLedgerService
    /// 探索グリッド(ExploredCell)の読み書き。ライブ確定とバックフィルが同じインスタンスを
    /// 共有することで二重カウントを防ぐ(ExplorationService のドキュメント参照)。
    let explorationService: ExplorationService
    private let classifier: OutingClassifier

    // 現在セッションの状態
    private var sessionID: NSManagedObjectID?
    /// 進行中セッションの UUID。WalkSession.id と同値で、通知の識別と
    /// 非同期生成の競合(生成完了前に終了)検出のトークンを兼ねる。
    private var currentSessionUUID: UUID?
    private var currentKind: ActivityKind?
    private var startedAt: Date?
    private var accumulatedDistance: Double = 0
    private var lastLocation: CLLocation?

    // ルート点バッファ
    private var pendingSamples: [RouteSample] = []
    private var flushTimer: Timer?

    // 候補バッファ(先行GPSバッファリング)。sustained 確定前に先行起動した GPS 点を貯める。
    // 確定(beginSession)で同 kind ならルート先頭に接続、キャンセルで破棄する。
    private var candidateKind: ActivityKind?
    private var candidateSamples: [RouteSample] = []

    init(detector: ActivityDetector = ActivityDetector(),
         locationTracker: LocationTracker = LocationTracker(),
         pedometer: PedometerService = PedometerService(),
         healthKit: HealthKitService = HealthKitService(),
         notifications: NotificationService = NotificationService(),
         repository: WalkRepository = WalkRepository(),
         backgroundWake: BackgroundWakeService = BackgroundWakeService(),
         stepLedger: StepLedgerService = StepLedgerService(),
         explorationService: ExplorationService = ExplorationService()) {
        self.detector = detector
        self.locationTracker = locationTracker
        self.pedometer = pedometer
        self.healthKit = healthKit
        self.notifications = notifications
        self.repository = repository
        self.backgroundWake = backgroundWake
        self.stepLedger = stepLedger
        self.explorationService = explorationService
        self.classifier = OutingClassifier(repository: repository)

        wire()
    }

    /// アプリ起動直後に呼ぶ。通知カテゴリ/デリゲートを設定する。
    func bootstrap() {
        notifications.configure()
    }

    /// 監視が起動済みか(SwiftUI `.task` と AppDelegate 相乗りの二重起動防止)。
    private var isMonitoring = false

    /// 自動検知の監視を開始する。Motion 権限プロンプトはこの時点で表示される。
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        detector.start()
        backgroundWake.start()
        stepLedger.refresh()
    }

    /// 歩数台帳の更新(フォアグラウンド復帰時などに UI 側から呼ぶ。内部 throttle 付き)。
    func refreshStepLedger() {
        stepLedger.refresh()
    }

    /// UI からの手動開始。種別は散歩/自転車。
    /// (detector のモード同期は beginSession が一元管理する。手動でも stationary 自動終了が効く。)
    func startManually(kind: ActivityKind) {
        guard !isRecording else { return }
        beginSession(kind: kind)
    }

    /// UI からの手動停止。
    func stopManually() {
        guard isRecording else { return }
        endSession(stoppedAt: Date())
    }

    /// バックグラウンドウェイク(位置更新/SLC relaunch)時のエントリ。
    /// これは「suspend/終了からの復帰」専用のリカバリ経路: ライブ検知が生きている間は
    /// そちらが sustained(startDuration)ゲート付きで開始を判定するため、ここでは何も
    /// しない。ライブ検知の evaluate が最近動いていない(=suspend されていた)場合のみ、
    /// 履歴照会で進行中の活動を拾って即時再開する。
    /// これがないと、生存中も30秒毎の onWake が「最後のセグメントが walking なら即開始」
    /// で走り、sustained ゲートのすり抜け・手動停止の直後の勝手な再開が起きる。
    func handleBackgroundWake() {
        guard !isRecording, isAutoRecordEnabled else { return }
        if let alive = detector.lastEvaluatedAt,
           Date().timeIntervalSince(alive) < Tunables.liveDetectionFreshWindow {
            // ライブ検知が健在 → 開始判定はライブ経路に委ねる。
            return
        }
        AppLog.session.notice("handleBackgroundWake: ライブ検知が停止していた形跡 → 履歴照会開始")
        detector.detectOngoingActivity { [weak self] kind in
            guard let self, let kind, !self.isRecording else { return }
            AppLog.session.notice("handleBackgroundWake: kind=\(kind.rawValue, privacy: .public) で自動開始")
            self.beginSession(kind: kind)
        }
    }

    /// 直近の活動履歴をログ出力する(調査用)。フォアグラウンド復帰時に呼ぶ。
    func logMotionHistory() {
        detector.logRecentHistory()
    }

    /// オンボーディングからの権限要求パススルー(権限はプロセス全体に効くため
    /// Coordinator 所有のインスタンス経由で要求してよい)。
    func requestNotificationAuthorization() async {
        await notifications.requestAuthorization()
    }

    func requestHealthKitAuthorization() async {
        try? await healthKit.requestAuthorization()
    }

    // MARK: - 配線

    /// 自動記録のON/OFF(マイページ設定)。未設定は ON。
    private var isAutoRecordEnabled: Bool {
        UserDefaults.standard.object(forKey: TekTheme.Keys.autoRecordEnabled) as? Bool ?? true
    }

    private func wire() {
        detector.onShouldStart = { [weak self] kind in
            guard let self else { return }
            guard self.isAutoRecordEnabled else {
                // 開始を握り潰したので検知を再武装する。detector は onShouldStart の直前に
                // .tracking へ遷移済みのため、ここで戻さないと自動検知が二度と発火しない
                // (「モード同期は beginSession/endSession が一元管理」の唯一の例外)。
                AppLog.session.notice("自動開始を無視(自動記録OFF設定)")
                self.detector.setMode(.idle)
                // setMode で ActivityDetector 側の movingKind は nil に戻るため、以後の
                // stationary/automotive 遷移では onCandidateCancelled が二度と発火しない。
                // 候補バッファ(先行GPS)が残っているとここで回収しない限り GPS が
                // 回りっぱなしになるので、明示的に破棄する。
                self.cancelCandidateBuffer()
                return
            }
            self.beginSession(kind: kind)
        }
        detector.onShouldStop = { [weak self] stoppedAt in
            self?.endSession(stoppedAt: stoppedAt)
        }
        detector.onCandidateStart = { [weak self] kind in
            self?.beginCandidateBuffer(kind: kind)
        }
        detector.onCandidateCancelled = { [weak self] in
            self?.cancelCandidateBuffer()
        }
        locationTracker.onSample = { [weak self] sample in
            guard let self else { return }
            if self.isRecording {
                self.ingest(sample)
            } else if self.candidateKind != nil {
                self.appendCandidateSample(sample)
            }
            // どちらでもなければ stop() 直後の競合で漏れてきた点として破棄する。
        }
        pedometer.onUpdate = { [weak self] snapshot in
            self?.live?.steps = snapshot.steps
        }
        notifications.onDiscardRequested = { [weak self] uuid in
            Task { try? await self?.repository.deleteSession(withID: uuid) }
        }
        backgroundWake.onWake = { [weak self] in
            // ついでに歩数台帳も更新(内部 throttle があるので安価)。
            self?.stepLedger.refresh()
            self?.handleBackgroundWake()
        }
    }

    // MARK: - 候補バッファ(先行GPSバッファリング)

    /// 「歩行っぽい」候補を検知した瞬間、確定を待たずに GPS を先行起動してバッファに貯め始める。
    private func beginCandidateBuffer(kind: ActivityKind) {
        // 自動記録OFF設定なら候補段階での先行GPS起動もしない(手動開始は候補バッファなしでも
        // 現在時刻起点で機能するので支障はなく、無駄な GPS 起動を避けられる)。
        guard !isRecording, isAutoRecordEnabled else { return }
        if candidateKind != kind {
            candidateSamples.removeAll()
        }
        candidateKind = kind
        AppLog.session.notice("beginCandidateBuffer: kind=\(kind.rawValue, privacy: .public) 先行GPS起動")
        locationTracker.start()   // 既に isTracking なら内部ガードで no-op(warm-up 状態も壊れない)。
    }

    /// 候補が確定に至らず破棄されたとき、先行起動した GPS とバッファを破棄する。
    /// `guard !isRecording` は ActivityDetector 側の `mode == .idle` ガードが将来壊れても、
    /// セッション中の GPS だけは絶対に止めないための多重防御(最重要の安全弁)。
    private func cancelCandidateBuffer() {
        guard !isRecording else { return }
        guard candidateKind != nil else { return }
        AppLog.session.notice("cancelCandidateBuffer: 候補破棄 → GPS停止")
        candidateKind = nil
        candidateSamples.removeAll()
        locationTracker.stop()
    }

    /// 候補バッファへサンプルを追加する。上限到達後は「先頭を捨てる」のではなく
    /// 新規追加を止めるだけにする — 先頭(最古の点)は確定時に startedAt の根拠となる
    /// 最重要データのため、これを失うと候補継続が長引くケースほど効果が薄れてしまう。
    private func appendCandidateSample(_ sample: RouteSample) {
        guard candidateSamples.count < Tunables.candidateBufferCap else { return }
        candidateSamples.append(sample)
    }

    // MARK: - セッション開始

    private func beginSession(kind: ActivityKind) {
        guard sessionID == nil, currentSessionUUID == nil else {
            AppLog.session.notice("beginSession 無視(既にセッション進行中)")
            return
        }
        AppLog.session.notice("beginSession: kind=\(kind.rawValue, privacy: .public) GPS/歩数計 起動")
        // detector モード同期はここで一元管理(自動/手動/ウェイクの全経路で不変)。
        detector.setMode(.tracking)

        // 同 kind の候補バッファがあればルート先頭に接続する。SessionCoordinator 側の
        // 候補状態はここで即座に畳む(以降の onSample 再入があっても二重消費しないため)。
        var bufferedSamples: [RouteSample] = []
        if candidateKind == kind {
            bufferedSamples = candidateSamples
        }
        candidateKind = nil
        candidateSamples.removeAll()

        // バッファの最新点が古すぎる(=候補バッファリング中に GPS 配信が途切れた。
        // suspend からの復帰が handleBackgroundWake 経由で thaw 検出より先に走った場合など)なら、
        // 実測されていない空白をルートに直線で混入させる恐れがあるため、バッファ全体を信用しない。
        if let last = bufferedSamples.last,
           Date().timeIntervalSince(last.timestamp) > Tunables.candidateBufferMaxSampleAge {
            AppLog.session.error("beginSession: 候補バッファの配信に空白の疑い → 破棄しDate()にフォールバック")
            bufferedSamples = []
        }

        // バッファがあればその先頭(実測 GPS が最初に届いた時刻)を startedAt に採用する。
        // 異常に古い値(将来のリグレッションで候補キャンセルが漏れた場合の最終防波堤)なら
        // 破棄して現在時刻にフォールバックする。
        let earliestPlausible = Date().addingTimeInterval(
            -(Tunables.startDuration(for: kind) + Tunables.gpsWarmupMaxDuration + 30))
        let now: Date
        if let first = bufferedSamples.first, first.timestamp >= earliestPlausible {
            now = first.timestamp
        } else {
            if !bufferedSamples.isEmpty {
                AppLog.session.error("beginSession: 候補バッファの先頭時刻が異常に古い → 破棄しDate()にフォールバック")
                bufferedSamples = []
            }
            now = Date()
        }

        let uuid = UUID()
        currentSessionUUID = uuid
        currentKind = kind
        startedAt = now
        accumulatedDistance = 0
        lastLocation = nil
        pendingSamples.removeAll()

        live = LiveStats(kind: kind, startedAt: now)

        locationTracker.start()   // 候補経由で既に起動済みなら内部ガードで no-op。
        for sample in bufferedSamples {
            ingest(sample)   // 通常のライブ点と同じ経路で distance/座標/pendingSamples を構築。
        }
        pedometer.start(from: now)
        notifications.notifyRecordingStarted(kind: kind)
        startFlushTimer()

        Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await repository.beginSession(id: uuid, kind: kind, startedAt: now)
                // 生成完了までに終了/破棄/別セッション開始が起きていたら孤児を削除。
                guard self.currentSessionUUID == uuid else {
                    try? await self.repository.deleteSession(id)
                    return
                }
                self.sessionID = id
                self.flushPendingSamples()   // 生成前に溜まった点を書き出す
            } catch {
                // 生成に失敗したら(まだ同一セッションなら)記録を畳む。
                AppLog.session.error("beginSession: Core Data 生成失敗 \(error.localizedDescription, privacy: .public)")
                if self.currentSessionUUID == uuid {
                    self.endSession(discard: true)
                }
            }
        }
    }

    // MARK: - ルート取り込み

    private func ingest(_ sample: RouteSample) {
        // GPS 距離を加算。
        let location = CLLocation(latitude: sample.latitude, longitude: sample.longitude)
        if let last = lastLocation {
            accumulatedDistance += location.distance(from: last)
        }
        lastLocation = location
        live?.distanceMeters = accumulatedDistance
        live?.coordinates.append(location.coordinate)
        if let count = live?.coordinates.count, count > liveCoordinateCap {
            live?.coordinates.removeFirst(count - liveCoordinateCap)
        }

        pendingSamples.append(sample)
        if pendingSamples.count >= Tunables.pointFlushBatchSize {
            flushPendingSamples()
        }
    }

    private func flushPendingSamples() {
        guard let sessionID, !pendingSamples.isEmpty else { return }
        let batch = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        // ロック中の実地検証で「GPS 配信が生きていたか」を事後ログで裏取りするための痕跡。
        AppLog.session.debug("flush: \(batch.count, privacy: .public)点 総距離=\(Int(self.accumulatedDistance), privacy: .public)m")
        Task { [weak self] in
            do {
                try await self?.repository.appendPoints(batch, to: sessionID)
            } catch {
                // 書き込み失敗分は次フラッシュで再送せず破棄(連続失敗の堆積回避)。
            }
        }
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        let timer = Timer(timeInterval: Tunables.pointFlushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushPendingSamples() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    // MARK: - セッション終了

    /// - Parameter stoppedAt: 動きが実際に止まった時刻。停止検知(stopDuration 経過後)ではなく
    ///   この時刻を終了時刻に使い、所要時間・ペース・距離・エネルギーが末尾の静止時間で
    ///   水増しされるのを防ぐ。
    private func endSession(stoppedAt: Date? = nil, discard: Bool = false) {
        AppLog.session.notice("endSession: discard=\(discard, privacy: .public) stoppedAt=\(stoppedAt?.timeIntervalSince1970 ?? -1, privacy: .public)")
        // detector モード同期はここで一元管理。特に discard 経路(Core Data 生成失敗)は
        // ここ以外に setMode(.idle) の機会がなく、抜けると detector が .tracking のまま
        // 取り残されて以後の自動開始が二度と発火しなくなる。
        detector.setMode(.idle)
        locationTracker.stop()
        let finalSnapshot = pedometer.stop()
        flushTimer?.invalidate()
        flushTimer = nil
        flushPendingSamples()

        let kind = currentKind
        let start = startedAt
        let id = sessionID
        let uuid = currentSessionUUID
        let distance = accumulatedDistance

        // 状態リセット(次の検知に備える)。
        live = nil
        sessionID = nil
        currentSessionUUID = nil
        currentKind = nil
        startedAt = nil
        accumulatedDistance = 0
        lastLocation = nil

        guard !discard, let id, let uuid, let kind, let start else { return }

        // 終了時刻 = 実際に止まった時刻(無ければ現在)。開始より前にならないよう clamp。
        let endedAt = max(start, stoppedAt ?? Date())

        Task { [weak self] in
            await self?.finalize(sessionID: id,
                                 sessionUUID: uuid,
                                 kind: kind,
                                 start: start,
                                 end: endedAt,
                                 liveDistance: distance,
                                 pedometer: finalSnapshot)
        }
    }

    private func finalize(sessionID: NSManagedObjectID,
                          sessionUUID: UUID,
                          kind: ActivityKind,
                          start: Date,
                          end: Date,
                          liveDistance: Double,
                          pedometer snapshot: PedometerSnapshot) async {
        // 終了時刻より後(停止検知までの静止点)を切り落とし、残った点の総距離を正とする。
        let trimmed = try? await repository.trimTrailingPoints(after: end, in: sessionID)
        // trim 失敗時はライブ距離→歩数計距離の順でフォールバック。
        let finalDistance = trimmed ?? (liveDistance > 0 ? liveDistance : snapshot.distance)
        let duration = max(0, end.timeIntervalSince(start))
        let energy = estimatedEnergy(kind: kind, durationSeconds: duration)
        let avgPace = finalDistance > 0 ? duration / finalDistance : 0  // 秒/メートル

        var metrics = SessionMetrics(totalDistance: finalDistance,
                                     totalSteps: snapshot.steps,
                                     avgPace: avgPace,
                                     energyBurned: energy)

        // HealthKit へ保存し、UUID を控える。
        let workoutUUID = try? await healthKit.saveWorkout(kind: kind,
                                                           start: start,
                                                           end: end,
                                                           distance: finalDistance,
                                                           energy: energy)
        metrics.healthKitWorkoutUUID = workoutUUID

        try? await repository.finalizeSession(sessionID, endedAt: end, metrics: metrics)

        // 外出目的の自動判定 + 探索グリッドへの反映(セッション確定後に一度だけ)。
        await classifyAndRecordExploration(sessionID: sessionID, kind: kind, startedAt: start, totalDistance: finalDistance)

        // 採番済みの UUID をそのまま使って保存通知(再フェッチ不要)。
        notifications.notifyRecordingSaved(kind: kind,
                                           distanceMeters: finalDistance,
                                           steps: snapshot.steps,
                                           sessionID: sessionUUID)
    }

    /// `OutingClassifier` で外出目的を判定し、`ExplorationService` でルートを探索グリッドへ
    /// 反映して、両方の結果を1回で永続化する。バックフィル(`ExplorationBackfillService`)も
    /// 同じ経路(`WalkRepository.finalizeClassification` の `classifiedAt` ガード)を通る。
    private func classifyAndRecordExploration(sessionID: NSManagedObjectID,
                                              kind: ActivityKind,
                                              startedAt: Date,
                                              totalDistance: Double) async {
        guard let coordinates = try? await repository.fetchRouteCoordinates(for: sessionID) else { return }
        let home = TekTheme.homeCoordinate()
        let purpose = await classifier.classify(kind: kind,
                                                 sessionID: sessionID,
                                                 startedAt: startedAt,
                                                 coordinates: coordinates,
                                                 totalDistance: totalDistance,
                                                 home: home)
        let newCellCount = (try? await explorationService.recordVisited(coordinates: coordinates, firstSeenAt: startedAt)) ?? 0
        try? await repository.finalizeClassification(sessionID: sessionID, purpose: purpose, newCellCount: newCellCount)
    }

    private func estimatedEnergy(kind: ActivityKind, durationSeconds: TimeInterval) -> Double {
        let hours = durationSeconds / 3600
        return Tunables.metValue(for: kind) * Tunables.defaultBodyMassKg * hours
    }
}
