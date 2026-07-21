// Reads and writes huske's config through `huske config show/set/unset` so
// every write is validated by the engine's own Pydantic model. The app never
// parses or writes the TOML directly.

import Foundation

public struct HuskeConfigSnapshot: Sendable, Equatable {
    public let path: String
    public let exists: Bool
    /// Keys explicitly present in the config file.
    public let explicitKeys: Set<String>
    /// Full effective config (defaults merged with the file), JSON-shaped.
    public let effective: [String: JSONValue]

    public func string(_ key: String) -> String? {
        if case .string(let s)? = effective[key] { return s }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let b)? = effective[key] { return b }
        return nil
    }

    public func double(_ key: String) -> Double? {
        switch effective[key] {
        case .number(let d): return d
        default: return nil
        }
    }

    public func int(_ key: String) -> Int? {
        guard let d = double(key) else { return nil }
        return Int(d)
    }
}

/// Minimal JSON tree, decodable from any `huske … --json` output.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public static func from(any: Any) -> JSONValue {
        // NSNumber bridges both bools and numbers — disambiguate via CFBoolean
        // before any other cast (`as? Bool` would also match 0/1 numbers).
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        }
        switch any {
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map { from(any: $0) })
        case let o as [String: Any]: return .object(o.mapValues { from(any: $0) })
        default: return .null
        }
    }
}

public enum ConfigBridgeError: Error, Equatable {
    case commandFailed(String)
    case badOutput
}

public enum ConfigBridge {
    public static func load(binary: URL) async throws -> HuskeConfigSnapshot {
        let result = try await CLIRunner.run(binary: binary, arguments: ["config", "show", "--json"])
        guard result.status == 0 else {
            throw ConfigBridgeError.commandFailed(firstLine(result.stderr + result.stdout))
        }
        return try parseShowJSON(result.stdout)
    }

    static func parseShowJSON(_ text: String) throws -> HuskeConfigSnapshot {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String,
              let effectiveRaw = obj["effective"] as? [String: Any]
        else {
            throw ConfigBridgeError.badOutput
        }
        let fileRaw = obj["file"] as? [String: Any] ?? [:]
        return HuskeConfigSnapshot(
            path: path,
            exists: obj["exists"] as? Bool ?? false,
            explicitKeys: Set(fileRaw.keys),
            effective: effectiveRaw.mapValues { JSONValue.from(any: $0) }
        )
    }

    /// Set one key. The engine validates before writing; a validation error
    /// surfaces as `.commandFailed` with the pydantic message.
    public static func set(binary: URL, key: String, value: String) async throws {
        let result = try await CLIRunner.run(
            binary: binary, arguments: ["config", "set", key, value])
        guard result.status == 0 else {
            throw ConfigBridgeError.commandFailed(firstLine(result.stdout + result.stderr))
        }
    }

    public static func unset(binary: URL, key: String) async throws {
        let result = try await CLIRunner.run(binary: binary, arguments: ["config", "unset", key])
        guard result.status == 0 else {
            throw ConfigBridgeError.commandFailed(firstLine(result.stdout + result.stderr))
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? "command failed"
    }
}
