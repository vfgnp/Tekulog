import XCTest
import CoreData
import CoreLocation
@testable import Tekulog

/// 探索グリッドまわりのテストが共用する、インメモリストアへのデータ投入ヘルパー。
enum ExplorationTestSupport {

    /// `start` から北へ `meters` 進む直線の経路(30m 間隔。GPS の記録間隔より粗いが、
    /// `ExplorationService.densify` が補間しない程度に細かい)。
    static func routeNorth(from start: CLLocationCoordinate2D, meters: Double) -> [CLLocationCoordinate2D] {
        stride(from: 0.0, through: meters, by: 30).map {
            CLLocationCoordinate2D(latitude: start.latitude + $0 / 111_320, longitude: start.longitude)
        }
    }

    /// 確定済み(`endedAt` あり)のセッションを経路つきで作る。`purpose` を渡すと分類済み
    /// (`classifiedAt` あり)、`nil` なら未分類。
    ///
    /// 未分類のセッションは `.running` にしておくこと: 外出目的の自動判定は徒歩・自転車だと
    /// MapKit の店舗検索(通信)を呼びうるが、ランニングは通信なしで `.run` に確定する。
    @discardableResult
    static func makeSession(in context: NSManagedObjectContext,
                            startedAt: Date,
                            kind: ActivityKind = .walking,
                            route: [CLLocationCoordinate2D],
                            purpose: OutingPurpose? = nil,
                            purposeIsUserSet: Bool = false,
                            exploredNewCellCount: Int = 0) -> WalkSession {
        let session = WalkSession(context: context)
        session.id = UUID()
        session.startedAt = startedAt
        session.endedAt = startedAt.addingTimeInterval(600)
        session.activityKind = kind
        session.exploredNewCellCount = Int64(exploredNewCellCount)
        if let purpose {
            session.purpose = purpose
            session.purposeIsUserSet = purposeIsUserSet
            session.classifiedAt = startedAt.addingTimeInterval(700)
        }
        for (offset, coordinate) in route.enumerated() {
            let point = RoutePoint(context: context)
            point.latitude = coordinate.latitude
            point.longitude = coordinate.longitude
            point.timestamp = startedAt.addingTimeInterval(Double(offset))
            point.session = session
        }
        return session
    }

    /// 経路を順に記録したとき、それぞれが新しく開拓するセル数(期待値の算出用。
    /// 検証対象とは別のインメモリストアで逐次実行する)。
    static func sequentialNewCellCounts(_ routes: [[CLLocationCoordinate2D]]) async throws -> [Int] {
        let reference = ExplorationService(persistence: PersistenceController(inMemory: true))
        var counts: [Int] = []
        for route in routes {
            counts.append(try await reference.recordVisited(coordinates: route, firstSeenAt: Date()))
        }
        return counts
    }

    /// テストごとに隔離した `UserDefaults`(アプリ本体の設定を汚さない)。
    static func makeDefaults(_ testCase: XCTestCase) -> UserDefaults {
        let name = "TekulogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        testCase.addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
}
