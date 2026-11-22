import HuskeSync
import XCTest
@testable import Huske

/// "Paste pairing link" gets whatever was copied — often the link at the end
/// of a sentence, with the sentence's punctuation attached.
final class PairingLinkPastedTextTests: XCTestCase {
    private let invite = PairingInvite.mint(macID: "8B1D3C2E-5F60-4A7B-9C1D-2E3F4A5B6C7D", macName: "Studio")

    func testToleratesPunctuationAfterThePastedLink() throws {
        for suffix in [".", ",", ";", "!", "?", "…", "”", "’", ").", "”.", ".\n", ".  "] {
            let text = "Open this on your iPhone: \(invite.url.absoluteString)\(suffix)"
            let parsed = try XCTUnwrap(PairingLink.parse(text: text).invite, "suffix \(suffix.debugDescription)")
            XCTAssertEqual(parsed.key, invite.key)
            XCTAssertEqual(parsed.deviceID, invite.deviceID)
        }
    }

    func testTrimmingNeverRescuesADamagedKey() {
        let link = invite.url.absoluteString
        // Cut short, then a period: still too few key bytes.
        XCTAssertEqual(PairingLink.parse(text: String(link.dropLast(3)) + "."), .invalid)
        // A stray character inside the key is not punctuation after the link.
        let inside = String(link.dropLast(1)) + "." + String(link.suffix(1))
        XCTAssertEqual(PairingLink.parse(text: inside), .invalid)
    }
}
