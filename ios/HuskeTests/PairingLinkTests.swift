import HuskeSync
import XCTest
@testable import Huske

final class PairingLinkTests: XCTestCase {
    private let invite = PairingInvite.mint(macID: "8B1D3C2E-5F60-4A7B-9C1D-2E3F4A5B6C7D", macName: "Tiago’s MacBook Pro")

    func testParsesTheMacsURL() throws {
        let outcome = PairingLink.parse(url: invite.url)
        let parsed = try XCTUnwrap(outcome.invite)
        XCTAssertEqual(parsed.macID, invite.macID)
        XCTAssertEqual(parsed.macName, "Tiago’s MacBook Pro")
        XCTAssertEqual(parsed.deviceID, invite.deviceID)
        XCTAssertEqual(parsed.key, invite.key)
    }

    func testFindsTheLinkInsidePastedText() throws {
        let text = "Pair your phone: \(invite.url.absoluteString)\nThanks!"
        let parsed = try XCTUnwrap(PairingLink.parse(text: text).invite)
        XCTAssertEqual(parsed.deviceID, invite.deviceID)
    }

    func testTruncatedLinkIsInvalidNotIgnored() {
        let truncated = String(invite.url.absoluteString.dropLast(10))
        XCTAssertEqual(PairingLink.parse(text: truncated), .invalid)
        XCTAssertNotNil(PairingLink.message(for: .invalid))
    }

    func testOtherTextAndURLsAreNotPairingLinks() throws {
        XCTAssertEqual(PairingLink.parse(text: "hello"), .notPairingLink)
        XCTAssertEqual(PairingLink.parse(url: try XCTUnwrap(URL(string: "https://example.com/pair"))), .notPairingLink)
        XCTAssertEqual(PairingLink.parse(url: try XCTUnwrap(URL(string: "huske://record"))), .notPairingLink)
    }

    func testFutureProtocolVersionIsInvalid() throws {
        let future = invite.url.absoluteString.replacingOccurrences(of: "v=1", with: "v=9")
        XCTAssertEqual(PairingLink.parse(url: try XCTUnwrap(URL(string: future))), .invalid)
    }

    func testSchemeAndHostAreCaseInsensitive() throws {
        let shouty = invite.url.absoluteString.replacingOccurrences(of: "huske://pair", with: "HUSKE://Pair")
        XCTAssertTrue(PairingLink.isPairingURL(try XCTUnwrap(URL(string: shouty))))
    }

    func testExpiredLinkIsReportedAsExpired() throws {
        let old = PairingInvite.mint(macID: "MAC", macName: "Mac", now: Date().addingTimeInterval(-3600))
        XCTAssertEqual(PairingLink.parse(url: old.url), .expired)
        XCTAssertNotNil(PairingLink.message(for: .expired))
        // Within the clock-skew tolerance it still pairs.
        let justPast = PairingInvite.mint(
            macID: "MAC", macName: "Mac",
            now: Date().addingTimeInterval(-SyncConstants.inviteLifetime - 30))
        XCTAssertNotNil(PairingLink.parse(url: justPast.url).invite)
    }
}
