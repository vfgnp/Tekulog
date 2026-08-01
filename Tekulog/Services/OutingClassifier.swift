import Foundation
import CoreData
import CoreLocation
import MapKit

/// 外出目的(`OutingPurpose`)の自動判定。`ActivityKind`(モーション検出結果)だけでは
/// 「なんの外出か」は分からないため、位置・時刻・過去の履歴から推定する。
/// 使う外部サービスは MapKit のローカル検索のみ(Apple のサービスに座標が渡るのは
/// 既存の `PlaceLookupService` の逆ジオコーディングと同じ扱い。開発者サーバへは何も送らない)。
struct OutingClassifier: Sendable {
    private let repository: WalkRepository

    init(repository: WalkRepository) {
        self.repository = repository
    }

    /// セッション確定時に一度だけ呼ぶ。ルート座標が取れない(GPSが一切入らなかった)場合は
    /// ランニングなら `.run`、それ以外は `.outing` にフォールバックする。
    func classify(kind: ActivityKind,
                  sessionID: NSManagedObjectID,
                  startedAt: Date,
                  coordinates: [CLLocationCoordinate2D],
                  totalDistance: Double,
                  home: CLLocationCoordinate2D?) async -> OutingPurpose {
        if kind == .running {
            return .run
        }
        guard let start = coordinates.first, let end = coordinates.last else {
            return .outing
        }

        if await isCommute(sessionID: sessionID, startedAt: startedAt, start: start, end: end) {
            return .commute
        }

        if totalDistance <= Tunables.shoppingMaxSessionDistanceMeters,
           await hasNearbyShop(at: end) {
            return .shopping
        }

        let radiusThreshold = home != nil ? Tunables.walkRadiusFromHomeMeters : Tunables.walkDistanceCapMeters
        let deviation: Double
        if let home {
            deviation = coordinates.map { distance($0, home) }.max() ?? 0
        } else {
            deviation = totalDistance
        }
        return deviation <= radiusThreshold ? .walk : .outing
    }

    // MARK: - 通勤判定

    /// 同じ曜日区分(平日/週末)・近い時間帯・近い開始/終了地点の過去セッションが
    /// `Tunables.commuteMinRepeatCount` 回以上あれば通勤とみなす(往復どちらの向きも一致とみなす)。
    private func isCommute(sessionID: NSManagedObjectID,
                           startedAt: Date,
                           start: CLLocationCoordinate2D,
                           end: CLLocationCoordinate2D) async -> Bool {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -Tunables.commuteLookbackDays, to: startedAt) ?? .distantPast
        guard let candidates = try? await repository.fetchCommuteCandidates(
            since: since, before: startedAt, excluding: sessionID
        ) else { return false }

        var matches = 0
        for candidate in candidates {
            if matchesCommutePattern(referenceStartedAt: startedAt, referenceStart: start, referenceEnd: end,
                                     candidate: candidate, calendar: calendar) {
                matches += 1
                if matches >= Tunables.commuteMinRepeatCount { return true }
            }
        }
        return false
    }

    /// 過去セッション1件が「今回の通勤パターン」と一致するか(曜日区分・時間帯・地点、往復どちらも可)。
    /// 純粋な判定ロジックなのでテストから直接検証できるよう `internal`。
    func matchesCommutePattern(referenceStartedAt: Date,
                               referenceStart: CLLocationCoordinate2D,
                               referenceEnd: CLLocationCoordinate2D,
                               candidate: CommuteCandidate,
                               calendar: Calendar = .current) -> Bool {
        guard isWeekend(referenceStartedAt, calendar: calendar) == isWeekend(candidate.startedAt, calendar: calendar) else {
            return false
        }
        let referenceMinutes = minutesOfDay(referenceStartedAt, calendar: calendar)
        let candidateMinutes = minutesOfDay(candidate.startedAt, calendar: calendar)
        guard abs(candidateMinutes - referenceMinutes) <= Tunables.commuteTimeWindowMinutes else { return false }

        let sameDirection = distance(referenceStart, candidate.startCoordinate) <= Tunables.commuteCoordinateMatchRadiusMeters
            && distance(referenceEnd, candidate.endCoordinate) <= Tunables.commuteCoordinateMatchRadiusMeters
        let reverseDirection = distance(referenceStart, candidate.endCoordinate) <= Tunables.commuteCoordinateMatchRadiusMeters
            && distance(referenceEnd, candidate.startCoordinate) <= Tunables.commuteCoordinateMatchRadiusMeters
        return sameDirection || reverseDirection
    }

    func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    func minutesOfDay(_ date: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    // MARK: - お買い物判定

    /// セッション終了地点の近くに店舗系 POI があるか(MapKit ローカル検索、端末外へは送らない)。
    private func hasNearbyShop(at coordinate: CLLocationCoordinate2D) async -> Bool {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: Tunables.shoppingSearchRadiusMeters)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
            .store, .foodMarket, .pharmacy, .bakery
        ])
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return false }
        return !response.mapItems.isEmpty
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
