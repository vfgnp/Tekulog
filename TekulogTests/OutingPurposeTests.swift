import XCTest
import CoreData
@testable import Tekulog

final class OutingPurposeTests: XCTestCase {

    func testEveryCaseHasANonEmptyDisplayNameAndSymbol() {
        for purpose in OutingPurpose.allCases {
            XCTAssertFalse(purpose.displayName.isEmpty, "\(purpose) の displayName が空")
            XCTAssertFalse(purpose.symbolName.isEmpty, "\(purpose) の symbolName が空")
        }
    }

    func testRawValuesAreUniqueAndStable() {
        // Core Data に文字列として永続化するため、rawValue の一意性・安定性は重要。
        let rawValues = OutingPurpose.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count, "rawValue が重複している")
    }
}

final class WalkSessionPurposeExtensionTests: XCTestCase {

    func testPurposeRoundTripsThroughPurposeRaw() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let session = WalkSession(context: context)
        session.id = UUID()
        session.startedAt = Date()

        session.purpose = .shopping
        XCTAssertEqual(session.purposeRaw, "shopping")
        XCTAssertEqual(session.purpose, .shopping)
    }

    func testPurposeFallsBackToOutingForUnknownRawValue() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let session = WalkSession(context: context)
        session.id = UUID()
        session.startedAt = Date()

        session.purposeRaw = "some-future-unknown-value"
        XCTAssertEqual(session.purpose, .outing)
    }
}
