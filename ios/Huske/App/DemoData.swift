// DEBUG-only demo mode for screenshots and UI review without a Mac.
//
// Launch arguments (Xcode scheme or `xcrun simctl launch … -Key value`):
//   -HuskeDemoData YES          seed a sample library in a throwaway directory,
//                               a fake paired Mac, and frozen sync states
//   -HuskeDemoPaired NO         seed the library but leave the Mac unpaired
//   -HuskeDemoRoute detail|latest|mac  open a screen at launch
//   -HuskeAutoRecord YES        start a real recording a second after launch
//   -HuskeAutoStopAfter <s>     …and stop/save it after <s> seconds
//   -HuskeDemoRecording YES     simulated recording (no microphone needed)
//   -HuskeAutoConfirmPairing YES  press "Pair" automatically for an opened link
//   -HuskeOpenURL <url>         handle <url> as if opened via onOpenURL
//   -HuskeSeedSampleRecording YES  add one finished recording (a tone) to the
//                               REAL library, to exercise sync without a mic
//   -HuskeSeedAudioFile <path>  add a copy of an existing audio file (e.g. a
//                               spoken .m4a on the host) as a finished recording

#if DEBUG
import AVFoundation
import Foundation
import HuskeSync

struct DemoMode {
    let isEnabled: Bool
    let paired: Bool
    let route: String?
    let autoRecord: Bool
    /// With autoRecord: stop (and save) after this many seconds — lets an
    /// end-to-end test record real audio, in the background, unattended.
    let autoStopAfter: Double?
    let autoConfirmPairing: Bool
    let simulatedRecording: Bool
    let openURL: URL?
    let seedSample: Bool
    let seedAudioFile: URL?

    static let current: DemoMode = {
        let defaults = UserDefaults.standard
        return DemoMode(
            isEnabled: defaults.bool(forKey: "HuskeDemoData"),
            paired: defaults.object(forKey: "HuskeDemoPaired") == nil || defaults.bool(forKey: "HuskeDemoPaired"),
            route: defaults.string(forKey: "HuskeDemoRoute"),
            autoRecord: defaults.bool(forKey: "HuskeAutoRecord"),
            autoStopAfter: defaults.object(forKey: "HuskeAutoStopAfter") != nil
                ? defaults.double(forKey: "HuskeAutoStopAfter") : nil,
            autoConfirmPairing: defaults.bool(forKey: "HuskeAutoConfirmPairing"),
            simulatedRecording: defaults.bool(forKey: "HuskeDemoRecording"),
            openURL: defaults.string(forKey: "HuskeOpenURL").flatMap(URL.init(string:)),
            seedSample: defaults.bool(forKey: "HuskeSeedSampleRecording"),
            seedAudioFile: defaults.string(forKey: "HuskeSeedAudioFile").map { URL(fileURLWithPath: $0) })
    }()

    static var defaults: UserDefaults {
        UserDefaults(suiteName: "huske.demo") ?? .standard
    }

    /// A fresh demo library directory (never the real one).
    static func resetDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HuskeDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        defaults.removePersistentDomain(forName: "huske.demo")
        return url
    }
}

enum DemoData {
    static let detailRecordingID = "DEMO-0003-IDEA"
    static let uploadingID = "DEMO-0002-UPLOAD"

    static var uploadingState: SyncManager.Activity {
        .uploading(recordingID: uploadingID, fraction: 0.42)
    }

    static let pairedMac = PairedMac(
        macID: "8B1D3C2E-5F60-4A7B-9C1D-2E3F4A5B6C7D",
        macName: "Studio MacBook Pro",
        deviceID: "DEMO-DEVICE",
        key: Data(repeating: 7, count: 32),
        pairedAt: Calendar.current.date(byAdding: .day, value: -12, to: Date()) ?? Date())

    /// Connect always fails quietly — demo sync is frozen anyway.
    struct UnreachableConnector: MacConnecting {
        func connect(timeout: TimeInterval) async throws -> any MacSession {
            throw CancellationError()
        }
    }

    @MainActor
    static func seed(into library: LibraryStore) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let mac = pairedMac.macID

        func remote(_ stage: RemoteStage, _ detail: String? = nil, _ progress: Double? = nil) -> SyncRecord {
            SyncRecord(macID: mac, uploadedAt: Date().addingTimeInterval(-600),
                       remote: RemoteSnapshot(stage: stage, detail: detail, progress: progress,
                                              updatedAt: Date().addingTimeInterval(-30)))
        }

        func make(_ id: String, _ title: String, _ start: Date, _ seconds: TimeInterval,
                  capture: CaptureState = .complete, sync: SyncRecord = SyncRecord(),
                  transcript: String? = nil, note: String? = nil) -> Recording {
            Recording(
                id: id, title: title, startedAt: start, duration: seconds,
                fileName: "\(id).m4a", byteCount: Int64(seconds * 8_000),
                inputName: "iPhone Microphone", capture: capture, sync: sync,
                transcript: transcript.map { TranscriptRecord(markdown: $0, fetchedAt: Date().addingTimeInterval(-1500)) },
                note: note)
        }

        let ideaStart = at(0, 11, 2)
        let recordings: [Recording] = [
            make("DEMO-0001-WAIT", "Recording 16:31", at(0, 16, 31), 52),
            make(uploadingID, "Recording 16:05", at(0, 16, 5), 271),
            make("DEMO-0004-QUEUE", "Walk & talk with Ana", at(0, 15, 12), 598, sync: remote(.queued)),
            make("DEMO-0005-TRANS", "Supplier call", at(0, 14, 20), 1367,
                 sync: remote(.transcribing, "2/3 chunks", 0.66)),
            make(detailRecordingID, "Idea: inbox triage", ideaStart, 84,
                 sync: remote(.transcribed, "1 transcript chunk", 1), transcript: ideaTranscript(ideaStart)),
            make("DEMO-0006-STAND", "Standup", at(0, 9, 30), 852,
                 sync: remote(.transcribed, "1 transcript chunk", 1), transcript: standupTranscript(at(0, 9, 30))),
            make("DEMO-0007-REVIEW", "Design review", at(-1, 15, 10), 2465,
                 sync: remote(.transcribed, "3 transcript chunks", 1), transcript: reviewTranscript(at(-1, 15, 10))),
            make("DEMO-0008-FAIL", "Interview — Jonas", at(-1, 10, 3), 3153,
                 sync: remote(.failed, "afconvert could not decode the audio")),
            make("DEMO-0009-LUNCH", "Lunch & learn", at(-2, 13, 0), 2300,
                 sync: remote(.transcribed, "3 transcript chunks", 1), transcript: lunchTranscript(at(-2, 13, 0))),
            make("DEMO-0010-DAMAGED", "Recording 08:12", at(-2, 8, 12), 0, capture: .damaged,
                 note: "Huske closed unexpectedly while recording and this audio couldn't be recovered."),
        ]
        library.replaceAll(with: recordings)

        // A real, playable file for the detail screen.
        let url = library.audioDirectory.appendingPathComponent("\(detailRecordingID).m4a")
        writeTone(to: url, seconds: 84)
        library.update(detailRecordingID) { $0.byteCount = AudioFileInspector.byteCount(of: url) ?? 0 }
    }

    private static func clock(_ date: Date, plus seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date.addingTimeInterval(TimeInterval(seconds)))
    }

    private static func heading(_ start: Date, minutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.dateFormat = "EEE yyyy-MM-dd"
        return "# \(formatter.string(from: start)) – \(formatter.string(from: start.addingTimeInterval(TimeInterval(minutes * 60)))) (\(day.string(from: start)))"
    }

    private static func ideaTranscript(_ start: Date) -> String {
        """
        \(heading(start, minutes: 2))

        [\(clock(start, plus: 1)) · mic] Okay, quick idea before I forget it. The inbox triage view should sort by who is waiting on me, not by when the message arrived.

        [\(clock(start, plus: 19)) · mic] Anything where I'm the blocker floats to the top, with how long they've been waiting in plain numbers. Two days, four hours. No colors, just the number.

        [\(clock(start, plus: 41)) · mic] And the second part: one keystroke to snooze until a specific person replies. That's the thing I actually want every Monday.

        [\(clock(start, plus: 66)) · mic] Write this up for Thursday's review. Ask Ana whether the data model already tracks who is waiting.
        """
    }

    private static func standupTranscript(_ start: Date) -> String {
        """
        \(heading(start, minutes: 15))

        [\(clock(start, plus: 4)) · mic] Morning. Yesterday I finished the export job; it's running on staging now.

        [\(clock(start, plus: 31)) · mic] Today I'm pairing with Jonas on the sync retries, and I'll look at the flaky upload test.

        [\(clock(start, plus: 58)) · mic] No blockers, but I need a review on the migration PR before lunch.
        """
    }

    private static func reviewTranscript(_ start: Date) -> String {
        """
        \(heading(start, minutes: 15))

        [\(clock(start, plus: 12)) · mic] Let's start with the recorder screen. The timer is the first thing anyone looks at, so it stays big and monospaced.

        [\(clock(start, plus: 47)) · mic] Agreed. The level meter should be data, not decoration — real input levels, newest on the right.
        """
    }

    private static func lunchTranscript(_ start: Date) -> String {
        """
        \(heading(start, minutes: 15))

        [\(clock(start, plus: 20)) · mic] Today's topic is local-first software: what it means to own your data, and what it costs to build.
        """
    }

    /// One finished 20 s recording in whatever library is open.
    @MainActor
    static func seedSampleRecording(into library: LibraryStore) {
        let id = UUID().uuidString
        let start = Date()
        let (fileName, url) = library.newAudioFile(id: id)
        writeTone(to: url, seconds: 20)
        library.insert(Recording(
            id: id, title: RecordingTitle.makeDefault(startedAt: start, existing: library.titles),
            startedAt: start, duration: AudioFileInspector.duration(of: url) ?? 20, fileName: fileName,
            byteCount: AudioFileInspector.byteCount(of: url) ?? 0, inputName: "Sample tone",
            capture: .complete))
    }

    /// Copy an existing audio file into the real library as a finished
    /// recording (simulator end-to-end tests with real speech).
    @MainActor
    static func seedAudioFile(_ source: URL, into library: LibraryStore) {
        let id = UUID().uuidString
        let start = Date()
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let (fileName, url) = library.newAudioFile(id: id, fileExtension: ext)
        guard (try? FileManager.default.copyItem(at: source, to: url)) != nil else { return }
        library.insert(Recording(
            id: id, title: source.deletingPathExtension().lastPathComponent,
            startedAt: start, duration: AudioFileInspector.duration(of: url) ?? 0, fileName: fileName,
            byteCount: AudioFileInspector.byteCount(of: url) ?? 0, inputName: "Seeded file",
            capture: .complete))
    }

    /// 84 s of a soft two-tone hum, AAC in .m4a — enough for the player.
    static func writeTone(to url: URL, seconds: Double) {
        let sampleRate = 48_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let frames = AVAudioFrameCount(sampleRate)
        var phase = 0.0
        for second in 0..<Int(seconds) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = frames
            let frequency = second % 4 < 2 ? 220.0 : 277.2
            for index in 0..<Int(frames) {
                phase += 2 * .pi * frequency / sampleRate
                channel[index] = Float(sin(phase) * 0.08)
            }
            try? file.write(from: buffer)
        }
    }
}

extension SyncManager {
    /// Freezes sync and fakes a believable state for screenshots.
    func applyDemoState(paired: Bool, uploading: Activity) {
        isFrozenForDemo = true
        guard paired else { return }
        setDemoState(reachable: true, activity: uploading, lastSyncAt: Date().addingTimeInterval(-120),
                     engineAvailable: true)
    }
}
#endif
