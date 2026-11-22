// Composition root: owns the library, recorder, Live Activity and sync
// manager, plus app-level navigation and the pairing flow.

import Foundation
import HuskeSync
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let library: LibraryStore
    let liveActivity: LiveActivityController
    let recorder: RecorderController
    let sync: SyncManager

    // MARK: navigation

    var path: [String] = []
    var showingMac = false

    // MARK: pairing flow

    enum PairingState: Equatable {
        case idle
        case working
        /// Saved, but the Mac wasn't reached yet (message says what to do).
        case finished(String)
    }

    /// A pairing link waiting for the user's "Pair" (from Camera, scanner, paste).
    var pendingInvite: PairingInvite?
    var pairingState: PairingState = .idle
    /// Why the last link/paste didn't work.
    var pairingMessage: String?
    /// Shown once on the Mac screen right after pairing succeeds.
    var pairingSuccessMessage: String?

    #if DEBUG
    let demo = DemoMode.current
    #endif

    private init() {
        #if DEBUG
        let demo = DemoMode.current
        let rootDirectory = demo.isEnabled ? DemoMode.resetDirectory() : LibraryStore.defaultRootDirectory()
        #else
        let rootDirectory = LibraryStore.defaultRootDirectory()
        #endif

        let library = LibraryStore(rootDirectory: rootDirectory)
        RecoveryScanner.reconcile(library)
        let liveActivity = LiveActivityController()
        let recorder = RecorderController(library: library, liveActivity: liveActivity)

        #if DEBUG
        let sync: SyncManager
        if demo.isEnabled {
            DemoData.seed(into: library)
            sync = SyncManager(
                library: library,
                pairingStore: InMemoryPairingStore(demo.paired ? DemoData.pairedMac : nil),
                defaults: DemoMode.defaults,
                defaultDeviceName: "iPhone",
                makeConnector: { _, _ in DemoData.UnreachableConnector() },
                makePresence: { _ in nil })
            sync.applyDemoState(paired: demo.paired, uploading: DemoData.uploadingState)
        } else {
            sync = SyncManager(library: library, pairingStore: KeychainPairingStore(),
                               defaultDeviceName: DeviceInfo.systemName)
        }
        #else
        let sync = SyncManager(library: library, pairingStore: KeychainPairingStore(),
                               defaultDeviceName: DeviceInfo.systemName)
        #endif

        self.library = library
        self.liveActivity = liveActivity
        self.recorder = recorder
        self.sync = sync

        recorder.onRecordingSaved = { [weak sync] id in sync?.recordingSaved(id) }
        RecordingCommandCenter.register { [weak recorder] command in
            await recorder?.handle(command) ?? .unavailable
        }
        // Activities from a previous run (killed while recording) are stale.
        Task { await liveActivity.endStale(keeping: nil) }

        #if DEBUG
        applyDemoRoute(demo)
        #endif
    }

    // MARK: URLs

    func handle(url: URL) {
        guard PairingLink.isPairingURL(url) else { return }
        receive(PairingLink.parse(url: url))
    }

    /// From the QR scanner or a paste.
    func receivePairingText(_ text: String) {
        receive(PairingLink.parse(text: text))
    }

    func pastePairingLink() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            pairingMessage = "The clipboard is empty. On your Mac, click Copy Link in Huske's Pair iPhone screen, then try again."
            return
        }
        receivePairingText(text)
    }

    private func receive(_ outcome: PairingLink.Outcome) {
        switch outcome {
        case let .invite(invite):
            pairingMessage = nil
            pairingSuccessMessage = nil
            pairingState = .idle
            pendingInvite = invite
            path.removeAll()
            showingMac = true
            #if DEBUG
            if demo.autoConfirmPairing {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    self.confirmPairing()
                }
            }
            #endif
        case .invalid, .expired, .notPairingLink:
            pairingMessage = PairingLink.message(for: outcome)
            showingMac = true
        }
    }

    func confirmPairing() {
        guard let invite = pendingInvite, pairingState != .working else { return }
        pairingState = .working
        Task { @MainActor in
            let result = await sync.pair(with: invite)
            switch result {
            case .paired:
                pendingInvite = nil
                pairingState = .idle
                pairingSuccessMessage = "Paired with \(invite.macName). New recordings sync automatically."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case let .savedButNotReached(message):
                pairingState = .finished(
                    "\(message) Pairing completes the first time this iPhone reaches your Mac — within 10 minutes of making the code.")
            case let .failed(message):
                pairingState = .finished(message)
            }
        }
    }

    func cancelPairing() {
        pendingInvite = nil
        pairingState = .idle
    }

    func finishPairingFlow() {
        pendingInvite = nil
        pairingState = .idle
    }

    func forgetMac() {
        sync.forgetMac()
        pairingSuccessMessage = nil
    }

    // MARK: debug routes

    #if DEBUG
    private func applyDemoRoute(_ demo: DemoMode) {
        // Navigate after the first frame, as a tap would.
        let route = demo.route
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            switch route {
            case "detail": self.path = [DemoData.detailRecordingID]
            case "latest": self.path = self.library.recordings.first.map { [$0.id] } ?? []
            case "mac": self.showingMac = true
            default: break
            }
        }
        if let file = demo.seedAudioFile {
            DemoData.seedAudioFile(file, into: library)
        }
        if demo.seedSample {
            DemoData.seedSampleRecording(into: library)
        }
        if let url = demo.openURL {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                self.handle(url: url)
            }
        }
        if demo.simulatedRecording {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.recorder.startDemoSession(title: "Supplier call — follow-up", alreadyElapsed: 754)
            }
        }
        if demo.autoRecord {
            let stopAfter = demo.autoStopAfter
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await self.recorder.start()
                if let stopAfter, stopAfter > 0 {
                    try? await Task.sleep(for: .seconds(stopAfter))
                    self.recorder.stop()
                }
            }
        }
    }
    #endif
}
