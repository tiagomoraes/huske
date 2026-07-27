// `huske devices --json` — fast microphone listing for the Configuration
// pane when no session is running (a live session serves the same data over
// the control socket instead).

import Foundation

public struct DevicesReport: Equatable, Sendable {
    public let configured: String?
    public let resolvedIndex: Int?
    public let warning: String?
    public let devices: [InputDeviceEntry]
}

public enum DevicesBridgeError: Error, Equatable {
    case commandFailed(String)
    case badOutput
}

public enum DevicesBridge {
    public static func list(binary: URL) async throws -> DevicesReport {
        let result = try await CLIRunner.run(binary: binary, arguments: ["devices", "--json"])
        guard result.status == 0 else {
            let detail = (result.stderr + result.stdout)
                .split(separator: "\n").first.map(String.init) ?? "devices listing failed"
            throw DevicesBridgeError.commandFailed(detail)
        }
        return try parse(result.stdout)
    }

    static func parse(_ text: String) throws -> DevicesReport {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesRaw = obj["devices"] as? [[String: Any]]
        else {
            throw DevicesBridgeError.badOutput
        }
        let devices: [InputDeviceEntry] = devicesRaw.compactMap { raw in
            guard let index = raw["index"] as? Int,
                  let name = raw["name"] as? String
            else { return nil }
            return InputDeviceEntry(
                index: index,
                name: name,
                channels: raw["channels"] as? Int ?? 1,
                sampleRate: (raw["sample_rate"] as? NSNumber)?.doubleValue ?? 48000
            )
        }
        return DevicesReport(
            configured: obj["configured"] as? String,
            resolvedIndex: obj["resolved_index"] as? Int,
            warning: obj["warning"] as? String,
            devices: devices
        )
    }
}
