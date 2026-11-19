import XCTest
@testable import Huske

final class RecordingTitleTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-11-25 14:03:27 UTC
    private let date = Date(timeIntervalSince1970: 1_795_615_407)

    func testDefaultUsesTheLocalClock() {
        let title = RecordingTitle.makeDefault(startedAt: date, locale: Locale(identifier: "en_GB"), timeZone: utc)
        XCTAssertEqual(title, "Recording 14:03")
    }

    func testDefaultFollowsTheUsersTimeZone() throws {
        let saoPaulo = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        let title = RecordingTitle.makeDefault(startedAt: date, locale: Locale(identifier: "pt_BR"), timeZone: saoPaulo)
        XCTAssertEqual(title, "Recording 11:03")
    }

    func testTwelveHourLocales() {
        let title = RecordingTitle.makeDefault(startedAt: date, locale: Locale(identifier: "en_US"), timeZone: utc)
        XCTAssertTrue(title.hasPrefix("Recording 2:03"), title)
    }

    func testCollisionsGetASuffix() {
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(
            RecordingTitle.makeDefault(startedAt: date, existing: ["Recording 14:03"], locale: locale, timeZone: utc),
            "Recording 14:03 (2)")
        XCTAssertEqual(
            RecordingTitle.makeDefault(startedAt: date, existing: ["Recording 14:03", "Recording 14:03 (2)"],
                                       locale: locale, timeZone: utc),
            "Recording 14:03 (3)")
        XCTAssertEqual(
            RecordingTitle.makeDefault(startedAt: date, existing: ["Standup"], locale: locale, timeZone: utc),
            "Recording 14:03")
    }

    func testNormalization() {
        XCTAssertEqual(RecordingTitle.normalized("  Reunião \n com   a Ana "), "Reunião com a Ana")
        XCTAssertNil(RecordingTitle.normalized(" \n\t "))
        XCTAssertEqual(RecordingTitle.normalized(String(repeating: "a", count: 500))?.count, 120)
    }
}
