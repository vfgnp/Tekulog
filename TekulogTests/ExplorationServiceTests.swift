import XCTest
import CoreLocation
@testable import Tekulog

final class ExplorationServiceTests: XCTestCase {

    // MARK: - bucket(for:)

    func testBucketIsStableForNearbyCoordinatesInTheSameCell() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        // 75m セル内(緯度差 0.0001度 ≒ 11m)なら同じバケットになるはず。
        let a = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let b = CLLocationCoordinate2D(latitude: 35.6800 + 0.0001, longitude: 139.7600)
        let bucketA = service.bucket(for: a)
        let bucketB = service.bucket(for: b)
        XCTAssertEqual(bucketA.lat, bucketB.lat)
        XCTAssertEqual(bucketA.lon, bucketB.lon)
    }

    func testBucketDiffersForFarCoordinates() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let a = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let b = CLLocationCoordinate2D(latitude: 35.7000, longitude: 139.7600) // 約2.2km北
        let bucketA = service.bucket(for: a)
        let bucketB = service.bucket(for: b)
        XCTAssertNotEqual(bucketA.lat, bucketB.lat)
    }

    func testBucketCenterIsCloseToOriginalCoordinate() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let coordinate = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let bucket = service.bucket(for: coordinate)
        let center = CLLocation(latitude: bucket.centerLat, longitude: bucket.centerLon)
        let original = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // セルサイズ75mなので、中心は元の点から半径75m程度以内のはず(対角でも100m強)。
        XCTAssertLessThan(center.distance(from: original), 110)
    }

    // MARK: - bucketKey(for:)

    func testBucketKeyIsInjectiveForDistinctBuckets() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let a = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let b = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7700)
        XCTAssertNotEqual(service.bucketKey(for: a), service.bucketKey(for: b))
    }

    func testBucketKeyIsStableForTheSameCoordinate() {
        let service = ExplorationService(persistence: PersistenceController(inMemory: true))
        let coordinate = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        XCTAssertEqual(service.bucketKey(for: coordinate), service.bucketKey(for: coordinate))
    }

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
}
