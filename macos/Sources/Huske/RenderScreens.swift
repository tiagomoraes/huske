// Hidden dev utility: `Huske --render-screens <dir>` renders the main screens
// offscreen to PNGs (no window server interaction) and exits. Used to verify
// the UI headlessly and to produce documentation screenshots.

import AppKit
import HuskeKit
import SwiftUI

@MainActor
enum ScreenRenderer {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--render-screens"),
              args.count > flagIndex + 1
        else { return false }
        let outDir = URL(fileURLWithPath: args[flagIndex + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        render(into: outDir)
        return true
    }

    private static func render(into outDir: URL) {
        let model = AppModel()
        let demo = DemoSession(controller: model.session)
        demo.start()
        // Advance the demo a few ticks synchronously via direct ingestion.
        let now = Date()
        model.session.ingest(
            message: .state(
                ControlSnapshot(
                    sessionId: "20260721T093000_demo",
                    recording: true,
                    paused: false,
                    stopping: false,
                    currentChunkSeq: 3,
                    queueDepth: 1,
                    screenshotsEnabled: true,
                    distillEnabled: false,
                    lastSavedName: "093012_demo0000_002.md",
                    peakMicDb: -21.4,
                    peakSystemDb: -33.8,
                    chunkStartedAt: now.addingTimeInterval(-312),
                    nextRotationAt: now.addingTimeInterval(1488),
                    sessionStartedAt: now.addingTimeInterval(-1520),
                    huskeVersion: "0.10.0",
                    outputRoot: NSHomeDirectory() + "/huske/transcripts",
                    lastSavedPath: nil,
                    screenshotsCount: 12,
                    inputDeviceName: "MacBook Pro Microphone",
                    warnings: [:],
                    events: [
                        SessionEvent(
                            rawTimestamp: "2026-07-21T09:31:00-03:00", severity: .info,
                            message: "chunk 001 queued for transcription"),
                        SessionEvent(
                            rawTimestamp: "2026-07-21T09:31:20-03:00", severity: .info,
                            message: "chunk 001 → 093012_demo0000_001.md"),
                        SessionEvent(
                            rawTimestamp: "2026-07-21T09:36:05-03:00", severity: .warn,
                            message: "distillation unavailable: daemon not reachable"),
                    ]
                )))

        let screens: [(String, AnyView)] = [
            ("record-active", AnyView(RecordView())),
            ("record-idle", AnyView(IdleView())),
            ("onboarding", AnyView(OnboardingView())),
            ("doctor", AnyView(DoctorView())),
            ("config", AnyView(ConfigView())),
        ]
        for (name, view) in screens {
            let framed = view
                .environment(model)
                .frame(width: 860, height: 640)
                .background(Theme.bg)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2.0
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("render failed: \(name)\n".utf8))
                continue
            }
            let url = outDir.appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("wrote \(url.path)")
        }
        demo.stop()
    }
}
