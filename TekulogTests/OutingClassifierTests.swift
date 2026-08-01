import XCTest
import CoreData
import CoreLocation
@testable import Tekulog

final class OutingClassifierTests: XCTestCase {

    private func makeClassifier() -> OutingClassifier {
        OutingClassifier(repository: WalkRepository(persistence: PersistenceController(inMemory: true)))
    }

    /// `classify` は sessionID を「除外対象」としてしか使わないため、実体を持つダミーの
    /// objectID があれば十分(NSManagedObjectID に public な初期化子はないため、
    /// インメモリ context に1件挿入して取得する)。
    private func dummySessionID() -> NSManagedObjectID {
        let context = PersistenceController(inMemory: true).container.viewContext
        let session = WalkSession(context: context)
        session.id = UUID()
        session.startedAt = Date()
        return session.objectID
    }

    // MARK: - isWeekend / minutesOfDay

    func testIsWeekendTrueForSaturdayAndSunday() {
        let classifier = makeClassifier()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-08-01 は土曜日。
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 9))!
        // 2026-08-03 は月曜日。
        let monday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!
        XCTAssertTrue(classifier.isWeekend(saturday, calendar: calendar))
        XCTAssertFalse(classifier.isWeekend(monday, calendar: calendar))
    }

    func testMinutesOfDayConvertsHourAndMinute() {
        let classifier = makeClassifier()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 14, minute: 30))!
        XCTAssertEqual(classifier.minutesOfDay(date, calendar: calendar), 870)
    }

    // MARK: - matchesCommutePattern

    private var tokyoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        tokyoCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testMatchesCommutePatternTrueForSameDirectionSameWeekdayCloseTime() {
        let classifier = makeClassifier()
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let office = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7700)
        // 両方とも平日(2026-08-03, 2026-08-04)の朝8時台。
        let candidate = CommuteCandidate(startedAt: date(2026, 8, 3, 8, 10),
                                         startCoordinate: home, endCoordinate: office)
        let matches = classifier.matchesCommutePattern(
            referenceStartedAt: date(2026, 8, 4, 8, 5),
            referenceStart: home, referenceEnd: office,
            candidate: candidate, calendar: tokyoCalendar)
        XCTAssertTrue(matches)
    }

    func testMatchesCommutePatternTrueForReverseDirection() {
        let classifier = makeClassifier()
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let office = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7700)
        // 候補は office→home(帰り)、今回は home→office(行き)。往復として一致するはず。
        let candidate = CommuteCandidate(startedAt: date(2026, 8, 3, 18, 30),
                                         startCoordinate: office, endCoordinate: home)
        let matches = classifier.matchesCommutePattern(
            referenceStartedAt: date(2026, 8, 4, 18, 40),
            referenceStart: home, referenceEnd: office,
            candidate: candidate, calendar: tokyoCalendar)
        XCTAssertTrue(matches)
    }

    func testMatchesCommutePatternFalseWhenWeekdayCategoryDiffers() {
        let classifier = makeClassifier()
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let office = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7700)
        // 候補は日曜(2026-08-02)、今回は月曜(2026-08-03)。
        let candidate = CommuteCandidate(startedAt: date(2026, 8, 2, 8, 10),
                                         startCoordinate: home, endCoordinate: office)
        let matches = classifier.matchesCommutePattern(
            referenceStartedAt: date(2026, 8, 3, 8, 5),
            referenceStart: home, referenceEnd: office,
            candidate: candidate, calendar: tokyoCalendar)
        XCTAssertFalse(matches)
    }

    func testMatchesCommutePatternFalseWhenTimeWindowExceeded() {
        let classifier = makeClassifier()
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let office = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7700)
        // 同じ平日だが、時刻が Tunables.commuteTimeWindowMinutes(既定90分)を大きく超える。
        let candidate = CommuteCandidate(startedAt: date(2026, 8, 3, 8, 0),
                                         startCoordinate: home, endCoordinate: office)
        let matches = classifier.matchesCommutePattern(
            referenceStartedAt: date(2026, 8, 4, 20, 0),
            referenceStart: home, referenceEnd: office,
            candidate: candidate, calendar: tokyoCalendar)
        XCTAssertFalse(matches)
    }

    func testMatchesCommutePatternFalseWhenCoordinatesAreFarApart() {
        let classifier = makeClassifier()
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let office = CLLocationCoordinate2D(latitude: 35.6900, longitude: 139.7700)
        let farAway = CLLocationCoordinate2D(latitude: 35.9000, longitude: 139.9000)
        let candidate = CommuteCandidate(startedAt: date(2026, 8, 3, 8, 10),
                                         startCoordinate: home, endCoordinate: farAway)
        let matches = classifier.matchesCommutePattern(
            referenceStartedAt: date(2026, 8, 4, 8, 5),
            referenceStart: home, referenceEnd: office,
            candidate: candidate, calendar: tokyoCalendar)
        XCTAssertFalse(matches)
    }

    // MARK: - classify(オフラインで決定的な経路のみ)

    func testClassifyAlwaysReturnsRunForRunningKind() async {
        let classifier = makeClassifier()
        // 距離0(ショッピング判定の閾値内)でもランニングなら即 .run で、
        // ネットワーク呼び出し(お買い物判定)を経由しないはず。
        let purpose = await classifier.classify(
            kind: .running,
            sessionID: dummySessionID(),
            startedAt: Date(),
            coordinates: [CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76)],
            totalDistance: 100,
            home: nil)
        XCTAssertEqual(purpose, .run)
    }

    func testClassifyReturnsOutingWhenNoCoordinates() async {
        let classifier = makeClassifier()
        let purpose = await classifier.classify(
            kind: .walking,
            sessionID: dummySessionID(),
            startedAt: Date(),
            coordinates: [],
            totalDistance: 0,
            home: nil)
        XCTAssertEqual(purpose, .outing)
    }

    func testClassifyReturnsOutingForLongWalkFarFromHomeWithNoHistory() async {
        let classifier = makeClassifier()
        // shoppingMaxSessionDistanceMeters を超える距離にして、お買い物判定(ネットワーク)を
        // スキップさせ、完全にオフラインで決定的な経路だけを通す。
        let start = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let end = CLLocationCoordinate2D(latitude: 35.7200, longitude: 139.8000)
        let home = CLLocationCoordinate2D(latitude: 35.6800, longitude: 139.7600)
        let purpose = await classifier.classify(
            kind: .walking,
            sessionID: dummySessionID(),
            startedAt: Date(),
            coordinates: [start, end],
            totalDistance: Tunables.shoppingMaxSessionDistanceMeters + 1000,
            home: home)
        XCTAssertEqual(purpose, .outing)
    }
}
