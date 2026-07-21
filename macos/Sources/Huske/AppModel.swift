// Top-level app state: engine binary resolution, engine config, the live
// session, transcripts, doctor, recovery. One instance, injected via
// SwiftUI's environment.

import Foundation
import HuskeKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let binaryOverrideKey = "huskeBinaryPath"

    // MARK: engine binary

    private(set) var binaryURL: URL?
    private(set) var binaryVersion: String?
    var binaryMissing: Bool { binaryURL == nil && !isDemo }

    // MARK: subsystems

    let session = SessionController()
    let transcripts = TranscriptStore()
    let config = ConfigStore()

    // MARK: doctor

    private(set) var doctorReport: DoctorReport?
    private(set) var doctorError: String?
    private(set) var doctorRunning = false

    // MARK: recover

    private(set) var recoverLog: [String] = []
    private(set) var recoverRunning = false
    private(set) var recoverExitCode: Int32?
    var recoverSheetVisible = false

    // MARK: devices (config pane, outside a session)

    private(set) var devicesReport: DevicesReport?

    let isDemo = ProcessInfo.processInfo.environment["HUSKE_APP_DEMO"] == "1"
    @ObservationIgnored private var demo: DemoSession?

    init() {
        refreshBinary()
    }

    func bootstrap() async {
        if isDemo {
            let demo = DemoSession(controller: session)
            self.demo = demo
            demo.start()
            transcripts.setRoot(defaultTranscriptRoot())
            return
        }
        await config.reload(binary: binaryURL)
        syncTranscriptRoot()
        // If a TUI/LaunchAgent session is already recording, surface it.
        session.attachIfEngineRunning()
    }

    // MARK: binary management

    func refreshBinary() {
        let override = UserDefaults.standard.string(forKey: Self.binaryOverrideKey)
        binaryURL = BinaryLocator.locate(override: override)
        binaryVersion = nil
        guard let url = binaryURL else { return }
        Task {
            let result = try? await CLIRunner.run(
                binary: url, arguments: ["--version"], timeout: 30)
            guard self.binaryURL == url else { return }
            self.binaryVersion = result?.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "huske ", with: "")
        }
    }

    func setBinaryOverride(_ path: String?) {
        if let path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: Self.binaryOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.binaryOverrideKey)
        }
        refreshBinary()
        Task { await bootstrap() }
    }

    // MARK: session

    func startRecording() {
        guard let binaryURL else { return }
        session.startEngine(binary: binaryURL)
    }

    // MARK: config → transcripts root

    func syncTranscriptRoot() {
        let path = config.snapshot?.string("output_root")
        let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        transcripts.setRoot(url ?? defaultTranscriptRoot())
    }

    private func defaultTranscriptRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("huske/transcripts", isDirectory: true)
    }

    // MARK: doctor

    func runDoctor() {
        guard let binaryURL, !doctorRunning else { return }
        doctorRunning = true
        doctorError = nil
        Task {
            do {
                self.doctorReport = try await DoctorBridge.run(binary: binaryURL)
            } catch {
                self.doctorError = Self.describe(error)
            }
            self.doctorRunning = false
        }
    }

    // MARK: devices

    func refreshDevices() {
        guard let binaryURL else { return }
        Task {
            self.devicesReport = try? await DevicesBridge.list(binary: binaryURL)
        }
    }

    // MARK: recover

    func runRecover() {
        guard let binaryURL, !recoverRunning else { return }
        recoverRunning = true
        recoverExitCode = nil
        recoverLog = []
        recoverSheetVisible = true
        Task {
            do {
                let status = try await CLIRunner.stream(
                    binary: binaryURL,
                    arguments: ["recover"],
                    onLine: { [weak self] line in
                        // EngineProcess delivers on the main queue.
                        MainActor.assumeIsolated {
                            self?.recoverLog.append(line)
                        }
                    }
                )
                self.recoverExitCode = status
            } catch {
                self.recoverLog.append("failed to launch: \(Self.describe(error))")
                self.recoverExitCode = -1
            }
            self.recoverRunning = false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ConfigBridgeError.commandFailed(let message),
            DoctorBridgeError.commandFailed(let message),
            DevicesBridgeError.commandFailed(let message):
            return message
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - engine configuration store

@MainActor
@Observable
final class ConfigStore {
    private(set) var snapshot: HuskeConfigSnapshot?
    private(set) var loadError: String?
    private(set) var writeError: String?
    private(set) var loading = false
    /// Optimistic values for keys with an in-flight write.
    private var overrides: [String: JSONValue] = [:]

    @ObservationIgnored private var binary: URL?

    func reload(binary: URL?) async {
        self.binary = binary
        guard let binary else {
            snapshot = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await ConfigBridge.load(binary: binary)
            loadError = nil
            overrides = [:]
        } catch {
            loadError = AppModel.describe(error)
        }
    }

    func clearWriteError() { writeError = nil }

    // MARK: typed accessors (override-aware)

    func string(_ key: String, default fallback: String = "") -> String {
        if case .string(let s)? = overrides[key] { return s }
        return snapshot?.string(key) ?? fallback
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if case .bool(let b)? = overrides[key] { return b }
        return snapshot?.bool(key) ?? fallback
    }

    func double(_ key: String, default fallback: Double = 0) -> Double {
        if case .number(let n)? = overrides[key] { return n }
        return snapshot?.double(key) ?? fallback
    }

    func isExplicit(_ key: String) -> Bool {
        snapshot?.explicitKeys.contains(key) ?? false
    }

    // MARK: writes

    func set(_ key: String, to value: JSONValue) {
        overrides[key] = value
        let literal: String
        switch value {
        case .string(let s): literal = s
        case .bool(let b): literal = b ? "true" : "false"
        case .number(let n):
            literal = n == n.rounded() && abs(n) < 1e15
                ? String(format: "%.1f", n)
                : String(n)
        default: return
        }
        write(key: key, literal: literal)
    }

    func setInt(_ key: String, to value: Int) {
        overrides[key] = .number(Double(value))
        write(key: key, literal: String(value))
    }

    func unset(_ key: String) {
        guard let binary else { return }
        overrides.removeValue(forKey: key)
        Task {
            do {
                try await ConfigBridge.unset(binary: binary, key: key)
            } catch {
                self.writeError = AppModel.describe(error)
            }
            await self.reload(binary: binary)
        }
    }

    private func write(key: String, literal: String) {
        guard let binary else { return }
        Task {
            do {
                try await ConfigBridge.set(binary: binary, key: key, value: literal)
                self.writeError = nil
            } catch {
                self.writeError = AppModel.describe(error)
            }
            await self.reload(binary: binary)
        }
    }

    // MARK: SwiftUI bindings

    func boolBinding(_ key: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.bool(key, default: fallback) ?? fallback },
            set: { [weak self] newValue in self?.set(key, to: .bool(newValue)) }
        )
    }

    func stringBinding(_ key: String, default fallback: String = "") -> Binding<String> {
        Binding(
            get: { [weak self] in self?.string(key, default: fallback) ?? fallback },
            set: { [weak self] newValue in self?.set(key, to: .string(newValue)) }
        )
    }

    func doubleBinding(_ key: String, default fallback: Double = 0) -> Binding<Double> {
        Binding(
            get: { [weak self] in self?.double(key, default: fallback) ?? fallback },
            set: { [weak self] newValue in self?.set(key, to: .number(newValue)) }
        )
    }
}
