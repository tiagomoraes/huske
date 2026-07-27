// Scripted fake session for developing and screenshotting the app without a
// running engine (no microphone, no models). Activated with the
// HUSKE_APP_DEMO=1 environment variable — see AppModel in the app target.

import Foundation

@MainActor
public final class DemoSession {
    private let controller: SessionController
    private var task: Task<Void, Never>?
    private var tick = 0
    private let startedAt = Date()

    public init(controller: SessionController) {
        self.controller = controller
    }

    public func start() {
        controller.setPhaseForDemo(.active(attached: false))
        controller.ingest(
            message: .devices(
                DeviceList(
                    devices: [
                        InputDeviceEntry(index: 1, name: "MacBook Pro Microphone", channels: 1, sampleRate: 48000),
                        InputDeviceEntry(index: 3, name: "AirPods Pro", channels: 1, sampleRate: 24000),
                    ],
                    currentIndex: 1
                )))
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.emit()
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        controller.setPhaseForDemo(.idle)
    }

    private func emit() {
        tick += 1
        let t = Double(tick) / 8.0
        // Speech-like envelope: talk bursts with pauses.
        let talking = sin(t * 0.7) > -0.2
        let micDb = talking ? -28.0 + 10.0 * sin(t * 5.3) + 4.0 * sin(t * 13.7) : -62.0
        let sysDb = talking ? -34.0 + 8.0 * sin(t * 4.1 + 1.2) : -70.0
        let chunk = 1 + tick / 480
        let events: [SessionEvent] = [
            SessionEvent(
                rawTimestamp: ISO8601DateFormatter().string(from: startedAt),
                severity: .info,
                message: "chunk 001 queued for transcription"),
            SessionEvent(
                rawTimestamp: ISO8601DateFormatter().string(from: startedAt.addingTimeInterval(9)),
                severity: .info,
                message: "chunk 001 → 093012_demo0000_001.md"),
        ]
        let snapshot = ControlSnapshot(
            sessionId: "20260721T093000_demo",
            recording: true,
            paused: false,
            stopping: false,
            currentChunkSeq: chunk,
            queueDepth: tick % 97 < 8 ? 1 : 0,
            screenshotsEnabled: false,
            distillEnabled: false,
            lastSavedName: tick > 80 ? "093012_demo0000_001.md" : nil,
            peakMicDb: micDb,
            peakSystemDb: sysDb,
            chunkStartedAt: startedAt,
            nextRotationAt: startedAt.addingTimeInterval(1800),
            sessionStartedAt: startedAt,
            huskeVersion: "demo",
            outputRoot: NSHomeDirectory() + "/huske/transcripts",
            lastSavedPath: nil,
            screenshotsCount: 0,
            inputDeviceName: "MacBook Pro Microphone",
            warnings: [:],
            events: tick > 80 ? events : Array(events.prefix(1))
        )
        controller.ingest(message: .state(snapshot))
    }
}
