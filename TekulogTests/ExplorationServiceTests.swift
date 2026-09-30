import XCTest
import CoreLocation
@testable import Tekulog

/// 探索グリッドの永続化(`ExplorationService`)を検証する。セル番号の計算そのものは
/// `ExplorationGridTests` が対象。
final class ExplorationServiceTests: XCTestCase {

    // MARK: - densify(_:)

    func testDensifyInsertsIntermediatePointsForLongGaps() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let start = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let end = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7600) // 約1.1km
        let result = service.densify([start, end])
        XCTAssertGreaterThan(result.count, 2, "1km 離れた2点はセルサイズ(75m)基準で補間されるはず")
        XCTAssertEqual(result.first!.latitude, start.latitude, accuracy: 1e-9)
        XCTAssertEqual(result.last!.latitude, end.latitude, accuracy: 1e-9)
    }

    func testDensifyDoesNotAlterShortGaps() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let start = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let end = CLLocationCoordinate2D(latitude: 35.68001, longitude: 139.7600) // 約1m
        let result = service.densify([start, end])
        XCTAssertEqual(result.count, 2, "セルサイズより十分近い2点は補間しない")
    }

    // MARK: - boundingBox(center:radiusMeters:)

    func testBoundingBoxSpansApproximatelyTheRequestedRadius() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let center = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let box = service.boundingBox(center: center, radiusMeters: 1000)
        let north = CLLocation(latitude: box.maxLat, longitude: center.longitude)
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        XCTAssertEqual(north.distance(from: centerLocation), 1000, accuracy: 5)
    }

    // MARK: - offset(from:distanceMeters:bearingDegrees:)

    func testOffsetNorthIncreasesLatitudeOnly() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let center = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let point = service.offset(from: center, distanceMeters: 500, bearingDegrees: 0)
        XCTAssertGreaterThan(point.latitude, center.latitude)
        XCTAssertEqual(point.longitude, center.longitude, accuracy: 0.0005)
    }

    func testOffsetEastIncreasesLongitudeOnly() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let center = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let point = service.offset(from: center, distanceMeters: 500, bearingDegrees: 90)
        XCTAssertGreaterThan(point.longitude, center.longitude)
        XCTAssertEqual(point.latitude, center.latitude, accuracy: 0.001)
    }

    func testOffsetActualDistanceMatchesRequestedDistance() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let center = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let point = service.offset(from: center, distanceMeters: 800, bearingDegrees: 130)
        let actual = CLLocation(latitude: point.latitude, longitude: point.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        XCTAssertEqual(actual, 800, accuracy: 2)
    }

    // MARK: - recordVisited / fetchCells(Core Data 結合)

    func testRecordVisitedReturnsNewCountOnceThenZeroForDuplicateCoordinate() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let coordinate = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)

        let first = try await service.recordVisited(coordinates: [coordinate], firstSeenAt: Date())
        XCTAssertEqual(first, 1)

        let second = try await service.recordVisited(coordinates: [coordinate], firstSeenAt: Date())
        XCTAssertEqual(second, 0, "同じセルへの再訪問は新規開拓としてカウントしない")
    }

    func testFetchCellsReturnsOnlyCellsWithinBoundingBox() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let near = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let far = CLLocationCoordinate2D(latitude: 36.5000, longitude: 140.5000)
        // near/far は別々の recordVisited 呼び出しにする: 同じ配列に入れると densify() が
        // 130km のギャップをセルサイズ刻みで直線補間しようとし、near の近くにも余分な
        // 中間セルができてテストの前提が崩れる(densify は GPS の小さな間引きギャップ用)。
        _ = try await service.recordVisited(coordinates: [near], firstSeenAt: Date())
        _ = try await service.recordVisited(coordinates: [far], firstSeenAt: Date())

        let box = service.boundingBox(center: near, radiusMeters: 500)
        let cells = try await service.fetchCells(minLat: box.minLat, maxLat: box.maxLat,
                                                 minLon: box.minLon, maxLon: box.maxLon)
        XCTAssertEqual(cells.count, 1)
    }

    // MARK: - findFrontierCandidates / explorationRate

    func testFindFrontierCandidatesReturnsOneCandidatePerDirectionWhenNothingExplored() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let candidates = try await service.findFrontierCandidates(home: home)
        XCTAssertEqual(candidates.count, Tunables.explorationFrontierDirectionCount,
                       "何も探索していなければ全方位が未開拓のはず")
        for candidate in candidates {
            XCTAssertEqual(candidate.distanceMeters, Tunables.explorationFrontierStepMeters, accuracy: 0.5)
        }
    }

    func testExplorationRateIsZeroWhenNothingExplored() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let rate = try await service.explorationRate(home: home, radiusMeters: 500)
        XCTAssertEqual(rate, 0)
    }

    func testExplorationRateIsPositiveAfterVisitingHome() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        _ = try await service.recordVisited(coordinates: [home], firstSeenAt: Date())
        let rate = try await service.explorationRate(home: home, radiusMeters: 500)
        XCTAssertGreaterThan(rate, 0)
        XCTAssertLessThanOrEqual(rate, 1)
    }

    // MARK: - recordVisited(新グリッド)

    func testRecordVisitedStoresTheGridCenterOfEachCell() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        // セルの端に近い点で記録しても、保存されるのはセル中心(どの点から入っても同じ値)。
        let cell = ExplorationGrid.cell(for: .init(latitude: 35.6800, longitude: 139.7600))
        let nearEdge = CLLocationCoordinate2D(
            latitude: cell.center.latitude + ExplorationGrid.latCellDegrees * 0.45,
            longitude: cell.center.longitude - ExplorationGrid.lonCellDegrees(latBucket: cell.latBucket) * 0.45)
        XCTAssertEqual(ExplorationGrid.cell(for: nearEdge), cell)

        let recorded = try await service.recordVisited(coordinates: [nearEdge], firstSeenAt: Date())
        XCTAssertEqual(recorded, 1)
        let stored = try await service.fetchAllCells()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].latitude, cell.center.latitude, accuracy: 1e-12)
        XCTAssertEqual(stored[0].longitude, cell.center.longitude, accuracy: 1e-12)
        XCTAssertEqual(ExplorationGrid.cell(for: stored[0]), cell, "保存した中心をセルへ戻すと元のセルになる")
    }

    func testRecordVisitedCountsOnlyCellsNotAlreadyExplored() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let start = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let middle = CLLocationCoordinate2D(latitude: 35.6850, longitude: 139.7600)   // 約 550m 北
        let end = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7600)      // さらに約 550m 北

        let firstHalf = try await service.recordVisited(coordinates: [start, middle], firstSeenAt: Date())
        XCTAssertGreaterThan(firstHalf, 5, "550m の直線は補間されて複数セルになる")

        // 前半を含む全体を記録し直すと、新規は後半ぶんだけ。
        let whole = try await service.recordVisited(coordinates: [start, middle, end], firstSeenAt: Date())
        XCTAssertGreaterThan(whole, 0)
        let total = try await service.totalExploredCellCount()
        XCTAssertEqual(total, firstHalf + whole)

        let stored = try await service.fetchAllCells()
        XCTAssertEqual(Set(stored.map { ExplorationGrid.cell(for: $0).key }).count, stored.count, "セルに重複がない")

        let again = try await service.recordVisited(coordinates: [start, middle, end], firstSeenAt: Date())
        XCTAssertEqual(again, 0)
    }

    func testRecordVisitedIgnoresInvalidCoordinates() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let invalidOnly = try await service.recordVisited(
            coordinates: [CLLocationCoordinate2D(latitude: 200, longitude: 0)], firstSeenAt: Date())
        XCTAssertEqual(invalidOnly, 0)

        let mixed = try await service.recordVisited(
            coordinates: [CLLocationCoordinate2D(latitude: .nan, longitude: 139.76),
                          CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76)],
            firstSeenAt: Date())
        XCTAssertEqual(mixed, 1, "無効な座標だけを捨てて、有効な点は記録する")
    }

    // MARK: - fetchAllCells / resetAllCells

    func testFetchAllCellsReturnsEveryCellRegardlessOfLocation() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let empty = try await service.fetchAllCells()
        XCTAssertTrue(empty.isEmpty)

        _ = try await service.recordVisited(coordinates: [.init(latitude: 35.68, longitude: 139.76)], firstSeenAt: Date())
        _ = try await service.recordVisited(coordinates: [.init(latitude: 43.06, longitude: 141.35)], firstSeenAt: Date())
        _ = try await service.recordVisited(coordinates: [.init(latitude: 26.21, longitude: 127.68)], firstSeenAt: Date())
        let all = try await service.fetchAllCells()
        XCTAssertEqual(all.count, 3, "表示範囲に関係なく全件を返す")
    }

    func testResetAllCellsRemovesEverythingAndAllowsRecordingAgain() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let coordinate = CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76)
        _ = try await service.recordVisited(coordinates: [coordinate], firstSeenAt: Date())
        _ = try await service.recordVisited(coordinates: [.init(latitude: 35.70, longitude: 139.70)], firstSeenAt: Date())

        try await service.resetAllCells()
        let afterReset = try await service.totalExploredCellCount()
        XCTAssertEqual(afterReset, 0)

        let again = try await service.recordVisited(coordinates: [coordinate], firstSeenAt: Date())
        XCTAssertEqual(again, 1, "全削除の後は、同じセルが新規として記録できる")
    }

    // MARK: - フロンティア(晴れて見える範囲を避ける)

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    func testFrontierCandidatesAreNeverInsideTheRevealedArea() async throws {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        // 自宅から北へ 400m、東へ 900m 歩いたことにする。
        let north = service.offset(from: home, distanceMeters: 400, bearingDegrees: 0)
        let east = service.offset(from: home, distanceMeters: 900, bearingDegrees: 90)
        _ = try await service.recordVisited(coordinates: [home, north], firstSeenAt: Date())
        _ = try await service.recordVisited(coordinates: [home, east], firstSeenAt: Date())

        let explored = try await service.fetchAllCells()
        let candidates = try await service.findFrontierCandidates(home: home)
        XCTAssertEqual(candidates.count, Tunables.explorationFrontierDirectionCount)
        for candidate in candidates {
            for center in explored {
                XCTAssertGreaterThan(meters(candidate.coordinate, center), Tunables.explorationRevealRadiusMeters,
                                     "方位\(candidate.bearingDegrees)°の候補が晴れて見える範囲に入っている")
            }
        }

        // 北: 200m・400m 地点は晴れている。600m 地点(経路の端から約 200m)が最初の未開拓。
        let northCandidate = try XCTUnwrap(candidates.first { $0.bearingDegrees == 0 })
        XCTAssertEqual(northCandidate.distanceMeters, 600, accuracy: 0.5)
        // 東: 200〜1000m 地点は経路の端(900m)から 150m 以内か経路上。1200m が最初の未開拓。
        let eastCandidate = try XCTUnwrap(candidates.first { $0.bearingDegrees == 90 })
        XCTAssertEqual(eastCandidate.distanceMeters, 1_200, accuracy: 0.5)
    }

    /// 近傍セルだけを調べる `isRevealed` が、全セルとの距離を総当たりした結果と一致する
    /// (150m 以内のセルを取りこぼさない)。
    func testIsRevealedMatchesBruteForceDistanceCheck() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        var state: UInt64 = 42
        func random(_ range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + (range.upperBound - range.lowerBound) * Double(state >> 11) / Double(1 << 53)
        }

        for base in [CLLocationCoordinate2D(latitude: 43.06, longitude: 141.35),
                     CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76),
                     CLLocationCoordinate2D(latitude: 26.21, longitude: 127.68)] {
            // 約 ±1km に 60 セルをばらまく。
            var cells = Set<ExplorationGrid.Cell>()
            while cells.count < 60 {
                cells.insert(ExplorationGrid.cell(for: .init(latitude: base.latitude + random(-0.009...0.009),
                                                             longitude: base.longitude + random(-0.011...0.011))))
            }
            let keys = Set(cells.map(\.key))
            for _ in 0..<3_000 {
                let point = CLLocationCoordinate2D(latitude: base.latitude + random(-0.012...0.012),
                                                   longitude: base.longitude + random(-0.014...0.014))
                let nearest = cells.map { meters($0.center, point) }.min()!
                // 判定の境目(150m ちょうど付近)は距離計算の丸めで揺れるので除く。
                guard abs(nearest - Tunables.explorationRevealRadiusMeters) > 0.01 else { continue }
                XCTAssertEqual(service.isRevealed(point, exploredKeys: keys),
                               nearest <= Tunables.explorationRevealRadiusMeters,
                               "最寄りセルまで \(nearest)m の地点の判定が総当たりと食い違う")
            }
        }
    }

    // MARK: - AsyncGate(外出単位の排他)

    /// テスト内の共有カウンタ(ゲートが守るべき「同時に1つだけ」を観測する)。
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var inside = 0
        private(set) var maxInside = 0
        private(set) var order: [Int] = []

        func enter(_ id: Int) {
            lock.lock(); defer { lock.unlock() }
            inside += 1
            maxInside = max(maxInside, inside)
            order.append(id)
        }
        func leave() {
            lock.lock(); defer { lock.unlock() }
            inside -= 1
        }
        var snapshot: (maxInside: Int, order: [Int]) {
            lock.lock(); defer { lock.unlock() }
            return (maxInside, order)
        }
    }

    func testAsyncGateNeverLetsTwoHoldersInAtOnce() async {
        let gate = AsyncGate()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<40 {
                group.addTask {
                    await gate.acquire()
                    probe.enter(id)
                    // 保持したまま中断点をまたぐ(ここで他のタスクが割り込めてはいけない)。
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    probe.leave()
                    gate.release()
                }
            }
        }
        let result = probe.snapshot
        XCTAssertEqual(result.maxInside, 1, "ゲートの内側に同時に2つ入った")
        XCTAssertEqual(result.order.count, 40, "全員が1回ずつ入れた(取りこぼしがない)")
    }

    func testAsyncGateServesWaitersInArrivalOrderAndCanBeReacquired() async {
        let gate = AsyncGate()
        let probe = Probe()
        await gate.acquire()   // 先に保持しておき、待ち行列を作る

        var tasks: [Task<Void, Never>] = []
        for id in 0..<5 {
            tasks.append(Task {
                await gate.acquire()
                probe.enter(id)
                probe.leave()
                gate.release()
            })
            // 到着順を確定させる(次のタスクを作る前に、待ち行列へ入る時間を与える)。
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(probe.snapshot.order.isEmpty, "保持中は誰も入れない")

        gate.release()
        for task in tasks { await task.value }
        XCTAssertEqual(probe.snapshot.order, [0, 1, 2, 3, 4], "待っていた順に入る")

        // 全員が抜けた後は、待たずに取り直せる。
        await gate.acquire()
        gate.release()
    }
}
