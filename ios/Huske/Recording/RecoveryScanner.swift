// Runs at launch, before any new recording can start: resolves library
// entries still marked `.inProgress` (the app died while recording).
//
// AVAudioRecorder writes the .m4a index (moov atom) when it stops, so a file
// cut short by a crash is usually unreadable. We never pretend otherwise:
// a readable file is finalized with its real duration and a note; an
// unreadable one is marked damaged (kept, so the user decides to delete it).

import AVFoundation
import Foundation

enum AudioFileInspector {
    /// Playable duration in seconds, or nil if the file can't be decoded.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }

    static func byteCount(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

@MainActor
enum RecoveryScanner {
    struct Outcome: Equatable {
        var recovered: [String] = []
        var damaged: [String] = []
    }

    @discardableResult
    static func reconcile(_ library: LibraryStore,
                          inspectDuration: (URL) -> TimeInterval? = AudioFileInspector.duration(of:)) -> Outcome {
        var outcome = Outcome()
        for recording in library.recordings where recording.capture == .inProgress {
            let url = library.audioURL(for: recording)
            let bytes = AudioFileInspector.byteCount(of: url) ?? 0
            if let duration = inspectDuration(url) {
                library.update(recording.id) {
                    $0.capture = .complete
                    $0.duration = duration
                    $0.byteCount = bytes
                    $0.note = "Saved after Huske closed unexpectedly while recording."
                }
                outcome.recovered.append(recording.id)
            } else {
                library.update(recording.id) {
                    $0.capture = .damaged
                    $0.byteCount = bytes
                    $0.note = bytes > 0
                        ? "Huske closed unexpectedly while recording and this audio couldn't be recovered."
                        : "Huske closed unexpectedly before any audio was saved."
                }
                outcome.damaged.append(recording.id)
            }
        }
        return outcome
    }
}
