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

    /// アプリ起動時に呼ぶ。自動検知の監視を開始する。
    func startMonitoring() {
        detector.start()
    }

    // MARK: - 配線

    private func wire() {
        detector.onShouldStart = { [weak self] kind in
            self?.beginSession(kind: kind)
        }
        detector.onShouldStop = { [weak self] in
            self?.endSession()
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
        guard sessionID == nil else { return }
        let now = Date()
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
                self.sessionID = id
                self.flushPendingSamples()   // 生成前に溜まった点を書き出す
            } catch {
                // 生成に失敗したら記録を畳む。
                self.endSession(discard: true)
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

    private func endSession(discard: Bool = false) {
        let endedAt = Date()
        locationTracker.stop()
        let finalSnapshot = pedometer.stop()
        flushTimer?.invalidate()
        flushTimer = nil
        flushPendingSamples()

        let kind = currentKind
        let start = startedAt
        let id = sessionID
        let distance = accumulatedDistance

        // 状態リセット(次の検知に備える)。
        isRecording = false
        live = nil
        sessionID = nil
        currentKind = nil
        startedAt = nil
        accumulatedDistance = 0
        lastLocation = nil

        guard !discard, let id, let kind, let start else { return }

        Task { [weak self] in
            await self?.finalize(sessionID: id,
                                 kind: kind,
                                 start: start,
                                 end: endedAt,
                                 distance: distance,
                                 pedometer: finalSnapshot)
        }
    }

    private func finalize(sessionID: NSManagedObjectID,
                          kind: ActivityKind,
                          start: Date,
                          end: Date,
                          distance: Double,
                          pedometer snapshot: PedometerSnapshot) async {
        // 距離は GPS を正とし、無ければ歩数計の距離を使う。
        let finalDistance = distance > 0 ? distance : snapshot.distance
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

    private func sessionUUID(for objectID: NSManagedObjectID) async -> UUID? {
        let context = PersistenceController.shared.newBackgroundContext()
        return await context.perform {
            (try? context.existingObject(with: objectID) as? WalkSession)?.id
        }
    }
}
