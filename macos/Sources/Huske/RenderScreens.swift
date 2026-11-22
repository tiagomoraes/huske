// Hidden dev utility: `Huske --render-screens <dir>` renders the main screens
// offscreen to PNGs (no window server interaction) and exits. Used to verify
// the UI headlessly and to produce documentation screenshots.
//
// Caveat: ImageRenderer skips AppKit-backed controls (toggles, pickers,
// progress views render as placeholders) — everything custom-drawn is
// faithful.

import AppKit
import HuskeKit
import HuskeSync
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
            ("engine-unusable", AnyView(EngineUnusableView().environment(makeUnusableModel()))),
        ]
        let transcriptsModel = makeTranscriptsModel()
        transcriptsModel.pane = .transcripts
        screens.append(("root-transcripts", AnyView(RootView().environment(transcriptsModel))))
        // The transport dock is the reason this one exists: recording state and
        // its controls must be present on a pane that isn't Record.
        let recordingElsewhere = makeTranscriptsModel()
        recordingElsewhere.pane = .transcripts
        recordingElsewhere.session.setPhaseForDemo(.active(attached: false))
        recordingElsewhere.session.ingest(message: .state(demoSnapshot(now: Date())))
        screens.append(
            ("root-transcripts-recording", AnyView(RootView().environment(recordingElsewhere))))
        let pausedElsewhere = makeTranscriptsModel()
        pausedElsewhere.pane = .transcripts
        pausedElsewhere.session.setPhaseForDemo(.active(attached: false))
        var paused = demoSnapshot(now: Date())
        paused.paused = true
        pausedElsewhere.session.ingest(message: .state(paused))
        screens.append(
            ("root-transcripts-paused", AnyView(RootView().environment(pausedElsewhere))))
        let doctorModel = makeDoctorModel()
        doctorModel.pane = .doctor
        screens.append(("root-doctor", AnyView(RootView().environment(doctorModel))))
        let configModel = makeConfigModel()
        configModel.pane = .configuration
        screens.append(("root-config", AnyView(RootView().environment(configModel))))
        // Cloud sync owns the whole ADR 0009 publish story, so it stays under
        // the same headless design review as every other pane.
        let syncModel = makeConfigModel()
        syncModel.pane = .connect
        screens.append(("root-cloud-sync", AnyView(RootView().environment(syncModel))))
        let paletteModel = makeActiveModel()
        paletteModel.paletteVisible = true
        screens.append(("root-palette", AnyView(RootView().environment(paletteModel))))
        // iPhone sync (specs/002-phone-sync): the pane with paired phones and
        // recordings in every state, plus the pairing sheet before and after
        // the phone connects.
        let phoneModel = makePhoneModel()
        phoneModel.pane = .phone
        let emptyPhoneModel = makeIdleModel()
        emptyPhoneModel.pane = .phone
        // An engine from before the inbox existed: the pane must say so.
        emptyPhoneModel._previewInject(
            capabilities: EngineCapabilities(
                version: "0.13.0", controlSocket: true, configCLI: true, devicesCLI: true),
            binary: URL(fileURLWithPath: "/opt/homebrew/bin/huske"), version: "0.13.0")
        emptyPhoneModel.phoneSync._previewInject(devices: [], recordings: [], listening: true)
        screens.append(("root-iphone-empty", AnyView(RootView().environment(emptyPhoneModel))))

        var sized: [(String, AnyView, CGSize)] = screens.map { ($0.0, $0.1, CGSize(width: 1080, height: 720)) }
        // Taller canvas: the static render cannot scroll, and every state
        // row should stay under review.
        sized.append(("root-iphone", AnyView(RootView().environment(phoneModel)), CGSize(width: 1080, height: 940)))
        let invite = PairingInvite.mint(
            macID: "8C1F0E52-7A41-4E0B-9E7C-2D5B6F3A9C10", macName: "MacBook Pro de Tiago")
        let pairingModel = makePhoneModel()
        pairingModel.phoneSync._previewInject(invite: invite)
        sized.append(("pair-sheet", AnyView(PairPhoneSheet().environment(pairingModel)), CGSize(width: 430, height: 525)))
        let pairedModel = makePhoneModel()
        pairedModel.phoneSync._previewInject(invite: invite, paired: phoneFixtureDevices()[0])
        sized.append(("pair-sheet-paired", AnyView(PairPhoneSheet().environment(pairedModel)), CGSize(width: 430, height: 525)))

        for (name, view, size) in sized {
            for dark in [false, true] {
                NSApplication.shared.appearance = NSAppearance(
                    named: dark ? .darkAqua : .aqua)
                let framed = view
                    .tint(Theme.amber)
                    .environment(\.screenRendering, true)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: size.width, height: size.height)
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
                version: "0.10.0", controlSocket: false, configCLI: false, devicesCLI: false),
            binary: URL(
                fileURLWithPath: NSHomeDirectory() + "/.local/share/uv/tools/huske/bin/huske"),
            version: "0.10.0")
        return model
    }

    /// The pinned-checkout failure this screen was written for: a console
    /// script whose virtualenv was rebuilt, with two healthy engines sitting
    /// beside it. Kept under the headless design review because it is the
    /// screen a developer machine hits most often.
    private static func makeUnusableModel() -> AppModel {
        let model = AppModel()
        model._previewInject(
            capabilities: EngineCapabilities(
                version: nil, controlSocket: false, configCLI: false, devicesCLI: false,
                failure: "Its interpreter is gone — "
                    + NSHomeDirectory() + "/code/huske/.venv/bin/python no longer exists, "
                    + "so the virtualenv behind this binary was deleted or rebuilt."),
            binary: URL(fileURLWithPath: NSHomeDirectory() + "/code/huske/.venv/bin/huske"),
            candidates: [
                EngineCandidate(
                    url: URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/huske"),
                    version: EngineVersion("0.14.0"),
                    origin: NSHomeDirectory() + "/.local/bin"),
                EngineCandidate(
                    url: URL(fileURLWithPath: "/opt/homebrew/bin/huske"),
                    version: EngineVersion("0.13.0"), origin: "/opt/homebrew/bin"),
            ])
        return model
    }

    private static func phoneFixtureDevices() -> [PairedDevice] {
        let now = Date()
        return [
            PairedDevice(
                deviceID: "5B0F7E4C-1111-4C67-9C0B-3C8F3A1B2D11", key: Data(count: 32),
                name: "iPhone de Tiago", model: "iPhone17,1",
                createdAt: now.addingTimeInterval(-86_400 * 12),
                pairedAt: now.addingTimeInterval(-86_400 * 12),
                lastSeenAt: now.addingTimeInterval(-240)),
            PairedDevice(
                deviceID: "9A2C44D0-2222-4C67-9C0B-3C8F3A1B2D11", key: Data(count: 32),
                name: "Work iPhone", model: "iPhone16,2",
                createdAt: now.addingTimeInterval(-86_400 * 40),
                pairedAt: now.addingTimeInterval(-86_400 * 40),
                lastSeenAt: now.addingTimeInterval(-86_400 * 3)),
        ]
    }

    private static func makePhoneModel() -> AppModel {
        let model = AppModel()
        model._previewInject(
            capabilities: EngineCapabilities(
                version: "0.14.0", controlSocket: true, configCLI: true, devicesCLI: true,
                inboxCLI: true),
            binary: URL(fileURLWithPath: "/opt/homebrew/bin/huske"),
            version: "0.14.0")
        let now = Date()
        typealias Recording = PhoneSyncCoordinator.Recording
        model.phoneSync._previewInject(
            devices: phoneFixtureDevices(),
            recordings: [
                Recording(
                    id: "r5", title: "Voice memo — groceries", deviceName: "iPhone de Tiago",
                    startedAt: now.addingTimeInterval(-300), durationSeconds: 94,
                    byteCount: 760_000, state: .receiving, progress: 0.42),
                Recording(
                    id: "r4", title: "Reunião com a Ana", deviceName: "iPhone de Tiago",
                    startedAt: now.addingTimeInterval(-3_600), durationSeconds: 1_834.5,
                    byteCount: 14_801_234, state: .transcribing, progress: 0.66,
                    detail: "Transcribing part 2 of 3"),
                Recording(
                    id: "r3", title: "Standup", deviceName: "Work iPhone",
                    startedAt: now.addingTimeInterval(-7_200), durationSeconds: 912,
                    byteCount: 7_300_000, state: .queued, detail: "Waiting for the transcriber"),
                Recording(
                    id: "r2", title: "1:1 with Marta", deviceName: "Work iPhone",
                    startedAt: now.addingTimeInterval(-86_400), durationSeconds: 2_710,
                    byteCount: 21_000_000, state: .transcribed, progress: 1,
                    detail: "2 transcript chunks",
                    transcripts: ["/tmp/huske-preview/2026-11-18/101500_9a2c44d0_001.md"]),
                Recording(
                    id: "r1", title: "Lecture — week 9", deviceName: "iPhone de Tiago",
                    startedAt: now.addingTimeInterval(-86_400 * 2), durationSeconds: 5_400,
                    byteCount: 43_000_000, state: .failed,
                    detail: "afconvert could not decode audio.m4a (unsupported codec)"),
            ],
            listening: true)
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
        let glances: [(String, String, Int, String, [String])] = [
            ("2026-07-21/101210_8a3f2c19_003.md", "So the decision is to ship the mobile build on Friday and keep the retention review for next week.", 840, "", ["microphone", "system"]),
            ("2026-07-21/093000_8a3f2c19_002.md", "Bom dia a todos, obrigado por entrarem na chamada. Hoje vamos rever o planeamento do trimestre.", 900, "", ["microphone", "system"]),
            ("2026-07-21/091500_8a3f2c19_001.md", "Okay, quick idea before I forget it: the inbox should sort by who is waiting on me.", 312, "phone", ["microphone"]),
            ("2026-07-18/112000_b71e0440_002.md", "The second part is pricing. We said three tiers, but I think two is cleaner for launch.", 600, "", ["microphone", "system"]),
            ("2026-07-18/084500_b71e0440_001.md", "Morning. Yesterday I finished the export job; it's running on staging now.", 180, "", ["microphone"]),
        ]
        for (path, text, seconds, origin, sources) in glances {
            TranscriptGlances.previewSeeds["/tmp/huske-preview/" + path] = TranscriptGlance(
                excerpt: text, durationSeconds: seconds, audioSources: sources,
                origin: origin.isEmpty ? nil : origin)
        }
        model.transcripts._previewInject(
            root: URL(fileURLWithPath: "/tmp/huske-preview"),
            days: [
                TranscriptDay(
                    date: "2026-07-21",
                    entries: [
                        entry("2026-07-21", "101210", 3, "8a3f2c19"),
                        entry("2026-07-21", "093000", 2, "8a3f2c19"),
                        entry("2026-07-21", "091500", 1, "8a3f2c19"),
                    ]),
                TranscriptDay(
                    date: "2026-07-18",
                    entries: [
                        entry("2026-07-18", "112000", 2, "b71e0440"),
                        entry("2026-07-18", "084500", 1, "b71e0440"),
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
                        name: "sync repository", ok: true,
                        detail: "configured; credentials are managed by Git",
                        hint: nil),
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
             "file": {"input_device": "MacBook Pro Microphone", "chunk_minutes": 15.0,
                      "sync_enabled": true,
                      "sync_remote": "git@github.com:you/huske-transcripts.git",
                      "sync_branch": "main"},
             "effective": {"asr_engine": "parakeet",
                           "parakeet_model": "mlx-community/parakeet-tdt-0.6b-v3",
                           "language": "", "whisper_idle_unload": true,
                           "speech_gated": true, "silence_split_seconds": 60.0,
                           "chunk_minutes": 15.0,
                           "input_device": "MacBook Pro Microphone",
                           "system_audio_backend": "auto", "echo_cancel": true,
                           "echo_dedup": "drop",
                           "output_root": "\(NSHomeDirectory())/huske/transcripts",
                           "audio_root": "\(NSHomeDirectory())/huske/audio",
                           "keep_audio": false, "keep_audio_format": "opus",
                           "screenshots_enabled": false,
                           "screenshots_interval_seconds": 60.0,
                           "sync_enabled": true, "sync_provider": "git",
                           "sync_remote": "git@github.com:you/huske-transcripts.git",
                           "sync_branch": "main", "distill_enabled": false,
                           "distill_model": "qwen3.5:0.8b", "menu_bar_enabled": true}}
            """
        if let snapshot = try? ConfigBridge.parseShowJSON(json) {
            model.config._previewInject(snapshot: snapshot)
        }
        // Two engines installed — the state that used to be invisible. Renders
        // the "Also installed, not in use" line so it stays under design review.
        model._previewInject(
            binary: URL(fileURLWithPath: "/opt/homebrew/bin/huske"),
            version: "0.11.0",
            candidates: [
                EngineCandidate(
                    url: URL(fileURLWithPath: "/opt/homebrew/bin/huske"),
                    version: EngineVersion("0.11.0"), origin: "/opt/homebrew/bin"),
                EngineCandidate(
                    url: URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/huske"),
                    version: EngineVersion("0.10.0"), origin: "~/.local/bin"),
            ])
        return model
    }
}
