import Foundation
import HealthKit

/// 記録した散歩/自転車を HealthKit にワークアウトとして保存する。
/// データは Apple 管理の端末内 HealthKit に入り、開発者サーバーには送らない。
@MainActor
final class HealthKitService {

    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let dWalk = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(dWalk)
        }
        if let dCycle = HKQuantityType.quantityType(forIdentifier: .distanceCycling) {
            types.insert(dCycle)
        }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(energy)
        }
        return types
    }

    /// 共有(書き込み)権限を要求する。読み取りはサマリ表示用に最小限。
    /// (1日歩数は HealthKit ではなく自前の StepLedgerService/CMPedometer で持つ。)
    func requestAuthorization() async throws {
        guard Self.isAvailable else { return }
        let read: Set<HKObjectType> = [HKObjectType.workoutType()]
        try await store.requestAuthorization(toShare: shareTypes, read: read)
    }

    /// 完了したセッションをワークアウトとして保存し、その UUID を返す。
    /// - Parameters:
    ///   - kind: 散歩/自転車
    ///   - distance: メートル
    ///   - energy: kcal(0 なら付与しない)
    @discardableResult
    func saveWorkout(kind: ActivityKind,
                     start: Date,
                     end: Date,
                     distance: Double,
                     energy: Double) async throws -> UUID? {
        guard Self.isAvailable else { return nil }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = kind.hkActivityType

        let builder = HKWorkoutBuilder(healthStore: store,
                                       configuration: configuration,
                                       device: .local())

        try await builder.beginCollection(at: start)

        var samples: [HKSample] = []
        if distance > 0, let distanceType = kind.hkDistanceType {
            let quantity = HKQuantity(unit: .meter(), doubleValue: distance)
            samples.append(HKCumulativeQuantitySample(type: distanceType,
                                                      quantity: quantity,
                                                      start: start,
                                                      end: end))
        }
        if energy > 0, let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: energy)
            samples.append(HKCumulativeQuantitySample(type: energyType,
                                                      quantity: quantity,
                                                      start: start,
                                                      end: end))
        }
        if !samples.isEmpty {
            try await builder.addSamples(samples)
        }

        try await builder.endCollection(at: end)
        let workout = try await builder.finishWorkout()
        return workout?.uuid
    }
}

private extension ActivityKind {
    var hkActivityType: HKWorkoutActivityType {
        switch self {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        }
    }

    var hkDistanceType: HKQuantityType? {
        switch self {
        case .walking, .running: return HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
        case .cycling: return HKQuantityType.quantityType(forIdentifier: .distanceCycling)
        }
    }
}
