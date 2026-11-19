import AVFoundation
import XCTest
@testable import Huske

/// A phone call reaches the app as an AVAudioSession interruption. The
/// recorder must pause with the call as the reason, say so, and never resume
/// on its own when the call ends (the user decides).
@MainActor
final class RecorderInterruptionTests: XCTestCase {
    private func makeRecorder() -> RecorderController {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("huske-rec-\(UUID().uuidString)")
        return RecorderController(library: LibraryStore(rootDirectory: dir), liveActivity: LiveActivityController())
    }

    /// Delivered the way the system does: posted off the main thread, observed
    /// on the main queue. (Posting on the main thread itself would wait on the
    /// main queue from the main queue.)
    private func post(_ type: AVAudioSession.InterruptionType) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                NotificationCenter.default.post(
                    name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
                done.resume()
            }
        }
    }

    /// Uses a real recording (the call path needs AVAudioRecorder). Skipped
    /// where the test host has no microphone permission, e.g. CI.
    func testACallPausesTheRecordingWithTheCallAsReason() async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("microphone permission not granted to the test host")
        }
        let recorder = makeRecorder()
        await recorder.start()
        try XCTSkipUnless(recorder.phase == .recording, "the simulator microphone did not start")
        try await Task.sleep(for: .milliseconds(600))

        await post(.began)
        XCTAssertEqual(recorder.phase, .paused(.interruption))
        XCTAssertNotNil(recorder.notice)
        let pausedAt = recorder.elapsed

        await post(.ended)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(recorder.phase, .paused(.interruption), "no automatic resume after a call")
        XCTAssertEqual(recorder.elapsed, pausedAt, accuracy: 0.05, "time does not run while paused")

        recorder.resume()
        XCTAssertEqual(recorder.phase, .recording)
        recorder.stop()
    }

    func testAnInterruptionWhileIdleChangesNothing() async {
        let recorder = makeRecorder()
        await post(.began)
        XCTAssertEqual(recorder.phase, .idle)
    }
}
