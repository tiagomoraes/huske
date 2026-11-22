import XCTest
@testable import Huske

/// The Shortcuts / Siri / Action button surface: what each command does when
/// nothing is recording, how transcripts come out, and what a recording looks
/// like to Shortcuts. (Starting needs the microphone, which CI doesn't have;
/// that path is covered by RecorderInterruptionTests where it is available.)
@MainActor
final class RecordingIntentsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingIntentsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecorder() -> RecorderController {
        RecorderController(library: LibraryStore(rootDirectory: directory), liveActivity: LiveActivityController())
    }

    // MARK: commands while idle

    func testStopAndPauseWithNothingRecordingSayNotRecording() async {
        let recorder = makeRecorder()
        let stop = await recorder.handle(.stop(recordingID: nil))
        XCTAssertEqual(stop, .notRecording)
        let pause = await recorder.handle(.togglePause(recordingID: nil))
        XCTAssertEqual(pause, .notRecording)
        XCTAssertEqual(recorder.phase, .idle)
    }

    func testLiveActivityButtonsForAnotherRecordingDoNothing() async {
        let recorder = makeRecorder()
        let outcome = await recorder.handle(.stop(recordingID: "stale-activity"))
        XCTAssertEqual(outcome, .notRecording)
        XCTAssertEqual(recorder.phase, .idle)
    }

    func testFailuresBecomeErrorsThePersonCanRead() {
        XCTAssertEqual(RecordingIntentError.from(.failed("Allow the microphone."))?.message, "Allow the microphone.")
        XCTAssertNotNil(RecordingIntentError.from(.unavailable))
        XCTAssertNil(RecordingIntentError.from(.started(recordingID: "a")))
        XCTAssertNil(RecordingIntentError.from(.notRecording))
    }

    // MARK: transcripts

    private let markdown = """
    # 09:30 – 09:45 (Wed 2026-05-07)

    [09:30:00 · mic] Olá, vamos começar.

    [09:30:08 · system] Hoje queria revisar o roadmap.
    """

    private func recording(transcript: String?, fetched: Bool = true) -> Recording {
        Recording(id: "r1", title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 1_000_000),
                  duration: 754.4, fileName: "r1.m4a", capture: .complete,
                  transcript: fetched ? TranscriptRecord(markdown: transcript, fetchedAt: Date()) : nil)
    }

    func testTextFormatKeepsOnlyWhatWasSaid() {
        let text = TranscriptText.render(recording(transcript: markdown), as: .text)
        XCTAssertEqual(text, "Olá, vamos começar.\n\nHoje queria revisar o roadmap.")
    }

    func testMarkdownFormatIsTheMacTranscript() {
        XCTAssertEqual(TranscriptText.render(recording(transcript: markdown), as: .markdown), markdown)
    }

    func testNoTranscriptYetExplainsWhere() {
        let pending = recording(transcript: nil, fetched: false)
        XCTAssertNil(TranscriptText.render(pending, as: .text))
        XCTAssertTrue(TranscriptText.missing(pending, status: "Queued on your Mac").contains("(queued on your Mac)"))

        let silent = recording(transcript: nil)
        XCTAssertNil(TranscriptText.render(silent, as: .text))
        XCTAssertTrue(TranscriptText.missing(silent, status: "Transcribed").contains("no speech"))
    }

    // MARK: the entity

    func testEntityMirrorsTheRecording() {
        let entity = RecordingEntity(recording: recording(transcript: markdown), status: "Transcribed")
        XCTAssertEqual(entity.id, "r1")
        XCTAssertEqual(entity.title, "Weekly sync")
        XCTAssertEqual(entity.duration.converted(to: .seconds).value, 754)
        XCTAssertTrue(entity.isTranscribed)
        XCTAssertEqual(entity.transcript, markdown)
        XCTAssertEqual(entity.status, "Transcribed")

        let pending = RecordingEntity(recording: recording(transcript: nil, fetched: false), status: "Waiting for your Mac")
        XCTAssertFalse(pending.isTranscribed)
        XCTAssertEqual(pending.transcript, "")
    }

    // MARK: Live Activity timer slot

    func testCompactTimerWidensJustBeforeTheHour() {
        func state(elapsed: TimeInterval) -> RecordingActivityAttributes.ContentState {
            let now = Date()
            return .init(phase: .paused, title: "t", timerStart: now.addingTimeInterval(-elapsed),
                         pausedAt: now, pauseReason: nil)
        }
        XCTAssertFalse(state(elapsed: 59 * 60).needsHourWidth)
        XCTAssertTrue(state(elapsed: 59 * 60 + 31).needsHourWidth)
        XCTAssertGreaterThan(state(elapsed: 3700).compactTimerWidth, state(elapsed: 60).compactTimerWidth)
    }
}
