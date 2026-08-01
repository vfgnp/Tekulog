import XCTest
import CoreData
@testable import Tekulog

/// `WalkRepository` の外出目的分類まわりの永続化ロジック(finalizeClassification /
/// setPurpose / fetchOldestUnclassifiedSession)を検証する。
final class WalkRepositoryClassificationTests: XCTestCase {

    private func makeRepository() -> WalkRepository {
        WalkRepository(persistence: PersistenceController(inMemory: true))
    }

    private func makeFinalizedSession(in context: NSManagedObjectContext,
                                      startedAt: Date,
                                      endedAt: Date? = Date()) -> WalkSession {
        let session = WalkSession(context: context)
        session.id = UUID()
        session.startedAt = startedAt
        session.endedAt = endedAt
        session.activityKind = .walking
        return session
    }

    func testFinalizeClassificationSetsAllFields() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()

        try await repository.finalizeClassification(sessionID: session.objectID, purpose: .shopping, newCellCount: 3)

        persistence.container.viewContext.refreshAllObjects()
        XCTAssertEqual(session.purpose, .shopping)
        XCTAssertEqual(session.exploredNewCellCount, 3)
        XCTAssertNotNil(session.classifiedAt)
        XCTAssertFalse(session.purposeIsUserSet, "自動判定なのでユーザー設定フラグは立たない")
    }

    func testFinalizeClassificationDoesNotOverwriteAlreadyClassifiedSession() async throws {
        // このテストは「同一 context 内での逐次呼び出し」に対するガードのみを検証する
        // (2つの独立した background context による真の並行アクセスは決定的に再現できないため
        // 自動テスト化していない — post-change-review の指摘参照)。
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()

        try await repository.finalizeClassification(sessionID: session.objectID, purpose: .walk, newCellCount: 5)
        try await repository.finalizeClassification(sessionID: session.objectID, purpose: .shopping, newCellCount: 0)

        persistence.container.viewContext.refreshAllObjects()
        XCTAssertEqual(session.purpose, .walk, "2回目の呼び出しは classifiedAt ガードで無視されるはず")
        XCTAssertEqual(session.exploredNewCellCount, 5)
    }

    func testSetPurposeOverwritesEvenAfterClassification() async throws {
        // setPurpose はユーザーによる明示的な上書きなので、finalizeClassification と違って
        // classifiedAt 済みでも常に反映されるべき。
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()

        try await repository.finalizeClassification(sessionID: session.objectID, purpose: .walk, newCellCount: 0)
        try await repository.setPurpose(sessionID: session.objectID, purpose: .commute)

        persistence.container.viewContext.refreshAllObjects()
        XCTAssertEqual(session.purpose, .commute)
        XCTAssertTrue(session.purposeIsUserSet)
    }

    func testFetchOldestUnclassifiedSessionOrdersByStartedAtAscendingAndExcludesUnended() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let context = persistence.container.viewContext

        let older = makeFinalizedSession(in: context, startedAt: Date().addingTimeInterval(-3600))
        let newer = makeFinalizedSession(in: context, startedAt: Date())
        _ = makeFinalizedSession(in: context, startedAt: Date().addingTimeInterval(-7200), endedAt: nil) // 進行中
        try context.save()

        let first = try await repository.fetchOldestUnclassifiedSession()
        XCTAssertEqual(first?.id, older.objectID)

        try await repository.finalizeClassification(sessionID: older.objectID, purpose: .walk, newCellCount: 0)

        let second = try await repository.fetchOldestUnclassifiedSession()
        XCTAssertEqual(second?.id, newer.objectID)
    }

    func testFetchOldestUnclassifiedSessionReturnsNilWhenNoneLeft() async throws {
        let repository = makeRepository()
        let result = try await repository.fetchOldestUnclassifiedSession()
        XCTAssertNil(result)
    }
}
