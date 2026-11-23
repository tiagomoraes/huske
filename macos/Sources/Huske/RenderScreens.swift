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
        // `scripts/smoke-launch.sh` checks this line: a packaged app that
        // can't find its resource bundle renders with system fonts instead.
        print("brand fonts registered: \(BrandFonts.registered)")
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
        seedCleanedTranscript()
        let transcriptsModel = makeTranscriptsModel()
        transcriptsModel.pane = .transcripts
        screens.append(("root-transcripts", AnyView(RootView().environment(transcriptsModel))))
        // A cleaned-up transcript with its original showing: the way back to
        // what the transcriber actually heard.
        let originalModel = makeTranscriptsModel()
        originalModel.pane = .transcripts
        screens.append(
            ("root-transcripts-original",
             AnyView(RootView().environment(originalModel).environment(\.transcriptPreviewShowsOriginal, true))))
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
        for (suffix, githubModel) in makeGitHubSyncModels() {
            githubModel.pane = .connect
            screens.append(("root-cloud-sync-\(suffix)", AnyView(RootView().environment(githubModel))))
        }
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
        // The whole Configuration pane, tall enough that nothing is cut: the
        // dictionary and transcript cleanup in the states that matter —
        // Apple Intelligence ready, a cloud provider waiting for consent, and
        // one still waiting for its key.
        for (name, fixture) in [
            ("config-cleanup-apple", CleanupFixture.appleReady),
            ("config-cleanup-cloud-consent", CleanupFixture.cloudAwaitingConsent),
            ("config-cleanup-cloud-key", CleanupFixture.cloudNeedsKey),
        ] {
            let cleanupModel = makeCleanupConfigModel(fixture)
            cleanupModel.pane = .configuration
            sized.append((name, AnyView(RootView().environment(cleanupModel)), CGSize(width: 1080, height: 2440)))
        }
        // Transcription models (`huske models`): the Model row on the
        // Configuration pane, and the picker sheet — one model in use, one
        // downloading, two that don't transcribe the configured language, a
        // Try result — plus an ad-hoc repo in use with a refused entry.
        let modelsConfig = makeCleanupConfigModel(.modelCatalog)
        modelsConfig.pane = .configuration
        sized.append(("config-models", AnyView(RootView().environment(modelsConfig)), CGSize(width: 1080, height: 2440)))
        sized.append(
            ("models-sheet", AnyView(ModelPickerSheet().environment(makeModelsSheetModel(adhoc: false))),
             CGSize(width: 680, height: 1640)))
        sized.append(
            ("models-sheet-adhoc", AnyView(ModelPickerSheet().environment(makeModelsSheetModel(adhoc: true))),
             CGSize(width: 680, height: 1660)))
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
            distillEnabled: true,
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
                    rawTimestamp: "2026-07-21T09:36:05-03:00", severity: .info,
                    message: "chunk 002 cleaned up with Apple Intelligence"),
            ],
            distillLabel: "Apple Intelligence"
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

    /// Connect GitHub, step by step: not connected → code → choose a
    /// repository → publishing.
    private static func makeGitHubSyncModels() -> [(String, AppModel)] {
        func status(connected: Bool, repository: String?) -> GitHubSyncStatus {
            GitHubSyncStatus(
                auth: repository == nil ? "git" : "github-app", connected: connected,
                login: connected ? "you" : nil, repository: repository,
                remote: repository.map { "https://github.com/\($0).git" },
                syncEnabled: repository != nil,
                installUrl: "https://github.com/apps/huske-sync/installations/new",
                newRepositoryUrl: "https://github.com/new?name=huske-transcripts&visibility=private")
        }
        func model(remote: String?) -> AppModel {
            let model = makeIdleModel()
            var file = #""input_device": "MacBook Pro Microphone""#
            if let remote {
                file += #", "sync_enabled": true, "sync_auth": "github-app", "sync_remote": "\#(remote)""#
            }
            let json = #"{"path": "/tmp/config.toml", "exists": true, "file": {\#(file)}, "effective": {\#(file)}}"#
            if let snapshot = try? ConfigBridge.parseShowJSON(json) {
                model.config._previewInject(snapshot: snapshot)
            }
            return model
        }

        let connect = model(remote: nil)
        connect.github._previewInject(status: status(connected: false, repository: nil))

        let code = model(remote: nil)
        code.github._previewInject(
            status: status(connected: false, repository: nil),
            login: .waiting(
                GitHubDeviceCode(
                    userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device",
                    expiresIn: 900)))

        let choose = model(remote: nil)
        choose.github._previewInject(
            status: status(connected: true, repository: nil),
            shared: GitHubSharedRepositories(
                installed: true, repositorySelection: "all",
                repositories: [
                    GitHubRepository(fullName: "you/huske-transcripts", isPrivate: true),
                    GitHubRepository(fullName: "you/website", isPrivate: false),
                ],
                installUrl: "https://github.com/apps/huske-sync/installations/new",
                installationSettingsUrl: "https://github.com/settings/installations/1",
                newRepositoryUrl: "https://github.com/new?name=huske-transcripts&visibility=private",
                current: nil))

        let publishing = model(remote: "https://github.com/you/huske-transcripts.git")
        publishing.github._previewInject(
            status: status(connected: true, repository: "you/huske-transcripts"))

        return [("connect", connect), ("code", code), ("choose", choose), ("publishing", publishing)]
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

    // MARK: transcript cleanup fixtures

    enum CleanupFixture {
        case appleReady, cloudAwaitingConsent, cloudNeedsKey
        /// Apple Intelligence cleanup on an engine with `huske models`,
        /// Whisper large-v3 turbo chosen from the catalog.
        case modelCatalog
    }

    /// The engine's real provider table (`huske llm status --json`).
    private static let providersJSON = """
        [{"name": "mlx", "label": "Built-in model", "placement": "on_device", "needs_key": false,
          "default_model": "mlx-community/Qwen3.5-0.8B-4bit", "default_endpoint": null},
         {"name": "apple", "label": "Apple Intelligence", "placement": "on_device", "needs_key": false,
          "default_model": "apple-on-device", "default_endpoint": null},
         {"name": "ollama", "label": "Ollama", "placement": "local", "needs_key": false,
          "default_model": "qwen3.5:0.8b", "default_endpoint": "http://127.0.0.1:11434"},
         {"name": "openai_compatible", "label": "OpenAI-compatible server", "placement": "local",
          "needs_key": false, "default_model": null, "default_endpoint": "http://127.0.0.1:1234/v1"},
         {"name": "openai", "label": "OpenAI", "placement": "cloud", "needs_key": true,
          "default_model": null, "default_endpoint": "https://api.openai.com/v1"},
         {"name": "anthropic", "label": "Anthropic", "placement": "cloud", "needs_key": true,
          "default_model": "claude-haiku-5-5", "default_endpoint": "https://api.anthropic.com/v1"},
         {"name": "openrouter", "label": "OpenRouter", "placement": "cloud", "needs_key": true,
          "default_model": null, "default_endpoint": "https://openrouter.ai/api/v1"}]
        """

    private static let appleJSON = """
        {"available": true, "reason": null, "detail": "Apple Intelligence is ready on this Mac.",
         "hint": null, "context_size": 8192, "helper": "/Applications/Huske.app/Contents/Helpers/huske-apple-llm"}
        """

    private static func makeCleanupConfigModel(_ fixture: CleanupFixture) -> AppModel {
        let model = AppModel()
        model._previewInject(
            capabilities: EngineCapabilities(
                version: "0.15.0", controlSocket: true, configCLI: true, devicesCLI: true,
                inboxCLI: true, llmCLI: true, languagesCLI: true,
                modelsCLI: fixture == .modelCatalog),
            binary: URL(fileURLWithPath: "/opt/homebrew/bin/huske"),
            version: "0.15.0",
            candidates: [
                EngineCandidate(
                    url: URL(fileURLWithPath: "/opt/homebrew/bin/huske"),
                    version: EngineVersion("0.15.0"), origin: "/opt/homebrew/bin")
            ])
        let home = NSHomeDirectory()
        let engine: String
        let cleanupKeys: String
        let fileKeys: String
        let statusJSON: String
        var models: LLMModelList?
        var test: LLMTestResult?
        switch fixture {
        case .appleReady:
            engine = #""asr_engine": "parakeet", "language": "pt", "parakeet_word_boost": false"#
            cleanupKeys = #""distill_enabled": true, "distill_backend": "apple", "distill_instructions": """#
            fileKeys = #""distill_enabled": true, "distill_backend": "apple", "language": "pt", "vocabulary": [], "vocabulary_replacements": {}"#
            statusJSON = """
                {"enabled": true, "backend": "apple", "label": "Apple Intelligence",
                 "placement": "on_device", "leaves_mac": false, "host": null, "endpoint": null,
                 "model": "apple-on-device", "consent": true, "key_required": false,
                 "key_accepted": false, "key_present": false, "ready": true, "reason": "ready",
                 "detail": "Apple Intelligence is ready (8,192-token context)", "hint": null,
                 "context_tokens": 8192,
                 "keys": {"openai_compatible": false, "openai": false, "anthropic": false, "openrouter": false},
                 "apple": \(appleJSON), "providers": \(providersJSON)}
                """
            var sample = LLMTestResult()
            sample.ok = true
            sample.label = "apple:apple-on-device"
            sample.input = [
                "good morning everyone today we'll review the cube ernetes deploy and the okrs for the quarter",
                "sounds good i'll post the dash board link in slack after the meeting",
            ]
            sample.output = [
                "Good morning, everyone. Today we'll review the Kubernetes deploy and the OKRs for the quarter.",
                "Sounds good. I'll post the dashboard link in Slack after the meeting.",
            ]
            sample.changed = 2
            sample.seconds = 1.6
            test = sample
        case .cloudAwaitingConsent:
            engine = #""asr_engine": "whisper", "model": "large-v3-turbo", "language": "pt", "parakeet_word_boost": false"#
            cleanupKeys = #""distill_enabled": true, "distill_backend": "anthropic", "distill_instructions": "Remove filler words. Keep Portuguese and English as spoken.""#
            fileKeys = #""distill_enabled": true, "distill_backend": "anthropic", "asr_engine": "whisper", "model": "large-v3-turbo", "language": "pt", "vocabulary": [], "distill_instructions": """#
            statusJSON = """
                {"enabled": true, "backend": "anthropic", "label": "Anthropic", "placement": "cloud",
                 "leaves_mac": true, "host": "api.anthropic.com",
                 "endpoint": "https://api.anthropic.com/v1", "model": "claude-haiku-5-5",
                 "consent": false, "key_required": true, "key_accepted": true, "key_present": true,
                 "ready": false, "reason": "needs_consent",
                 "detail": "sending transcripts to api.anthropic.com hasn't been allowed",
                 "hint": "Allow it in Huske.app → Configuration, or run `huske llm allow-cloud`.",
                 "context_tokens": 32000,
                 "keys": {"openai_compatible": false, "openai": false, "anthropic": true, "openrouter": false},
                 "apple": \(appleJSON), "providers": \(providersJSON)}
                """
            models = LLMModelList(
                backend: "anthropic",
                models: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        case .cloudNeedsKey:
            engine = #""asr_engine": "parakeet", "language": "", "parakeet_word_boost": true"#
            cleanupKeys = #""distill_enabled": false, "distill_backend": "openai", "distill_instructions": """#
            fileKeys = #""distill_backend": "openai", "parakeet_word_boost": true, "vocabulary": []"#
            statusJSON = """
                {"enabled": false, "backend": "openai", "label": "OpenAI", "placement": "cloud",
                 "leaves_mac": true, "host": "api.openai.com", "endpoint": "https://api.openai.com/v1",
                 "model": null, "consent": false, "key_required": true, "key_accepted": true,
                 "key_present": false, "ready": false, "reason": "needs_key",
                 "detail": "no OpenAI API key in the Keychain",
                 "hint": "Add it in Huske.app → Configuration, or run `huske llm key set openai`.",
                 "context_tokens": 32000,
                 "keys": {"openai_compatible": false, "openai": false, "anthropic": false, "openrouter": false},
                 "apple": \(appleJSON), "providers": \(providersJSON)}
                """
            models = LLMModelList(
                backend: "openai",
                error: "add an API key for OpenAI first (`huske llm key set openai`)")
        case .modelCatalog:
            engine = #""asr_model": "whisper-large-v3-turbo", "asr_engine": "whisper", "model": "large-v3-turbo", "language": "pt", "parakeet_word_boost": false"#
            cleanupKeys = #""distill_enabled": true, "distill_backend": "apple", "distill_instructions": """#
            fileKeys = #""asr_model": "whisper-large-v3-turbo", "asr_engine": "whisper", "language": "pt", "distill_enabled": true, "distill_backend": "apple", "vocabulary": [], "vocabulary_replacements": {}"#
            statusJSON = """
                {"enabled": true, "backend": "apple", "label": "Apple Intelligence",
                 "placement": "on_device", "leaves_mac": false, "host": null, "endpoint": null,
                 "model": "apple-on-device", "consent": true, "key_required": false,
                 "key_accepted": false, "key_present": false, "ready": true, "reason": "ready",
                 "detail": "Apple Intelligence is ready (8,192-token context)", "hint": null,
                 "context_tokens": 8192,
                 "keys": {"openai_compatible": false, "openai": false, "anthropic": false, "openrouter": false},
                 "apple": \(appleJSON), "providers": \(providersJSON)}
                """
        }
        let vocabulary = #""vocabulary": ["Kubernetes", "OKR", "Huske", "Marta Ribeiro"], "vocabulary_replacements": {"cube ernetes": "Kubernetes", "okay are": "OKR"}"#
        let json = """
            {"path": "\(home)/.config/huske/config.toml", "exists": true,
             "file": {\(fileKeys)},
             "effective": {\(engine), \(cleanupKeys), \(vocabulary),
                           "parakeet_model": "mlx-community/parakeet-tdt-0.6b-v3",
                           "whisper_idle_unload": true, "speech_gated": true,
                           "silence_split_seconds": 60.0, "chunk_minutes": 15.0,
                           "input_device": "MacBook Pro Microphone",
                           "system_audio_backend": "auto", "echo_cancel": true,
                           "capture_sync": true, "echo_dedup": "drop",
                           "output_root": "\(home)/huske/transcripts",
                           "audio_root": "\(home)/huske/audio",
                           "keep_audio": false, "keep_audio_format": "opus",
                           "screenshots_enabled": false, "screenshots_interval_seconds": 60.0,
                           "distill_model": null, "distill_endpoint": null,
                           "menu_bar_enabled": true}}
            """
        if let snapshot = try? ConfigBridge.parseShowJSON(json) {
            model.config._previewInject(snapshot: snapshot)
        } else {
            FileHandle.standardError.write(Data("bad config fixture: \(fixture)\n".utf8))
        }
        do {
            model.cleanup._previewInject(
                status: try LLMBridge.parseStatus(statusJSON), models: models, test: test)
        } catch {
            FileHandle.standardError.write(Data("bad status fixture: \(fixture)\n".utf8))
        }
        if fixture == .modelCatalog, let catalog = modelCatalogFixture() {
            model.models._previewInject(catalog: catalog)
        }
        return model
    }

    // MARK: transcription model fixtures

    /// `huske models --json` from a real run (Portuguese configured), with
    /// Whisper large-v3 turbo in use and a mix of models on disk.
    private static let catalogModelsJSON = """
        [{"id": "parakeet-tdt-0.6b-v3", "name": "Parakeet v3", "family": "parakeet", "family_label": "Parakeet", "repo": "mlx-community/parakeet-tdt-0.6b-v3", "label": "parakeet:tdt-0.6b-v3", "summary": "Fast and quiet on silence; 25 European languages, recognised automatically.", "note": "Can't be told the language: mixed Portuguese and English can slip into English.", "languages": ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"], "language_count": 25, "pins_language": false, "dictionary": "boost", "size_mb": 2508, "speed": "fastest", "accuracy": "very good", "measured": "51x real time on an M3 Pro; 5 of 10 jargon terms right in Portuguese, 9 in English", "default": true, "recommended": true, "in_catalog": true, "downloaded": true, "in_use": false, "runtime_available": true},
         {"id": "whisper-large-v3-turbo", "name": "Whisper large-v3 turbo", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-large-v3-turbo", "label": "mlx-whisper:large-v3-turbo", "summary": "Locks the language you choose and spells jargon well; the pick for mixed-language meetings.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 1614, "speed": "fast", "accuracy": "very good", "measured": "24x real time on an M3 Pro; 7 of 10 jargon terms right in Portuguese, 10 in English", "default": false, "recommended": true, "in_catalog": true, "downloaded": true, "in_use": true, "runtime_available": true},
         {"id": "whisper-large-v3-turbo-q4", "name": "Whisper large-v3 turbo, compact", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-large-v3-turbo-q4", "label": "mlx-whisper:large-v3-turbo-q4", "summary": "Same accuracy as turbo in a third of the memory (4-bit), slightly slower.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 464, "speed": "fast", "accuracy": "very good", "measured": "20x real time on an M3 Pro; 7 of 10 jargon terms right in Portuguese", "default": false, "recommended": false, "in_catalog": true, "downloaded": true, "in_use": false, "runtime_available": true},
         {"id": "whisper-large-v3", "name": "Whisper large-v3", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-large-v3-mlx", "label": "mlx-whisper:large-v3", "summary": "The most accurate, and the slowest and heaviest.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 3084, "speed": "slow", "accuracy": "best", "measured": "8x real time on an M3 Pro; 9 of 10 jargon terms right in Portuguese", "default": false, "recommended": false, "in_catalog": true, "downloaded": false, "in_use": false, "runtime_available": true},
         {"id": "whisper-medium", "name": "Whisper medium", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-medium-mlx", "label": "mlx-whisper:medium", "summary": "Older middle ground; turbo is faster and more accurate.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 1525, "speed": "moderate", "accuracy": "good", "measured": null, "default": false, "recommended": false, "in_catalog": true, "downloaded": false, "in_use": false, "runtime_available": true},
         {"id": "whisper-small", "name": "Whisper small", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-small-mlx", "label": "mlx-whisper:small", "summary": "Light and quick; misses more names and jargon.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 481, "speed": "fast", "accuracy": "good", "measured": "34x real time on an M3 Pro; 3 of 10 jargon terms right in Portuguese", "default": false, "recommended": false, "in_catalog": true, "downloaded": true, "in_use": false, "runtime_available": true},
         {"id": "whisper-small-q4", "name": "Whisper small, compact", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-small-mlx-q4", "label": "mlx-whisper:small-mlx-q4", "summary": "The smallest useful Whisper (4-bit): quick, but rough on jargon.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 197, "speed": "fastest", "accuracy": "good", "measured": "46x real time on an M3 Pro; 3 of 10 jargon terms right in Portuguese", "default": false, "recommended": false, "in_catalog": true, "downloaded": false, "in_use": false, "runtime_available": true},
         {"id": "whisper-base", "name": "Whisper base", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-base-mlx", "label": "mlx-whisper:base", "summary": "Tiny download for quick tests; not for real meetings.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 144, "speed": "fastest", "accuracy": "basic", "measured": null, "default": false, "recommended": false, "in_catalog": true, "downloaded": false, "in_use": false, "runtime_available": true},
         {"id": "whisper-tiny", "name": "Whisper tiny", "family": "whisper", "family_label": "Whisper", "repo": "mlx-community/whisper-tiny-mlx", "label": "mlx-whisper:tiny", "summary": "The smallest Whisper; for trying Huske out, not for keeping.", "note": "", "languages": null, "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": 74, "speed": "fastest", "accuracy": "basic", "measured": null, "default": false, "recommended": false, "in_catalog": true, "downloaded": false, "in_use": false, "runtime_available": true},
         {"id": "parakeet-tdt-0.6b-v2", "name": "Parakeet v2, English", "family": "parakeet", "family_label": "Parakeet", "repo": "mlx-community/parakeet-tdt-0.6b-v2", "label": "parakeet:tdt-0.6b-v2", "summary": "English only; the previous Parakeet, still excellent for English.", "note": "English only.", "languages": ["en"], "language_count": 1, "pins_language": false, "dictionary": "boost", "size_mb": 2472, "speed": "fastest", "accuracy": "very good", "measured": null, "default": false, "recommended": false, "in_catalog": true, "downloaded": false, "in_use": false, "runtime_available": true},
         {"id": "parakeet-tdt_ctc-110m", "name": "Parakeet 110M, English", "family": "parakeet", "family_label": "Parakeet", "repo": "mlx-community/parakeet-tdt_ctc-110m", "label": "parakeet:tdt_ctc-110m", "summary": "English only and very light: the fastest model here.", "note": "English only.", "languages": ["en"], "language_count": 1, "pins_language": false, "dictionary": "boost", "size_mb": 459, "speed": "fastest", "accuracy": "good", "measured": "81x real time on an M3 Pro; 6 of 10 jargon terms right in English", "default": false, "recommended": false, "in_catalog": true, "downloaded": true, "in_use": false, "runtime_available": true}]
        """
    private static let catalogFamiliesJSON = """
        [{"name": "parakeet", "label": "Parakeet", "pins_language": false, "dictionary": "boost", "available": true}, {"name": "whisper", "label": "Whisper", "pins_language": true, "dictionary": "prompt", "available": true}]
        """

    private static func modelCatalogFixture() -> ModelCatalog? {
        let json = #"{"current": null, "models": "# + catalogModelsJSON + #", "families": "#
            + catalogFamiliesJSON + "}"
        do {
            return try ModelsBridge.parseCatalog(json)
        } catch {
            FileHandle.standardError.write(Data("bad model catalog fixture: \(error)\n".utf8))
            return nil
        }
    }

    private static func makeModelsSheetModel(adhoc: Bool) -> AppModel {
        let model = makeCleanupConfigModel(.modelCatalog)
        guard var catalog = modelCatalogFixture() else { return model }
        if adhoc {
            // A repo typed into "Another model": listed first, facts unknown.
            catalog.models = catalog.models.map {
                var row = $0
                row.inUse = false
                return row
            }
            let custom = TranscriptionModel(
                id: "someone/whisper-large-v4-mlx", name: "large-v4",
                family: "whisper", familyLabel: "Whisper",
                repo: "someone/whisper-large-v4-mlx",
                label: "mlx-whisper:large-v4", languageCount: 100, pinsLanguage: true,
                dictionary: "prompt", inCatalog: false, downloaded: false, inUse: true)
            catalog.models.insert(custom, at: 0)
            catalog.current = custom
            model.models._previewInject(
                catalog: catalog, customDraft: "nvidia/canary-1b-flash",
                customError: "Huske can't tell which engine runs 'nvidia/canary-1b-flash' (it knows: "
                    + "parakeet, whisper). Repos are matched by name, folders by their config.json.")
            return model
        }
        var sample = ModelTryResult()
        sample.ok = true
        sample.audioSeconds = 10.4
        sample.loadSeconds = 2.8
        sample.seconds = 0.53
        sample.xRealtime = 19.6
        sample.language = "pt"
        sample.text = "Bom dia, pessoal. Hoje a gente vai revisar o planejamento do trimestre, conferir "
            + "os números da última semana e combinar os próximos passos com o time."
        model.models._previewInject(
            catalog: catalog,
            downloads: ["whisper-medium": .init(bytes: 640_500_000, total: 1_525_000_000)],
            tries: ["whisper-large-v3-turbo-q4": sample])
        // Recording right now: the sheet says the choice waits for the next one.
        model.session.setPhaseForDemo(.active(attached: false))
        model.session.ingest(message: .state(demoSnapshot(now: Date())))
        return model
    }

    /// The newest transcript in the transcripts fixture, cleaned up with
    /// Apple Intelligence, and the raw ASR output beside it. Synthetic text.
    private static func seedCleanedTranscript() {
        let dir = "/tmp/huske-preview/2026-07-21/"
        let front = """
            ---
            session_id: 20260721T093000_8a3f2c19
            chunk_seq: 3
            date: 2026-07-21
            start_time: 2026-07-21T10:12:10-03:00
            end_time: 2026-07-21T10:26:10-03:00
            duration_seconds: 840
            duration_actual_seconds: 840.0
            gap_seconds: 0.0
            audio_sources:
              - microphone
              - system
            model: parakeet:tdt-0.6b-v3
            language: en
            incomplete: false
            huske_version: 0.15.0
            """
        let cleaned = front + """

            postprocessed_by: apple:apple-on-device
            postprocessed_at: 2026-07-21T10:26:31-03:00
            raw_transcript: 101210_8a3f2c19_003.asr.txt
            ---

            # 10:12 – 10:26 (Tue 2026-07-21)

            [10:12:10 · system] So the decision is to ship the mobile build on Friday and keep the retention review for next week.

            [10:12:24 · mic] Agreed. I'll move the Kubernetes upgrade to Monday so it doesn't collide with the release.

            [10:12:41 · system] Can you post the OKR dashboard link in Slack after the call?

            [10:12:50 · mic] Sure, right after. And I'll ask Marta to review the pricing page.
            """
        let raw = front + """

            ---

            # 10:12 – 10:26 (Tue 2026-07-21)

            [10:12:10 · system] so the decision is to ship the mobile build on friday and keep the retention review for next week

            [10:12:24 · mic] agreed i'll move the cube ernetes upgrade to monday so it doesn't collide with the release

            [10:12:41 · system] can you post the okay are dash board link in slack after the call

            [10:12:50 · mic] sure right after and i'll ask marta to review the pricing page
            """
        TranscriptDetailView.previewDocuments[dir + "101210_8a3f2c19_003.md"] = TranscriptParser.parse(cleaned)
        TranscriptDetailView.previewDocuments[dir + "101210_8a3f2c19_003.asr.txt"] = TranscriptParser.parse(raw)
    }
}
