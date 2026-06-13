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

    /// 記録中の進行状況(UI 表示用)。
    struct LiveStats {
        var kind: ActivityKind
        var startedAt: Date
        var distanceMeters: Double = 0
        var steps: Int = 0
    }

    @Published private(set) var isRecording = false
    @Published private(set) var live: LiveStats?

    private let detector: ActivityDetector
    private let locationTracker: LocationTracker
    private let pedometer: PedometerService
    private let healthKit: HealthKitService
    private let notifications: NotificationService
    private let repository: WalkRepository

    // 現在セッションの状態
    private var sessionID: NSManagedObjectID?
    /// 進行中セッションの識別トークン。非同期生成の競合(生成完了前に終了)を検出する。
    private var activeToken: UUID?
    private var currentKind: ActivityKind?
    private var startedAt: Date?
    private var accumulatedDistance: Double = 0
    private var lastLocation: CLLocation?

    // ルート点バッファ
    private var pendingSamples: [RouteSample] = []
    private var flushTimer: Timer?

    init(detector: ActivityDetector = ActivityDetector(),
         locationTracker: LocationTracker = LocationTracker(),
         pedometer: PedometerService = PedometerService(),
         healthKit: HealthKitService = HealthKitService(),
         notifications: NotificationService = NotificationService(),
         repository: WalkRepository = WalkRepository()) {
        self.detector = detector
        self.locationTracker = locationTracker
        self.pedometer = pedometer
        self.healthKit = healthKit
        self.notifications = notifications
        self.repository = repository

        wire()
    }

    /// アプリ起動直後に呼ぶ。通知カテゴリ/デリゲートを設定する。
    func bootstrap() {
        notifications.configure()
    }

    /// 自動検知の監視を開始する。Motion 権限プロンプトはこの時点で表示される。
    func startMonitoring() {
        detector.start()
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

    private func wire() {
        detector.onShouldStart = { [weak self] kind in
            self?.beginSession(kind: kind)
        }
        detector.onShouldStop = { [weak self] stoppedAt in
            self?.endSession(stoppedAt: stoppedAt)
        }
        locationTracker.onSample = { [weak self] sample in
            self?.ingest(sample)
        }
        pedometer.onUpdate = { [weak self] snapshot in
            self?.live?.steps = snapshot.steps
        }
        notifications.onDiscardRequested = { [weak self] uuid in
            Task { try? await self?.repository.deleteSession(withID: uuid) }
        }
    }

    // MARK: - セッション開始

    private func beginSession(kind: ActivityKind) {
        guard sessionID == nil, activeToken == nil else { return }
        let now = Date()
        let token = UUID()
        activeToken = token
        currentKind = kind
        startedAt = now
        accumulatedDistance = 0
        lastLocation = nil
        pendingSamples.removeAll()

        isRecording = true
        live = LiveStats(kind: kind, startedAt: now)

        locationTracker.start()
        pedometer.start(from: now)
        notifications.notifyRecordingStarted(kind: kind)
        startFlushTimer()

        Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await repository.beginSession(kind: kind, startedAt: now)
                // 生成完了までに終了/破棄/別セッション開始が起きていたら孤児を削除。
                guard self.activeToken == token else {
                    try? await self.repository.deleteSession(id)
                    return
                }
                self.sessionID = id
                self.flushPendingSamples()   // 生成前に溜まった点を書き出す
            } catch {
                // 生成に失敗したら(まだ同一セッションなら)記録を畳む。
                if self.activeToken == token {
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

        pendingSamples.append(sample)
        if pendingSamples.count >= Tunables.pointFlushBatchSize {
            flushPendingSamples()
        }
    }

    private func flushPendingSamples() {
        guard let sessionID, !pendingSamples.isEmpty else { return }
        let batch = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
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

    /// - Parameter stoppedAt: 動きが実際に止まった時刻。停止検知(約30分後)ではなくこの時刻を
    ///   終了時刻に使い、所要時間・ペース・距離・エネルギーが末尾の静止時間で水増しされるのを防ぐ。
    private func endSession(stoppedAt: Date? = nil, discard: Bool = false) {
        locationTracker.stop()
        let finalSnapshot = pedometer.stop()
        flushTimer?.invalidate()
        flushTimer = nil
        flushPendingSamples()

        let kind = currentKind
        let start = startedAt
        let id = sessionID
        let distance = accumulatedDistance

        // 状態リセット(次の検知に備える)。トークンも無効化。
        isRecording = false
        live = nil
        sessionID = nil
        activeToken = nil
        currentKind = nil
        startedAt = nil
        accumulatedDistance = 0
        lastLocation = nil

        guard !discard, let id, let kind, let start else { return }

        // 終了時刻 = 実際に止まった時刻(無ければ現在)。開始より前にならないよう clamp。
        let endedAt = max(start, stoppedAt ?? Date())

        Task { [weak self] in
            await self?.finalize(sessionID: id,
                                 kind: kind,
                                 start: start,
                                 end: endedAt,
                                 liveDistance: distance,
                                 pedometer: finalSnapshot)
        }
    }

    private func finalize(sessionID: NSManagedObjectID,
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

        // 保存通知のため UUID を取り直す。
        if let sessionUUID = await sessionUUID(for: sessionID) {
            notifications.notifyRecordingSaved(kind: kind,
                                               distanceMeters: finalDistance,
                                               steps: snapshot.steps,
                                               sessionID: sessionUUID)
        }
    }

    private func estimatedEnergy(kind: ActivityKind, durationSeconds: TimeInterval) -> Double {
        let hours = durationSeconds / 3600
        return Tunables.metValue(for: kind) * Tunables.defaultBodyMassKg * hours
    }

    nonisolated private func sessionUUID(for objectID: NSManagedObjectID) async -> UUID? {
        let context = PersistenceController.shared.newBackgroundContext()
        return await context.perform {
            (try? context.existingObject(with: objectID) as? WalkSession)?.id
        }
    }
}
