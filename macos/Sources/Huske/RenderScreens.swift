// Hidden dev utility: `Huske --render-screens <dir>` renders the main screens
// offscreen to PNGs (no window server interaction) and exits. Used to verify
// the UI headlessly and to produce documentation screenshots.
//
// Caveat: ImageRenderer skips AppKit-backed controls (toggles, pickers,
// progress views render as placeholders) — everything custom-drawn is
// faithful.

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
        let model = makeActiveModel()
        let idleModel = makeIdleModel()

        var screens: [(String, AnyView)] = [
            ("root-record-active", AnyView(RootView().environment(model))),
            ("root-record-idle", AnyView(RootView().environment(idleModel))),
            ("onboarding", AnyView(OnboardingView().environment(idleModel))),
            ("engine-outdated", AnyView(EngineOutdatedView().environment(makeOutdatedModel()))),
        ]
        let transcriptsModel = makeTranscriptsModel()
        transcriptsModel.pane = .transcripts
        screens.append(("root-transcripts", AnyView(RootView().environment(transcriptsModel))))
        let doctorModel = makeDoctorModel()
        doctorModel.pane = .doctor
        screens.append(("root-doctor", AnyView(RootView().environment(doctorModel))))
        let configModel = makeConfigModel()
        configModel.pane = .configuration
        screens.append(("root-config", AnyView(RootView().environment(configModel))))
        let paletteModel = makeActiveModel()
        paletteModel.paletteVisible = true
        screens.append(("root-palette", AnyView(RootView().environment(paletteModel))))

        for (name, view) in screens {
            for dark in [false, true] {
                NSApplication.shared.appearance = NSAppearance(
                    named: dark ? .darkAqua : .aqua)
                let framed = view
                    .tint(Theme.amber)
                    .environment(\.screenRendering, true)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: 1080, height: 720)
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
                let url = outDir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                try? png.write(to: url)
                print("wrote \(url.path)")
            }
        }
        NSApplication.shared.appearance = nil
    }

    // MARK: model fixtures

    private static func demoSnapshot(now: Date) -> ControlSnapshot {
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
            huskeVersion: "0.11.0",
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
        )
    }

    private static func makeActiveModel() -> AppModel {
        let model = AppModel()
        model.session.setPhaseForDemo(.active(attached: false))
        model.session.ingest(message: .state(demoSnapshot(now: Date())))
        model.session.ingest(
            message: .devices(
                DeviceList(
                    devices: [
                        InputDeviceEntry(index: 1, name: "MacBook Pro Microphone", channels: 1, sampleRate: 48000)
                    ],
                    currentIndex: 1)))
        return model
    }

    private static func makeIdleModel() -> AppModel {
        let model = AppModel()
        model._previewInject(
            capabilities: EngineCapabilities(
                version: "0.11.0", controlSocket: true, configCLI: true, devicesCLI: true))
        return model
    }

    private static func makeOutdatedModel() -> AppModel {
        let model = AppModel()
        model._previewInject(
            capabilities: EngineCapabilities(
                version: "0.10.0", controlSocket: false, configCLI: false, devicesCLI: false))
        return model
    }

    private static func makeTranscriptsModel() -> AppModel {
        let model = makeIdleModel()
        func entry(_ day: String, _ time: String, _ seq: Int, _ sid: String) -> TranscriptEntry {
            let name = "\(time)_\(sid)_\(String(format: "%03d", seq)).md"
            return TranscriptEntry(
                url: URL(fileURLWithPath: "/tmp/huske-preview/\(day)/\(name)"),
                filename: name,
                timeString: "\(time.prefix(2)):\(time.dropFirst(2).prefix(2)):\(time.suffix(2))",
                sessionId8: sid,
                chunkSeq: seq
            )
        }
        model.transcripts._previewInject(
            root: URL(fileURLWithPath: "/tmp/huske-preview"),
            days: [
                TranscriptDay(
                    date: "2026-07-21",
                    entries: [
                        entry("2026-07-21", "091500", 1, "8a3f2c19"),
                        entry("2026-07-21", "093000", 2, "8a3f2c19"),
                        entry("2026-07-21", "101210", 3, "8a3f2c19"),
                    ]),
                TranscriptDay(
                    date: "2026-07-18",
                    entries: [
                        entry("2026-07-18", "084500", 1, "b71e0440"),
                        entry("2026-07-18", "112000", 2, "b71e0440"),
                    ]),
            ]
        )
        return model
    }

    private static func makeDoctorModel() -> AppModel {
        let model = makeIdleModel()
        model._previewInject(
            doctor: DoctorReport(
                version: "0.11.0",
                ok: true,
                checks: [
                    DoctorCheck(name: "Python", ok: true, detail: "3.13.2", hint: nil),
                    DoctorCheck(name: "huske version", ok: true, detail: "0.11.0", hint: nil),
                    DoctorCheck(name: "parakeet-mlx", ok: true, detail: "0.5.2", hint: nil),
                    DoctorCheck(
                        name: "microphone", ok: true,
                        detail: "'MacBook Pro Microphone' (1ch, 48000 Hz)", hint: nil),
                    DoctorCheck(name: "mic sample", ok: true, detail: "peak -36.4 dB (audible)", hint: nil),
                    DoctorCheck(name: "system audio", ok: true, detail: "Core Audio process tap usable", hint: nil),
                    DoctorCheck(
                        name: "search index", ok: false,
                        detail: "index unreadable: model mismatch",
                        hint: "Run `huske index --rebuild`."),
                ],
                inputDevices: [
                    InputDeviceEntry(index: 1, name: "MacBook Pro Microphone", channels: 1, sampleRate: 48000),
                    InputDeviceEntry(index: 3, name: "ZoomAudioDevice", channels: 2, sampleRate: 48000),
                ]
            ))
        return model
    }

    private static func makeConfigModel() -> AppModel {
        let model = makeIdleModel()
        let json = """
            {"path": "\(NSHomeDirectory())/.config/huske/config.toml", "exists": true,
             "file": {"input_device": "MacBook Pro Microphone", "chunk_minutes": 30.0},
             "effective": {"asr_engine": "parakeet",
                           "parakeet_model": "mlx-community/parakeet-tdt-0.6b-v3",
                           "language": "", "whisper_idle_unload": true,
                           "speech_gated": true, "silence_split_seconds": 60.0,
                           "chunk_minutes": 30.0,
                           "input_device": "MacBook Pro Microphone",
                           "system_audio_backend": "auto", "echo_cancel": true,
                           "echo_dedup": "drop",
                           "output_root": "\(NSHomeDirectory())/huske/transcripts",
                           "audio_root": "\(NSHomeDirectory())/huske/audio",
                           "keep_audio": false, "keep_audio_format": "opus",
                           "screenshots_enabled": false,
                           "screenshots_interval_seconds": 60.0,
                           "indexing_enabled": true, "distill_enabled": false,
                           "distill_model": "qwen3.5:0.8b", "menu_bar_enabled": true}}
            """
        if let snapshot = try? ConfigBridge.parseShowJSON(json) {
            model.config._previewInject(snapshot: snapshot)
        }
        return model
    }
}
