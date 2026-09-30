import XCTest
import CoreData
@testable import Tekulog

/// `WalkRepository` の外出目的分類まわりの永続化ロジック(finalizeClassification /
/// setPurpose / fetchOldestUnclassifiedSession)を検証する。
///
/// `@MainActor`: 検証のために `viewContext`(メインキュー専用)の `WalkSession` を作成・再読込・
/// 参照するため。async のテストは既定だとバックグラウンドで走り、`viewContext` をそこから触ると
/// メインキューでの自動マージと競合して落ちることがある(Release 構成の実行で実際に落ちた)。
@MainActor
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

    /// ユーザーが先に目的を手動で決めていた場合、後から届いた自動判定は目的を上書きしない
    /// (新エリア数と分類済みの印は書く)。
    func testFinalizeClassificationKeepsAPurposeTheUserAlreadySet() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()

        try await repository.setPurpose(sessionID: session.objectID, purpose: .commute)
        try await repository.finalizeClassification(sessionID: session.objectID, purpose: .walk, newCellCount: 4)

        persistence.container.viewContext.refreshAllObjects()
        XCTAssertEqual(session.purpose, .commute, "手動で決めた目的が自動判定で上書きされた")
        XCTAssertTrue(session.purposeIsUserSet)
        XCTAssertEqual(session.exploredNewCellCount, 4)
        XCTAssertNotNil(session.classifiedAt)
    }

    // MARK: - グリッド再構築用

    func testFetchFinalizedSessionsReturnsEndedSessionsOldestFirstWithClassificationFlag() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let context = persistence.container.viewContext
        let now = Date()

        let newest = makeFinalizedSession(in: context, startedAt: now)
        let oldest = makeFinalizedSession(in: context, startedAt: now.addingTimeInterval(-7200))
        let middle = makeFinalizedSession(in: context, startedAt: now.addingTimeInterval(-3600))
        _ = makeFinalizedSession(in: context, startedAt: now.addingTimeInterval(-60), endedAt: nil) // 進行中
        try context.save()
        try await repository.finalizeClassification(sessionID: middle.objectID, purpose: .walk, newCellCount: 1)

        let sessions = try await repository.fetchFinalizedSessions()
        XCTAssertEqual(sessions.map(\.id), [oldest.objectID, middle.objectID, newest.objectID],
                       "確定済みだけを古い順に返す(進行中は含めない)")
        XCTAssertEqual(sessions.map(\.isClassified), [false, true, false])
    }

    func testSetExploredNewCellCountTouchesNothingElse() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()
        try await repository.finalizeClassification(sessionID: session.objectID, purpose: .shopping, newCellCount: 9)
        try await repository.setPurpose(sessionID: session.objectID, purpose: .commute)
        persistence.container.viewContext.refreshAllObjects()
        let classifiedAt = session.classifiedAt

        try await repository.setExploredNewCellCount(sessionID: session.objectID, count: 3)

        persistence.container.viewContext.refreshAllObjects()
        XCTAssertEqual(session.exploredNewCellCount, 3)
        XCTAssertEqual(session.purpose, .commute)
        XCTAssertTrue(session.purposeIsUserSet)
        XCTAssertEqual(session.classifiedAt, classifiedAt)
    }

    func testIsClassifiedReflectsClassifiedAt() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()

        let before = try await repository.isClassified(sessionID: session.objectID)
        XCTAssertFalse(before)
        try await repository.finalizeClassification(sessionID: session.objectID, purpose: .walk, newCellCount: 0)
        let after = try await repository.isClassified(sessionID: session.objectID)
        XCTAssertTrue(after)
    }

    /// 削除済みのセッションは「もう処理不要」として扱い、エラーにしない。
    func testRebuildHelpersTreatADeletedSessionAsNothingToDo() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()
        let sessionID = session.objectID

        let existing = try await repository.fetchRouteCoordinatesIfExists(for: sessionID)
        XCTAssertNotNil(existing, "存在するセッションは(経路が空でも)nil にならない")

        try await repository.deleteSession(sessionID)

        let classified = try await repository.isClassified(sessionID: sessionID)
        XCTAssertTrue(classified)
        let coordinates = try await repository.fetchRouteCoordinatesIfExists(for: sessionID)
        XCTAssertNil(coordinates)
        try await repository.setExploredNewCellCount(sessionID: sessionID, count: 5)   // 投げないこと
        // 分類の通信を待つ間に削除された外出へ結果を書こうとしても、再構築を止めない。
        try await repository.finalizeClassification(sessionID: sessionID, purpose: .walk, newCellCount: 1)
    }

    /// 外出を削除しても、その外出で開拓したセルは残る(現行踏襲)。
    func testDeletingASessionKeepsItsExploredCells() async throws {
        let persistence = PersistenceController(inMemory: true)
        let repository = WalkRepository(persistence: persistence)
        let exploration = ExplorationService(persistence: persistence)
        let session = makeFinalizedSession(in: persistence.container.viewContext, startedAt: Date())
        try persistence.container.viewContext.save()
        let recorded = try await exploration.recordVisited(
            coordinates: [.init(latitude: 35.68, longitude: 139.76), .init(latitude: 35.684, longitude: 139.76)],
            firstSeenAt: Date())
        XCTAssertGreaterThan(recorded, 0)

        try await repository.deleteSession(session.objectID)

        let remaining = try await exploration.totalExploredCellCount()
        XCTAssertEqual(remaining, recorded)
    }
}
