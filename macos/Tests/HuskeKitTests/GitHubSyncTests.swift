import XCTest

@testable import HuskeKit

/// The JSON lines below are what `huske sync … --json` prints (see
/// `huske/sync/account.py`); PythonInteropTests checks the live CLI too.
final class GitHubSyncTests: XCTestCase {
    func testLoginStreamsACodeThenConnects() {
        let events = GitHubSyncEvent.parseAll(
            """
            {"event": "code", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": 899}
            {"event": "connected", "login": "octo", "install_url": "https://github.com/apps/huske-sync/installations/new"}
            """)
        XCTAssertEqual(
            events,
            [
                .code(
                    GitHubDeviceCode(
                        userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device",
                        expiresIn: 899)),
                .connected(login: "octo"),
            ])
    }

    func testStatusDecodes() {
        let event = GitHubSyncEvent.parse(
            #"{"event": "status", "auth": "github-app", "connected": true, "login": "octo", "sign_in_renewable_until": "2027-05-20T12:00:00+00:00", "repository": "octo/t", "remote": "https://github.com/octo/t.git", "sync_enabled": true, "install_url": "https://github.com/apps/huske-sync/installations/new", "new_repository_url": "https://github.com/new?name=huske-transcripts&visibility=private"}"#
        )
        guard case .status(let status)? = event else { return XCTFail("not a status: \(String(describing: event))") }
        XCTAssertTrue(status.usesGitHubApp)
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.login, "octo")
        XCTAssertEqual(status.repository, "octo/t")
        XCTAssertTrue(status.syncEnabled)
    }

    func testSharedRepositoriesSeparatePrivateFromPublic() {
        let event = GitHubSyncEvent.parse(
            #"{"event": "repos", "installed": true, "repository_selection": "all", "repositories": [{"full_name": "octo/transcripts", "private": true, "html_url": "u"}, {"full_name": "octo/site", "private": false, "html_url": "u"}], "install_url": "i", "installation_settings_url": "https://github.com/settings/installations/42", "new_repository_url": "n", "current": null}"#
        )
        guard case .shared(let shared)? = event else { return XCTFail("not repos") }
        XCTAssertTrue(shared.sharesEverything)
        XCTAssertEqual(shared.usable.map(\.fullName), ["octo/transcripts"])
        XCTAssertEqual(shared.publicOnes.map(\.fullName), ["octo/site"])
        XCTAssertNil(shared.current)
    }

    func testErrorsCarryTheReconnectHint() {
        XCTAssertEqual(
            GitHubSyncEvent.parse(#"{"event": "error", "message": "expired", "reconnect": true}"#),
            .error(message: "expired", reconnect: true))
        XCTAssertEqual(
            GitHubSyncEvent.parse(#"{"event": "error", "message": "offline"}"#),
            .error(message: "offline", reconnect: false))
    }

    func testNonEventLinesAreIgnored() {
        XCTAssertNil(GitHubSyncEvent.parse("[huske] connected to GitHub as @octo"))
        XCTAssertNil(GitHubSyncEvent.parse(#"{"event": "something-new"}"#))
        XCTAssertEqual(GitHubSyncEvent.parse(#"{"event": "disconnected", "authorizations_url": "x"}"#), .disconnected)
    }
}
