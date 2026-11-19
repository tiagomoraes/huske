// AVAudioPlayer wrapper for the detail screen: play/pause, ±15 s, scrubbing.
//
// Loading is split in two: `load` only measures the file (off the main
// thread); the AVAudioPlayer — which prepares audio hardware — is created on
// the first Play. Preparing it while the detail screen is being pushed
// stalls the navigation transition.

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlayerModel {
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isAvailable = true
    var isScrubbing = false

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let delegate = PlayerDelegate()

    init() {
        delegate.onFinish = { [weak self] in
            Task { @MainActor in self?.didFinish() }
        }
    }

    func load(url: URL, fallbackDuration: TimeInterval) async {
        guard self.url != url else { return }
        stop()
        player = nil
        self.url = url
        duration = fallbackDuration
        currentTime = 0
        let measured = await Task.detached(priority: .userInitiated) {
            AudioFileInspector.duration(of: url)
        }.value
        guard self.url == url else { return }
        if let measured {
            duration = measured
            isAvailable = true
        } else {
            isAvailable = false
        }
    }

    /// `recordingActive`: a recording owns the audio session; leave its
    /// category alone (the UI disables playback then anyway).
    func togglePlay(recordingActive: Bool = false) {
        isPlaying ? pause() : play(recordingActive: recordingActive)
    }

    func play(recordingActive: Bool = false) {
        guard let player = preparedPlayer() else { return }
        if !recordingActive {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
        player.currentTime = currentTime
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTicker()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), duration)
        currentTime = clamped
        player?.currentTime = clamped
    }

    private func preparedPlayer() -> AVAudioPlayer? {
        if let player { return player }
        guard let url, let created = try? AVAudioPlayer(contentsOf: url) else {
            isAvailable = false
            return nil
        }
        created.delegate = delegate
        created.prepareToPlay()
        if created.duration > 0 { duration = created.duration }
        player = created
        return created
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, !self.isScrubbing else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func didFinish() {
        isPlaying = false
        stopTicker()
        currentTime = 0
        player?.currentTime = 0
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
