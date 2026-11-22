import XCTest

@testable import HuskeKit

/// Cross-language contract test: drives the *real* Python ControlServer
/// (huske/ipc/server.py) with the Swift client. Gated on the
/// HUSKE_INTEROP_PYTHON environment variable (path to a python with huske
/// importable) so plain `swift test` stays hermetic:
///
///   HUSKE_INTEROP_PYTHON=../.venv/bin/python swift test --filter PythonInterop
final class PythonInteropTests: XCTestCase {
    private static let serverScript = """
        import sys, time
        from pathlib import Path
        from huske.control import Command, CommandChannel
        from huske.ipc.protocol import ControlSnapshot
        from huske.ipc.server import ControlServer

        sock = Path(sys.argv[1])
        channel = CommandChannel()
        server = ControlServer(sock, channel)
        server.start()
        snap = ControlSnapshot(
            session_id="interop", recording=True, paused=False, stopping=False,
            current_chunk_seq=7, queue_depth=1, screenshots_enabled=False,
            distill_enabled=False, last_saved_name=None,
            peak_mic_db=-25.0, peak_system_db=-40.0,
            chunk_started_at="2026-07-21T09:00:00.123456-03:00",
            session_started_at="2026-07-21T08:59:00-03:00",
            huske_version="interop", output_root="/tmp",
            input_device_name="Interop Mic",
            warnings={"heartbeat": "test warning"},
            events=[{"ts": "2026-07-21T09:00:01-03:00", "severity": "info",
                     "message": "hello from python"}],
            distill_label="Apple Intelligence",
        )
        got = None
        deadline = time.time() + 20
        while time.time() < deadline and got is None:
            server.broadcast_state(snap)
            for cmd, arg in channel.drain():
                got = (cmd, arg)
            time.sleep(0.05)
        server.stop()
        ok = got == (Command.SET_INPUT_DEVICE, "Interop Mic 2")
        print("RESULT", "ok" if ok else got, flush=True)
        sys.exit(0 if ok else 1)
        """

    func testSwiftClientAgainstRealPythonServer() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let socketPath = "/tmp/hsk-interop-\(UInt32.random(in: 0..<UInt32.max)).sock"
        defer { unlink(socketPath) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = ["-c", Self.serverScript, socketPath]
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        defer { if server.isRunning { server.terminate() } }

        // Poll-connect while the server binds its socket.
        let client = LineSocketClient(path: socketPath)
        let snapshotReceived = expectation(description: "v2 snapshot decoded")
        nonisolated(unsafe) var receivedOnce = false
        client.onMessage = { message in
            guard case .state(let snap) = message, !receivedOnce else { return }
            receivedOnce = true
            XCTAssertEqual(snap.sessionId, "interop")
            XCTAssertEqual(snap.currentChunkSeq, 7)
            XCTAssertEqual(snap.peakMicDb, -25.0, accuracy: 0.001)
            XCTAssertEqual(snap.inputDeviceName, "Interop Mic")
            XCTAssertEqual(snap.warnings["heartbeat"], "test warning")
            XCTAssertEqual(snap.events.first?.message, "hello from python")
            XCTAssertNotNil(snap.chunkStartedAt) // microsecond fraction parses
            XCTAssertEqual(snap.distillLabel, "Apple Intelligence")
            snapshotReceived.fulfill()
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? client.connect()) != nil { break }
            usleep(100_000)
        }
        XCTAssertTrue(client.isConnected, "could not connect to the python server")

        wait(for: [snapshotReceived], timeout: 10)

        // Command with an argument must arrive typed on the Python side.
        client.send(.setInputDevice, arg: "Interop Mic 2")
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus, 0, "python server did not receive the command")
        client.close()
    }

    /// Cloud sync is configured through the engine-owned config contract. Drive
    /// the real CLI and decode it through the same bridge as the app.
    func testSyncConfigJSONDecodesWithTheSwiftBridge() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "huske", "config", "show", "--json", "--config", "/nonexistent.toml"]
        var env = ProcessInfo.processInfo.environment
        env["HUSKE_NO_UPDATE_CHECK"] = "1"
        // Isolate from the developer's real ~/.config/huske and ~/huske.
        env["HOME"] = home.path
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        let snapshot = try ConfigBridge.parseShowJSON(text)
        XCTAssertEqual(snapshot.bool("sync_enabled"), false)
        XCTAssertEqual(snapshot.string("sync_provider"), "git")
        XCTAssertEqual(snapshot.string("sync_branch"), "main")
        XCTAssertNil(snapshot.string("sync_remote"))
    }

    /// Transcript cleanup is configured through `huske llm` and `huske
    /// languages`. Drive the real CLI — isolated from the developer's config,
    /// Keychain and installed Huske.app — and decode it with the app's bridge.
    func testCleanupJSONDecodesWithTheSwiftBridge() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-llm-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var env = ProcessInfo.processInfo.environment
        env["HUSKE_NO_UPDATE_CHECK"] = "1"
        env["HOME"] = home.path
        // A keychain file that does not exist: every lookup says "no key".
        env["HUSKE_KEYCHAIN"] = home.appendingPathComponent("none.keychain-db").path
        env["HUSKE_APPLE_LLM_HELPER"] = home.appendingPathComponent("no-helper").path

        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "huske"] + arguments
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }

        let config = home.appendingPathComponent("config.toml").path
        let status = try LLMBridge.parseStatus(
            try run(["llm", "status", "--json", "--config", config]))
        XCTAssertEqual(status.backend, "mlx")
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.leavesMac)
        XCTAssertTrue(status.consent)
        XCTAssertFalse(status.detail.isEmpty)
        XCTAssertEqual(
            Set(status.keys.keys), ["openai", "anthropic", "openrouter", "openai_compatible"])
        XCTAssertFalse(status.keys.values.contains(true))
        XCTAssertEqual(status.apple?.available, false)
        XCTAssertFalse(status.apple?.detail.isEmpty ?? true)
        let names = status.providers.map(\.name)
        for name in ["apple", "mlx", "ollama", "openai_compatible", "openai", "anthropic", "openrouter"] {
            XCTAssertTrue(names.contains(name), "engine no longer offers \(name)")
        }
        XCTAssertEqual(status.provider(named: "anthropic")?.placement, .cloud)
        XCTAssertEqual(status.provider(named: "anthropic")?.needsKey, true)
        XCTAssertEqual(status.provider(named: "apple")?.placement, .onDevice)

        let cloud = try LLMBridge.parseStatus(
            try run(["llm", "status", "--json", "--config", config, "--backend", "openai"]))
        XCTAssertEqual(cloud.backend, "openai")
        XCTAssertTrue(cloud.leavesMac)
        XCTAssertEqual(cloud.host, "api.openai.com")
        XCTAssertEqual(cloud.reason, "needs_key")

        let models = try LLMBridge.parseModels(
            try run(["llm", "models", "--json", "--config", config, "--backend", "mlx"]))
        XCTAssertNil(models.error)
        XCTAssertFalse(models.models.isEmpty)

        let languages = try LLMBridge.parseLanguages(try run(["languages", "--json"]))
        XCTAssertGreaterThanOrEqual(languages.count, 25)
        XCTAssertEqual(languages.first { $0.code == "pt" }?.parakeetSupported, true)
        XCTAssertEqual(languages.first { $0.code == "ja" }?.parakeetSupported, false)
        // The app's fallback list must agree with the engine's.
        XCTAssertEqual(
            Set(languages.filter(\.parakeetSupported).map(\.code)), LanguageInfo.parakeetCodes)
    }

    /// The transcription-model catalog: drive the real `huske models` with an
    /// isolated HOME (no config, no model cache of the developer's) and decode
    /// every answer the Configuration pane reads. Nothing is downloaded.
    func testModelsJSONDecodesWithTheSwiftBridge() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-models-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var env = ProcessInfo.processInfo.environment
        env["HUSKE_NO_UPDATE_CHECK"] = "1"
        env["HOME"] = home.path
        // An empty Hugging Face cache: "downloaded" is false everywhere.
        env["HF_HOME"] = home.appendingPathComponent("hf").path
        env["HF_HUB_OFFLINE"] = "1"

        func run(_ arguments: [String]) throws -> (status: Int32, stdout: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "huske"] + arguments
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }

        let catalog = try ModelsBridge.parseCatalog(
            try run(["models", "--json", "--config", "/nonexistent.toml"]).stdout)
        XCTAssertGreaterThanOrEqual(catalog.models.count, 2)
        XCTAssertEqual(Set(catalog.models.map(\.id)).count, catalog.models.count, "ids are unique")
        for family in ["parakeet", "whisper"] {
            XCTAssertTrue(catalog.families.contains { $0.name == family }, "engine lost \(family)")
        }
        XCTAssertEqual(catalog.families.first { $0.name == "whisper" }?.pinsLanguage, true)
        let current = try XCTUnwrap(catalog.current, "the default config picks a model")
        XCTAssertTrue(current.inUse)
        XCTAssertTrue(current.isDefault)
        XCTAssertEqual(catalog.models.filter(\.inUse).map(\.id), [current.id])
        XCTAssertTrue(catalog.models.contains { $0.recommended })
        XCTAssertNotNil(catalog.languageLockingChoice)
        for model in catalog.models {
            XCTAssertTrue(model.inCatalog, "\(model.id)")
            XCTAssertFalse(model.downloaded, "\(model.id): the isolated cache is empty")
            XCTAssertFalse(model.name.isEmpty, "\(model.id)")
            XCTAssertFalse(model.summary.isEmpty, "\(model.id)")
            XCTAssertNotNil(model.sizeMB, "\(model.id)")
            XCTAssertTrue(["prompt", "boost", "none"].contains(model.dictionary), "\(model.id)")
            XCTAssertNotNil(ModelWords.speedAndAccuracy(model), "\(model.id) is rated")
            if model.pinsLanguage {
                XCTAssertNil(model.languages, "\(model.id): pinning models take any language")
            }
        }
        // The `list` subcommand answers the same.
        let listed = try ModelsBridge.parseCatalog(
            try run(["models", "list", "--json", "--config", "/nonexistent.toml"]).stdout)
        XCTAssertEqual(listed.models.map(\.id), catalog.models.map(\.id))

        let tiny = try ModelsBridge.parseModel(
            try run(["models", "info", "whisper-tiny", "--json", "--config", "/nonexistent.toml"]).stdout)
        XCTAssertEqual(tiny.family, "whisper")
        XCTAssertTrue(tiny.pinsLanguage)
        XCTAssertEqual(tiny.dictionary, "prompt")

        // Choosing writes the config through the engine; a refusal is JSON.
        // CI's interpreter has no MLX runtimes (the contract job installs no
        // ML packages), and the engine rightly refuses a model whose runtime
        // is missing — so check whichever answer this interpreter gives.
        let config = home.appendingPathComponent("config.toml").path
        let whisperInstalled = catalog.families.first { $0.name == "whisper" }?.available ?? false
        let usedRun = try run(["models", "use", "whisper-tiny", "--json", "--config", config])
        let used = try ModelsBridge.parseUse(usedRun.stdout)
        let after = try ModelsBridge.parseCatalog(try run(["models", "--json", "--config", config]).stdout)
        if whisperInstalled {
            XCTAssertNil(used.error)
            XCTAssertEqual(used.model?.id, "whisper-tiny")
            XCTAssertEqual(used.model?.inUse, true)
            XCTAssertEqual(used.written["asr_model"], .string("whisper-tiny"))
            XCTAssertEqual(after.current?.id, "whisper-tiny")
        } else {
            XCTAssertEqual(usedRun.status, 2)
            XCTAssertTrue(used.error?.contains("mlx-whisper") ?? false, "\(String(describing: used.error))")
            XCTAssertNil(used.model)
            XCTAssertEqual(after.current?.id, current.id, "a refused choice leaves the config alone")
        }

        let refused = try run(["models", "use", "foo/bar", "--json", "--config", config])
        XCTAssertEqual(refused.status, 2)
        let refusal = try ModelsBridge.parseUse(refused.stdout)
        XCTAssertNil(refusal.model)
        XCTAssertFalse(refusal.error?.isEmpty ?? true)

        let unknown = try run(["models", "download", "nope", "--json", "--config", config])
        XCTAssertNotEqual(unknown.status, 0)
        let event = unknown.stdout.split(separator: "\n").compactMap {
            ModelsBridge.parseDownloadLine(String($0))
        }.last
        guard case .failed(let message)? = event else {
            return XCTFail("expected a refusal, got \(String(describing: event))")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// Cloud sync's GitHub sign-in is rendered from `huske sync status --json`.
    /// Decode the real CLI's output with the app's parser.
    func testSyncStatusJSONDecodesWithTheSwiftParser() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-github-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "huske", "sync", "status", "--json", "--config", "/nonexistent.toml"]
        var env = ProcessInfo.processInfo.environment
        env["HUSKE_NO_UPDATE_CHECK"] = "1"
        env["HOME"] = home.path
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let events = GitHubSyncEvent.parseAll(String(data: data, encoding: .utf8) ?? "")
        switch events.last {
        case .status(let status)?:
            XCTAssertEqual(status.auth, "git")
            XCTAssertNil(status.repository)
            XCTAssertTrue(status.installUrl.hasPrefix("https://github.com/apps/"))
        case .error?:
            // A runner without a usable login keychain still has to speak
            // the same contract: an error event the app can show.
            break
        default:
            XCTFail("unparseable `huske sync status --json` output: \(events)")
        }
    }
}
