// Async helpers for one-shot `huske <subcommand>` invocations (config, doctor,
// devices, recover). Never used for `huske run` — that goes through
// EngineProcess so the app can supervise it.

import Foundation

public struct CLIResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum CLIRunner {
    /// Run to completion and capture output.
    public static func run(
        binary: URL,
        arguments: [String],
        timeout: TimeInterval = 120
    ) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["HUSKE_NO_UPDATE_CHECK"] = "1"
                process.environment = env
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let watchdog = DispatchWorkItem { [weak process] in
                    process?.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Read fully before waitUntilExit so a large output cannot
                // deadlock on a full pipe.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                continuation.resume(
                    returning: CLIResult(
                        status: process.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
            }
        }
    }

    /// Run while streaming combined output lines to `onLine` (main queue).
    /// Returns the exit status.
    public static func stream(
        binary: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let engine = EngineProcess(binary: binary, arguments: arguments)
        engine.onOutputLine = onLine
        return try await withCheckedThrowingContinuation { continuation in
            engine.onTermination = { status in
                withExtendedLifetime(engine) {} // keep the supervisor alive until exit
                continuation.resume(returning: status)
            }
            do {
                try engine.launch()
            } catch {
                engine.onTermination = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
