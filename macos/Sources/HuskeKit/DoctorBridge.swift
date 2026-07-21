// Runs `huske doctor --json` and `huske devices --json` and models their
// output for the Doctor pane.

import Foundation

public struct DoctorCheck: Equatable, Sendable, Identifiable {
    public let name: String
    public let ok: Bool
    public let detail: String
    public let hint: String?

    public var id: String { name + "|" + detail }

    public init(name: String, ok: Bool, detail: String, hint: String?) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.hint = hint
    }
}

public struct DoctorReport: Equatable, Sendable {
    public let version: String
    public let ok: Bool
    public let checks: [DoctorCheck]
    public let inputDevices: [InputDeviceEntry]

    public init(version: String, ok: Bool, checks: [DoctorCheck], inputDevices: [InputDeviceEntry]) {
        self.version = version
        self.ok = ok
        self.checks = checks
        self.inputDevices = inputDevices
    }
}

public enum DoctorBridgeError: Error, Equatable {
    case commandFailed(String)
    case badOutput
}

public enum DoctorBridge {
    /// `huske doctor` probes devices and records a 1 s mic sample; give it
    /// room. Exit codes 1/3 still print the full JSON report (failed checks),
    /// so any parseable output wins over the status code.
    public static func run(binary: URL) async throws -> DoctorReport {
        let result = try await CLIRunner.run(
            binary: binary, arguments: ["doctor", "--json"], timeout: 180)
        if let report = try? parse(result.stdout) {
            return report
        }
        let detail = (result.stderr + result.stdout)
            .split(separator: "\n").first.map(String.init) ?? "doctor produced no output"
        throw DoctorBridgeError.commandFailed(detail)
    }

    static func parse(_ text: String) throws -> DoctorReport {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checksRaw = obj["checks"] as? [[String: Any]]
        else {
            throw DoctorBridgeError.badOutput
        }
        let checks: [DoctorCheck] = checksRaw.compactMap { raw in
            guard let name = raw["name"] as? String,
                  let ok = raw["ok"] as? Bool
            else { return nil }
            return DoctorCheck(
                name: name,
                ok: ok,
                detail: raw["detail"] as? String ?? "",
                hint: raw["hint"] as? String
            )
        }
        let devicesRaw = obj["input_devices"] as? [[String: Any]] ?? []
        let devices: [InputDeviceEntry] = devicesRaw.compactMap { raw in
            guard let index = raw["index"] as? Int,
                  let name = raw["name"] as? String
            else { return nil }
            let rate = (raw["sample_rate"] as? NSNumber)?.doubleValue ?? 48000
            return InputDeviceEntry(
                index: index,
                name: name,
                channels: raw["channels"] as? Int ?? 1,
                sampleRate: rate
            )
        }
        return DoctorReport(
            version: obj["version"] as? String ?? "",
            ok: obj["ok"] as? Bool ?? checks.allSatisfy(\.ok),
            checks: checks,
            inputDevices: devices
        )
    }
}
