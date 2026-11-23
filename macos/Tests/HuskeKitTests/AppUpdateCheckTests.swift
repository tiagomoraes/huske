// The app's own "is there a newer Huske.app?" check. The engine has printed a
// PyPI banner since it shipped, but only to a TTY — which an app user never
// sees, so a new release was invisible to exactly the people who installed the
// zip.

import XCTest

@testable import HuskeKit

final class AppUpdateCheckTests: XCTestCase {
    private func payload(
        tag: String = "v0.15.0", draft: Bool = false, prerelease: Bool = false,
        asset: String? = "Huske.app.zip"
    ) -> Data {
        let assets = asset.map {
            """
            [{"name": "\($0)", "browser_download_url": "https://example.test/\($0)"}]
            """
        } ?? "[]"
        return Data(
            """
            {"tag_name": "\(tag)",
             "html_url": "https://github.com/tiagomoraes/huske/releases/tag/\(tag)",
             "draft": \(draft), "prerelease": \(prerelease),
             "assets": \(assets)}
            """.utf8)
    }

    func testParsesTagPageAndAsset() {
        let release = AppUpdateCheck.parse(payload())
        XCTAssertEqual(release?.tag, "v0.15.0")
        XCTAssertEqual(release?.downloadURL?.lastPathComponent, "Huske.app.zip")
        XCTAssertEqual(release?.version, EngineVersion("0.15.0"))
    }

    func testReleaseWithoutTheAppAssetStillLinksToItsPage() {
        // A release that predates the app, or one whose asset upload failed:
        // the page is still the right place to send someone.
        let release = AppUpdateCheck.parse(payload(asset: nil))
        XCTAssertNil(release?.downloadURL)
        XCTAssertNotNil(release?.pageURL)
    }

    func testDraftsAndPrereleasesAreNotOffered() {
        XCTAssertNil(AppUpdateCheck.parse(payload(draft: true)))
        XCTAssertNil(AppUpdateCheck.parse(payload(prerelease: true)))
    }

    func testGarbageIsSilent() {
        XCTAssertNil(AppUpdateCheck.parse(Data("not json".utf8)))
        XCTAssertNil(AppUpdateCheck.parse(Data("{}".utf8)))
    }

    func testComparesVersionsNumericallyNotLexically() {
        // The trap this whole codebase keeps tripping over: "0.9.0" > "0.11.0"
        // as strings.
        let release = AppUpdateCheck.parse(payload(tag: "v0.11.0"))!
        XCTAssertTrue(AppUpdateCheck.isNewer(release, than: "0.9.0"))
        XCTAssertFalse(AppUpdateCheck.isNewer(release, than: "0.11.0"))
        XCTAssertFalse(AppUpdateCheck.isNewer(release, than: "0.12.0"))
    }

    func testAnUnreadableVersionOnEitherSideStaysQuiet() {
        let release = AppUpdateCheck.parse(payload(tag: "nightly"))!
        XCTAssertFalse(AppUpdateCheck.isNewer(release, than: "0.14.0"))
        let good = AppUpdateCheck.parse(payload())!
        XCTAssertFalse(AppUpdateCheck.isNewer(good, than: "unknown"))
    }

    func testHonoursTheEnginesOptOutVariable() {
        XCTAssertTrue(AppUpdateCheck.isDisabled(environment: ["HUSKE_NO_UPDATE_CHECK": "1"]))
        XCTAssertTrue(AppUpdateCheck.isDisabled(environment: ["HUSKE_NO_UPDATE_CHECK": "TRUE"]))
        XCTAssertFalse(AppUpdateCheck.isDisabled(environment: ["HUSKE_NO_UPDATE_CHECK": "0"]))
        XCTAssertFalse(AppUpdateCheck.isDisabled(environment: [:]))
    }

    func testCacheLivesBesideTheEnginesOwnCheck() {
        let url = AppUpdateCheck.cacheURL(environment: ["XDG_CACHE_HOME": "/tmp/cache"])
        XCTAssertEqual(url.path, "/tmp/cache/huske/app-update-check.json")
    }

    func testFreshnessWindowIsADay() {
        let now = Date()
        XCTAssertTrue(AppUpdateCheck.isFresh(now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(AppUpdateCheck.isFresh(now.addingTimeInterval(-25 * 3600), now: now))
        // A cache written in the future (clock change) must not pin forever.
        XCTAssertFalse(AppUpdateCheck.isFresh(now.addingTimeInterval(3600), now: now))
    }

    func testCacheRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hsk-update-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let release = AppUpdateCheck.parse(payload())
        AppUpdateCheck.storeCache(
            AppUpdateCheck.CachedCheck(checkedAt: Date(), release: release), at: url)
        XCTAssertEqual(AppUpdateCheck.loadCache(at: url)?.release, release)
    }
}
