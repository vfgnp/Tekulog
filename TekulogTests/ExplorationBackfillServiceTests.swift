import XCTest
import Combine
import CoreData
import CoreLocation
@testable import Tekulog

/// グリッド再構築と未分類バックフィル(`ExplorationBackfillService`)を検証する。
/// 設計: `design/explore-map/03-detailed-design.md` §6、受け入れ基準 AC-10〜AC-12 / AC-14。
///
/// `@MainActor`: 検証のために `viewContext`(メインキュー専用)の `WalkSession` を直接読むため。
@MainActor
final class ExplorationBackfillServiceTests: XCTestCase {

    private let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    /// 3つの外出(古い順): A = 分類済みの散歩、B = A と同じ道(手動で「お買い物」に変更済み)、
    /// C = 別の道を走った未分類のランニング。
    private struct Fixture {
        let persistence: PersistenceController
        let service: ExplorationService
        let repository: WalkRepository
        let defaults: UserDefaults
        let backfill: ExplorationBackfillService
        let a: WalkSession
        let b: WalkSession
        let c: WalkSession
        let routeA: [CLLocationCoordinate2D]
        let routeC: [CLLocationCoordinate2D]

        var context: NSManagedObjectContext { persistence.container.viewContext }
    }

    private func makeFixture() throws -> Fixture {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let routeA = ExplorationTestSupport.routeNorth(from: home, meters: 600)
        let routeC = ExplorationTestSupport.routeNorth(
            from: .init(latitude: home.latitude, longitude: home.longitude + 0.02), meters: 450)

        // 新エリア数には、旧グリッドで数えた(今となっては誤った)値が入っている想定。
        let a = ExplorationTestSupport.makeSession(in: context, startedAt: base, route: routeA,
                                                   purpose: .walk, exploredNewCellCount: 999)
        let b = ExplorationTestSupport.makeSession(in: context, startedAt: base.addingTimeInterval(86_400),
                                                   route: routeA, purpose: .shopping, purposeIsUserSet: true,
                                                   exploredNewCellCount: 777)
        let c = ExplorationTestSupport.makeSession(in: context, startedAt: base.addingTimeInterval(172_800),
                                                   kind: .running, route: routeC)
        try context.save()

        let service = ExplorationService(persistence: persistence)
        let repository = WalkRepository(persistence: persistence)
        let defaults = ExplorationTestSupport.makeDefaults(self)
        let backfill = ExplorationBackfillService(explorationService: service, repository: repository,
                                                  defaults: defaults)
        return Fixture(persistence: persistence, service: service, repository: repository, defaults: defaults,
                       backfill: backfill, a: a, b: b, c: c, routeA: routeA, routeC: routeC)
    }

    /// 旧グリッド時代のセルに見立てた行を、ストアへ直接入れる(新グリッドのどの経路とも無関係な場所)。
    private func insertStaleCell(_ fixture: Fixture, latBucket: Int32 = 1, lonBucket: Int32 = 1) throws {
        let cell = ExploredCell(context: fixture.context)
        cell.latBucket = latBucket
        cell.lonBucket = lonBucket
        cell.centerLatitude = 10
        cell.centerLongitude = 10
        cell.firstSeenAt = base
        try fixture.context.save()
    }

    private func refresh(_ fixture: Fixture) {
        fixture.context.refreshAllObjects()
    }

    /// 再構築後の正しい状態になっていることを確かめる(複数のテストで共用)。
    private func assertRebuilt(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let expected = try await ExplorationTestSupport.sequentialNewCellCounts(
            [fixture.routeA, fixture.routeA, fixture.routeC])
        XCTAssertGreaterThan(expected[0], 0, file: file, line: line)
        XCTAssertEqual(expected[1], 0, "B は A と同じ道なので新規なし", file: file, line: line)
        XCTAssertGreaterThan(expected[2], 0, file: file, line: line)

        let cells = try await fixture.service.fetchAllCells()
        XCTAssertEqual(cells.count, expected[0] + expected[2], "セルは経路から作り直した分だけ", file: file, line: line)
        XCTAssertEqual(Set(cells.map { ExplorationGrid.cell(for: $0).key }).count, cells.count,
                       "セルに重複がない", file: file, line: line)
        XCTAssertFalse(cells.contains { abs($0.latitude - 10) < 1 }, "旧グリッドのセルが残っている", file: file, line: line)

        refresh(fixture)
        XCTAssertEqual(fixture.a.exploredNewCellCount, Int64(expected[0]), "A の新エリア数", file: file, line: line)
        XCTAssertEqual(fixture.b.exploredNewCellCount, 0, "B の新エリア数", file: file, line: line)
        XCTAssertEqual(fixture.c.exploredNewCellCount, Int64(expected[2]), "C の新エリア数", file: file, line: line)

        // 分類済みの外出の目的は変えない(手動変更を含む)。
        XCTAssertEqual(fixture.a.purpose, .walk, file: file, line: line)
        XCTAssertEqual(fixture.a.classifiedAt, base.addingTimeInterval(700), file: file, line: line)
        XCTAssertEqual(fixture.b.purpose, .shopping, file: file, line: line)
        XCTAssertTrue(fixture.b.purposeIsUserSet, file: file, line: line)
        // 未分類だった外出は分類される(ランニングは通信なしで .run)。
        XCTAssertEqual(fixture.c.purpose, .run, file: file, line: line)
        XCTAssertNotNil(fixture.c.classifiedAt, file: file, line: line)

        XCTAssertEqual(fixture.defaults.integer(forKey: ExplorationBackfillService.gridVersionKey),
                       ExplorationBackfillService.currentGridVersion, "版数が保存される", file: file, line: line)
    }

    // MARK: - 再構築(AC-10)

    func testRebuildRecreatesCellsAndCountsWithoutTouchingPurposes() async throws {
        let fixture = try makeFixture()
        try insertStaleCell(fixture)

        await fixture.backfill.runIfNeeded()

        try await assertRebuilt(fixture)
    }

    func testSecondRunDoesNotRebuildAgain() async throws {
        let fixture = try makeFixture()
        await fixture.backfill.runIfNeeded()
        let countAfterFirst = try await fixture.service.totalExploredCellCount()

        // 再構築済みなら、2回目は全削除から始めない(印として入れた行が残る)。
        try insertStaleCell(fixture, latBucket: 2, lonBucket: 2)
        refresh(fixture)
        let savedCount = fixture.a.exploredNewCellCount
        await fixture.backfill.runIfNeeded()

        let countAfterSecond = try await fixture.service.totalExploredCellCount()
        XCTAssertEqual(countAfterSecond, countAfterFirst + 1)
        refresh(fixture)
        XCTAssertEqual(fixture.a.exploredNewCellCount, savedCount)
    }

    func testFreshInstallOnlyStoresTheGridVersion() async throws {
        let persistence = PersistenceController(inMemory: true)
        let service = ExplorationService(persistence: persistence)
        let defaults = ExplorationTestSupport.makeDefaults(self)
        let backfill = ExplorationBackfillService(explorationService: service,
                                                  repository: WalkRepository(persistence: persistence),
                                                  defaults: defaults)
        await backfill.runIfNeeded()
        XCTAssertEqual(defaults.integer(forKey: ExplorationBackfillService.gridVersionKey),
                       ExplorationBackfillService.currentGridVersion)
        let count = try await service.totalExploredCellCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - 中断・失敗からのやり直し(AC-11)

    /// 前回の再構築が途中で止まった状態(セルは一部だけ、新エリア数は途中まで書き換え済み、
    /// 版数は未保存)から実行しても、最初から実行した場合と同じ結果になる。
    func testRebuildFromInterruptedStateGivesTheSameResult() async throws {
        let fixture = try makeFixture()
        // 途中まで: A だけ再生済みで、C は順番が来る前に先に記録されてしまった、という崩れた状態。
        let partial = try await fixture.service.recordVisited(coordinates: Array(fixture.routeC.prefix(5)),
                                                              firstSeenAt: base)
        try await fixture.repository.setExploredNewCellCount(sessionID: fixture.a.objectID, count: partial + 3)
        try insertStaleCell(fixture)
        XCTAssertEqual(fixture.defaults.integer(forKey: ExplorationBackfillService.gridVersionKey), 0)

        await fixture.backfill.runIfNeeded()

        try await assertRebuilt(fixture)
    }

    /// 再構築が途中で失敗したら版数を進めず(誤った状態を「完了」として固定しない)、
    /// 次の実行で最初からやり直して正しい結果になる。
    func testFailedRebuildDoesNotAdvanceTheGridVersionAndTheNextRunRecovers() async throws {
        struct ReplayFailure: Error {}
        let fixture = try makeFixture()
        try insertStaleCell(fixture)
        let processor = OutingPostProcessor(repository: fixture.repository, explorationService: fixture.service)
        let secondSessionID = fixture.b.objectID
        // 2件目(B)の再生で失敗させる。A までは反映済みの、途中で止まった状態になる。
        let failing = ExplorationBackfillService(
            explorationService: fixture.service, repository: fixture.repository, defaults: fixture.defaults,
            replay: { session in
                if session.id == secondSessionID { throw ReplayFailure() }
                try await processor.replayHoldingGate(session)
            })

        await failing.runIfNeeded()

        XCTAssertEqual(fixture.defaults.integer(forKey: ExplorationBackfillService.gridVersionKey), 0,
                       "失敗したのに版数が進んだ")
        XCTAssertFalse(fixture.service.rebuildState.value, "失敗しても「再構築中」のまま残らない")
        refresh(fixture)
        XCTAssertNil(fixture.c.classifiedAt, "失敗した回は、その先の外出(C)と未分類バックフィルへ進まない")

        // ゲートが解放されていること(解放されていなければ、ここで止まる)と、やり直しで正しくなること。
        await fixture.backfill.runIfNeeded()
        try await assertRebuilt(fixture)
    }

    // MARK: - 未分類バックフィル

    /// 再構築が済んだ後に未分類の外出が残っていても(確定後処理の途中でプロセスが終了した場合など)、
    /// 次の起動で拾われる。
    func testUnclassifiedSessionLeftBehindIsPickedUpOnTheNextRun() async throws {
        let fixture = try makeFixture()
        await fixture.backfill.runIfNeeded()

        let routeD = ExplorationTestSupport.routeNorth(
            from: .init(latitude: home.latitude + 0.05, longitude: home.longitude), meters: 300)
        let d = ExplorationTestSupport.makeSession(in: fixture.context, startedAt: base.addingTimeInterval(300_000),
                                                   kind: .running, route: routeD)
        try fixture.context.save()
        let before = try await fixture.service.totalExploredCellCount()

        await fixture.backfill.runIfNeeded()

        refresh(fixture)
        XCTAssertNotNil(d.classifiedAt, "未分類のまま残った外出が処理されなかった")
        XCTAssertEqual(d.purpose, .run)
        XCTAssertGreaterThan(d.exploredNewCellCount, 0)
        let after = try await fixture.service.totalExploredCellCount()
        XCTAssertEqual(after, before + Int(d.exploredNewCellCount))
    }

    // MARK: - 再構築状態の公開(AC-14)

    func testRebuildStatePublishesTrueThenFalseAndReplaysCurrentValueToLateSubscribers() async throws {
        let fixture = try makeFixture()
        let recorder = StateRecorder()
        let subscription = Self.record(fixture.service.rebuildState, into: recorder)
        defer { subscription.cancel() }

        await fixture.backfill.runIfNeeded()

        XCTAssertEqual(recorder.values, [false, true, false], "購読時の現在値 → 再構築中 → 完了")

        // 完了後に購読しても、現在値(false)がすぐ届く。
        let late = StateRecorder()
        let lateSubscription = Self.record(fixture.service.rebuildState, into: late)
        defer { lateSubscription.cancel() }
        XCTAssertEqual(late.values, [false])
    }

    /// 発行は再構築を実行しているスレッド(MainActor の外)から届く。このテストクラスは
    /// `@MainActor` なので、クロージャをここ(nonisolated)で作らないと MainActor 隔離になり、
    /// バックグラウンドから呼ばれた時点で実行時の隔離チェックに引っかかって落ちる。
    private nonisolated static func record(_ subject: CurrentValueSubject<Bool, Never>,
                                           into recorder: StateRecorder) -> AnyCancellable {
        subject.sink { recorder.append($0) }
    }

    private final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        func append(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            stored.append(value)
        }
        var values: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    // MARK: - 再構築とライブ確定の並行(AC-12)

    /// 再構築と、最も新しい外出の確定後処理を同時に走らせても、結果は
    /// 「確定済みの全外出を古い順に1回ずつ反映した」場合と一致する。
    func testRebuildRacingWithLiveFinalizeMatchesSequentialReplay() async throws {
        for iteration in 0..<12 {
            let fixture = try makeFixture()
            try insertStaleCell(fixture)
            // S: たった今確定した外出。A の道の後半と重なり、その先へ延びる。
            let routeS = ExplorationTestSupport.routeNorth(
                from: .init(latitude: home.latitude + 300 / 111_320, longitude: home.longitude), meters: 700)
            let s = ExplorationTestSupport.makeSession(in: fixture.context, startedAt: base.addingTimeInterval(400_000),
                                                       kind: .running, route: routeS)
            try fixture.context.save()
            let processor = OutingPostProcessor(repository: fixture.repository, explorationService: fixture.service)
            let backfill = fixture.backfill
            let sessionID = s.objectID
            let startedAt = base.addingTimeInterval(400_000)

            // MainActor の外で同時に走らせる。どちらが先にゲートを取るかを回ごとに変える。
            let rebuild = Task.detached {
                if iteration % 2 == 1 { await Task.yield() }
                await backfill.runIfNeeded()
            }
            let live = Task.detached {
                if iteration % 2 == 0 { await Task.yield() }
                await processor.processFinalized(sessionID: sessionID, kind: .running,
                                                 startedAt: startedAt, totalDistance: 700)
            }
            await rebuild.value
            await live.value

            let expected = try await ExplorationTestSupport.sequentialNewCellCounts(
                [fixture.routeA, fixture.routeA, fixture.routeC, routeS])
            let aloneS = try await ExplorationTestSupport.sequentialNewCellCounts([routeS])[0]
            XCTAssertGreaterThan(expected[3], 0)
            XCTAssertLessThan(expected[3], aloneS, "S は A と一部重なるので、単独で数えた値より少ないはず")

            let cells = try await fixture.service.fetchAllCells()
            XCTAssertEqual(cells.count, expected.reduce(0, +), "回\(iteration): セル数")
            XCTAssertEqual(Set(cells.map { ExplorationGrid.cell(for: $0).key }).count, cells.count,
                           "回\(iteration): セルが重複した")

            refresh(fixture)
            XCTAssertEqual(fixture.a.exploredNewCellCount, Int64(expected[0]), "回\(iteration): A")
            XCTAssertEqual(fixture.b.exploredNewCellCount, Int64(expected[1]), "回\(iteration): B")
            XCTAssertEqual(fixture.c.exploredNewCellCount, Int64(expected[2]), "回\(iteration): C")
            XCTAssertEqual(s.exploredNewCellCount, Int64(expected[3]), "回\(iteration): S(並行で確定した外出)")
            XCTAssertEqual(s.purpose, .run)
            XCTAssertNotNil(s.classifiedAt)
        }
    }
}
