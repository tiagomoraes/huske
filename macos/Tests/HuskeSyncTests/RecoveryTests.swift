import Foundation
import XCTest

@testable import HuskeSync

/// Review fixes: closed extension list, stale partial pruning, and
/// re-delivery of verified uploads whose hand-off never finished.
final class RecoveryTests: XCTestCase {
    private func manifest(id: String = "REC-1", ext: String = "m4a", bytes: Data) -> RecordingManifest {
        RecordingManifest(
            id: id, title: "t", startedAt: Date(timeIntervalSince1970: 1_763_571_780),
            durationSeconds: 1, byteCount: Int64(bytes.count),
            sha256: String(repeating: "ab", count: 32), fileExtension: ext,
            contentType: "audio/mp4", sampleRate: 48_000, channels: 1,
            timeZone: "UTC", deviceName: "iPhone de Teste")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("huske-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOnlyAudioExtensionsAreAccepted() {
        XCTAssertNil(manifest(bytes: Data([1])).validationError())
        XCTAssertNotNil(manifest(ext: "json", bytes: Data([1])).validationError())
        XCTAssertNotNil(manifest(ext: "part", bytes: Data([1])).validationError())
        XCTAssertNil(manifest(ext: "wav", bytes: Data([1])).validationError())
    }

    func testStalePartialUploadsArePruned() throws {
        let root = try tempDir()
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let server = SyncServer(
            registry: DeviceRegistry(fileURL: root.appendingPathComponent("devices.json")),
            stagingDirectory: staging, macName: "Mac", serverVersion: "test")
        let old = staging.appendingPathComponent("OLD.part")
        let fresh = staging.appendingPathComponent("NEW.part")
        try Data([1, 2, 3]).write(to: old)
        try Data([1, 2, 3]).write(to: staging.appendingPathComponent("OLD.manifest.json"))
        try Data([4]).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        server.pruneStalePartials()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("OLD.manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testVerifiedUploadsAreRedeliveredAfterARestart() async throws {
        let root = try tempDir()
        let staging = root.appendingPathComponent("staging")
        let verified = staging.appendingPathComponent("verified")
        try FileManager.default.createDirectory(at: verified, withIntermediateDirectories: true)
        let audio = Data("audio-bytes".utf8)
        let m = manifest(id: "STRANDED", bytes: audio)
        try audio.write(to: verified.appendingPathComponent("STRANDED.m4a"))
        try WireJSON.encoder().encode(m).write(to: verified.appendingPathComponent("STRANDED.manifest.json"))

        let server = SyncServer(
            registry: DeviceRegistry(fileURL: root.appendingPathComponent("devices.json")),
            stagingDirectory: staging, macName: "Mac", serverVersion: "test")
        let delegate = FakeDelegate()
        server.delegate = delegate
        await server.redeliverVerified()

        XCTAssertEqual(delegate.received.map(\.0.id), ["STRANDED"])
        XCTAssertEqual(delegate.received.first?.1, audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verified.appendingPathComponent("STRANDED.manifest.json").path))
    }
}
