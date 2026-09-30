import XCTest
import CoreData
import CoreLocation
@testable import Tekulog

/// 外出1件の確定後処理(`OutingPostProcessor`)を検証する。
/// 設計: `design/explore-map/03-detailed-design.md` §5。
///
/// `@MainActor`: 検証のために `viewContext`(メインキュー専用)の `WalkSession` を直接読むため。
@MainActor
final class OutingPostProcessorTests: XCTestCase {

    private let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private struct Environment {
        let persistence: PersistenceController
        let service: ExplorationService
        let repository: WalkRepository
        let processor: OutingPostProcessor
        var context: NSManagedObjectContext { persistence.container.viewContext }
    }

    private func makeEnvironment() -> Environment {
        let persistence = PersistenceController(inMemory: true)
        let service = ExplorationService(persistence: persistence)
        let repository = WalkRepository(persistence: persistence)
        return Environment(persistence: persistence, service: service, repository: repository,
                           processor: OutingPostProcessor(repository: repository, explorationService: service))
    }

    // MARK: - 入口(ゲートを取る)

    func testProcessFinalizedClassifiesAndRecordsAnUnclassifiedSession() async throws {
        let environment = makeEnvironment()
        let route = ExplorationTestSupport.routeNorth(from: home, meters: 500)
        let session = ExplorationTestSupport.makeSession(in: environment.context, startedAt: start,
                                                         kind: .running, route: route)
        try environment.context.save()

        await environment.processor.processFinalized(sessionID: session.objectID, kind: .running,
                                                     startedAt: start, totalDistance: 500)

        let expected = try await ExplorationTestSupport.sequentialNewCellCounts([route])[0]
        environment.context.refreshAllObjects()
        XCTAssertEqual(session.purpose, .run)
        XCTAssertNotNil(session.classifiedAt)
        XCTAssertEqual(session.exploredNewCellCount, Int64(expected))
        let cellCount = try await environment.service.totalExploredCellCount()
        XCTAssertEqual(cellCount, expected)
    }

    /// 再構築が先に処理した外出に、後から確定後処理が届いた場合。何も書かず、セルも増やさない
    /// (ここで 0 を上書きすると新エリア数が消える)。
    func testProcessFinalizedDoesNothingForAnAlreadyClassifiedSession() async throws {
        let environment = makeEnvironment()
        let route = ExplorationTestSupport.routeNorth(from: home, meters: 500)
        let session = ExplorationTestSupport.makeSession(in: environment.context, startedAt: start,
                                                         kind: .running, route: route, purpose: .outing,
                                                         exploredNewCellCount: 12)
        try environment.context.save()

        await environment.processor.processFinalized(sessionID: session.objectID, kind: .running,
                                                     startedAt: start, totalDistance: 500)

        environment.context.refreshAllObjects()
        XCTAssertEqual(session.purpose, .outing, "処理済みの外出の目的を書き換えた")
        XCTAssertEqual(session.exploredNewCellCount, 12, "処理済みの外出の新エリア数を書き換えた")
        let cellCount = try await environment.service.totalExploredCellCount()
        XCTAssertEqual(cellCount, 0, "処理済みの外出は経路の反映も行わない")
    }

    func testProcessBackfillClassifiesASessionWithNoRoutePoints() async throws {
        let environment = makeEnvironment()
        let session = ExplorationTestSupport.makeSession(in: environment.context, startedAt: start,
                                                         kind: .walking, route: [])
        try environment.context.save()

        await environment.processor.processBackfill(sessionID: session.objectID, kind: .walking,
                                                    startedAt: start, totalDistance: 0)

        environment.context.refreshAllObjects()
        XCTAssertNotNil(session.classifiedAt, "経路が無くても分類済みにする(未分類のままだと毎回拾われる)")
        XCTAssertEqual(session.purpose, .outing)
        XCTAssertEqual(session.exploredNewCellCount, 0)
    }

    /// 入口はゲートを待つ。保持中は処理が進まず、解放されてから実行される。
    func testEntryPointWaitsForTheGate() async throws {
        let environment = makeEnvironment()
        let route = ExplorationTestSupport.routeNorth(from: home, meters: 300)
        let session = ExplorationTestSupport.makeSession(in: environment.context, startedAt: start,
                                                         kind: .running, route: route)
        try environment.context.save()
        let processor = environment.processor
        let sessionID = session.objectID
        let startedAt = start

        await environment.service.outingGate.acquire()
        let task = Task.detached {
            await processor.processFinalized(sessionID: sessionID, kind: .running,
                                             startedAt: startedAt, totalDistance: 300)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let whileHeld = try await environment.service.totalExploredCellCount()
        XCTAssertEqual(whileHeld, 0, "ゲートが保持されている間に処理が進んだ")

        environment.service.outingGate.release()
        await task.value
        let afterRelease = try await environment.service.totalExploredCellCount()
        XCTAssertGreaterThan(afterRelease, 0)
    }

    // MARK: - 本体(再構築用・ゲートを取らない)

    func testReplayUpdatesOnlyTheCountForAClassifiedSession() async throws {
        let environment = makeEnvironment()
        let route = ExplorationTestSupport.routeNorth(from: home, meters: 500)
        let session = ExplorationTestSupport.makeSession(in: environment.context, startedAt: start, route: route,
                                                         purpose: .commute, purposeIsUserSet: true,
                                                         exploredNewCellCount: 999)
        try environment.context.save()
        let ref = try await environment.repository.fetchFinalizedSessions()[0]
        XCTAssertTrue(ref.isClassified)

        try await environment.processor.replayHoldingGate(ref)

        let expected = try await ExplorationTestSupport.sequentialNewCellCounts([route])[0]
        environment.context.refreshAllObjects()
        XCTAssertEqual(session.exploredNewCellCount, Int64(expected))
        XCTAssertEqual(session.purpose, .commute)
        XCTAssertTrue(session.purposeIsUserSet)
        XCTAssertEqual(session.classifiedAt, start.addingTimeInterval(700))
    }

    /// 再構築の途中で削除された外出は、失敗ではなく読み飛ばす(再構築を止めない)。
    func testReplaySkipsASessionDeletedAfterTheSnapshot() async throws {
        let environment = makeEnvironment()
        let route = ExplorationTestSupport.routeNorth(from: home, meters: 500)
        let session = ExplorationTestSupport.makeSession(in: environment.context, startedAt: start, route: route,
                                                         purpose: .walk)
        try environment.context.save()
        let ref = try await environment.repository.fetchFinalizedSessions()[0]

        try await environment.repository.deleteSession(session.objectID)

        try await environment.processor.replayHoldingGate(ref)   // 投げないこと
        let cellCount = try await environment.service.totalExploredCellCount()
        XCTAssertEqual(cellCount, 0, "削除済みの外出の経路は反映しない")
    }
}
