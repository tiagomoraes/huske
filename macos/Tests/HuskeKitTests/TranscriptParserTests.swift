import XCTest

@testable import HuskeKit

final class TranscriptParserTests: XCTestCase {
    private let sample = """
        ---
        session_id: 20260507T091500_8a3f2c19
        chunk_seq: 2
        date: 2026-05-07
        start_time: 2026-05-07T09:30:00-03:00
        end_time: 2026-05-07T09:45:00-03:00
        duration_seconds: 900
        duration_actual_seconds: 900.0
        gap_seconds: 0.0
        audio_sources:
          - microphone
          - system
        model: parakeet:tdt-0.6b-v3
        language: pt
        incomplete: false
        huske_version: 0.10.0
        ---

        # 09:30 – 09:45 (Wed 2026-05-07)

        [09:30:00 · system] Olá, vamos começar a reunião.

        [09:30:01 · mic] Oi, tudo certo.
        Continuação da mesma fala em outra linha.

        [09:30:08 · system] Hoje queria revisar o roadmap.
        """

    func testParsesFrontmatter() throws {
        let doc = try XCTUnwrap(TranscriptParser.parse(sample))
        XCTAssertEqual(doc.meta.sessionId, "20260507T091500_8a3f2c19")
        XCTAssertEqual(doc.meta.chunkSeq, 2)
        XCTAssertEqual(doc.meta.date, "2026-05-07")
        XCTAssertEqual(doc.meta.durationSeconds, 900)
        XCTAssertEqual(doc.meta.durationActualSeconds, 900.0, accuracy: 0.001)
        XCTAssertEqual(doc.meta.audioSources, ["microphone", "system"])
        XCTAssertEqual(doc.meta.model, "parakeet:tdt-0.6b-v3")
        XCTAssertEqual(doc.meta.language, "pt")
        XCTAssertFalse(doc.meta.incomplete)
        XCTAssertEqual(doc.meta.huskeVersion, "0.10.0")
        XCTAssertNotNil(doc.meta.startTime)
        XCTAssertNotNil(doc.meta.endTime)
    }

    func testParsesRuns() throws {
        let doc = try XCTUnwrap(TranscriptParser.parse(sample))
        XCTAssertEqual(doc.heading, "09:30 – 09:45 (Wed 2026-05-07)")
        XCTAssertEqual(doc.runs.count, 3)
        XCTAssertEqual(doc.runs[0].source, .system)
        XCTAssertEqual(doc.runs[0].time, "09:30:00")
        XCTAssertEqual(doc.runs[0].text, "Olá, vamos começar a reunião.")
        XCTAssertEqual(doc.runs[1].source, .mic)
        XCTAssertEqual(
            doc.runs[1].text, "Oi, tudo certo. Continuação da mesma fala em outra linha.")
        XCTAssertEqual(doc.runs[2].source, .system)
    }

    func testParsesInlineAudioSources() throws {
        let text = """
            ---
            session_id: x
            audio_sources: [microphone, system]
            ---
            body
            """
        let doc = try XCTUnwrap(TranscriptParser.parse(text))
        XCTAssertEqual(doc.meta.audioSources, ["microphone", "system"])
    }

    func testParsesEchoAnnotatedRun() {
        let head = TranscriptParser.parseRunHead("[09:30:01 · mic · echo] duplicated line")
        XCTAssertEqual(head?.1, .micEcho)
        XCTAssertEqual(head?.2, "duplicated line")
    }

    func testNoSpeechBodyHasNoRuns() throws {
        let text = """
            ---
            session_id: x
            ---

            _(no speech detected)_
            """
        let doc = try XCTUnwrap(TranscriptParser.parse(text))
        XCTAssertTrue(doc.isEmpty)
    }

    func testUnrecognizedNonemptyBodyIsNotTreatedAsNoSpeech() throws {
        let text = """
            ---
            session_id: x
            ---

            body that does not match the run format
            """
        let doc = try XCTUnwrap(TranscriptParser.parse(text))
        XCTAssertFalse(doc.isEmpty)
    }

    func testMissingFrontmatterReturnsNil() {
        XCTAssertNil(TranscriptParser.parse("# just a heading\n\nsome text"))
    }

    func testParseFilename() {
        let info = TranscriptParser.parseFilename("091500_8a3f2c19_002.md")
        XCTAssertEqual(info?.timeString, "09:15:00")
        XCTAssertEqual(info?.sessionId8, "8a3f2c19")
        XCTAssertEqual(info?.chunkSeq, 2)
    }

    func testParseFilenameWithDisambiguationSuffix() {
        let info = TranscriptParser.parseFilename("091500_8a3f2c19_002_a1b2.md")
        XCTAssertEqual(info?.chunkSeq, 2)
    }

    func testParseFilenameRejectsOtherFiles() {
        XCTAssertNil(TranscriptParser.parseFilename("README.md"))
        XCTAssertNil(TranscriptParser.parseFilename("notes.md"))
    }

    func testIsDayFolder() {
        XCTAssertTrue(TranscriptParser.isDayFolder("2026-05-07"))
        XCTAssertFalse(TranscriptParser.isDayFolder("incomplete"))
        XCTAssertFalse(TranscriptParser.isDayFolder("2026-5-7"))
    }
}

final class TranscriptScannerTests: XCTestCase {
    func testScansDaysAndChunksNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        for (day, files) in [
            "2026-05-06": ["084500_8a3f2c19_001.md", "090000_8a3f2c19_002.md"],
            "2026-05-07": ["091500_b71e0440_001.md"],
        ] {
            let dayDir = root.appendingPathComponent(day)
            try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
            for file in files {
                try "---\nsession_id: x\n---\nbody".write(
                    to: dayDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        }
        // Distractors that must be ignored.
        try fm.createDirectory(at: root.appendingPathComponent("incomplete"), withIntermediateDirectories: true)
        try "readme".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let days = TranscriptScanner.scan(root: root)
        XCTAssertEqual(days.map(\.date), ["2026-05-07", "2026-05-06"])
        XCTAssertEqual(days[1].entries.map(\.chunkSeq), [2, 1])
        XCTAssertEqual(days[1].entries[0].timeString, "09:00:00")
    }

    func testOmitsLegacyNoSpeechTranscriptsAndEmptyDays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("2026-05-07")
        try FileManager.default.createDirectory(
            at: dayDir, withIntermediateDirectories: true)
        try """
            ---
            session_id: x
            ---

            # 09:15 – 09:30 (Wed 2026-05-07)

            _(no speech detected)_
            """.write(
                to: dayDir.appendingPathComponent("091500_b71e0440_001.md"),
                atomically: true,
                encoding: .utf8)

        XCTAssertTrue(TranscriptScanner.scan(root: root).isEmpty)
    }

    func testWarmCacheSkipsRereadingUnchangedFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("huske-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dayDir = root.appendingPathComponent("2026-05-07")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)

        for seq in 1...3 {
            try "---\nsession_id: x\n---\n\n[09:15:00 · mic] hello"
                .write(
                    to: dayDir.appendingPathComponent(
                        String(format: "0915%02d_b71e0440_%03d.md", seq, seq)),
                    atomically: true, encoding: .utf8)
        }

        let cold = TranscriptScanner.scan(root: root, cache: TranscriptScanCache())
        XCTAssertEqual(cold.filesRead, 3)
        XCTAssertEqual(cold.days.first?.entries.count, 3)

        let warm = TranscriptScanner.scan(root: root, cache: cold.cache)
        XCTAssertEqual(warm.filesRead, 0, "unchanged files must reuse their cached verdict")
        XCTAssertEqual(warm.days, cold.days)

        // A new chunk costs exactly one read.
        try "---\nsession_id: x\n---\n\n[09:16:00 · mic] more"
            .write(
                to: dayDir.appendingPathComponent("091600_b71e0440_004.md"),
                atomically: true, encoding: .utf8)
        let incremental = TranscriptScanner.scan(root: root, cache: warm.cache)
        XCTAssertEqual(incremental.filesRead, 1)
        XCTAssertEqual(incremental.days.first?.entries.count, 4)
    }

    func testCacheInvalidatesOnRewriteAndDropsDeletedFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("huske-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dayDir = root.appendingPathComponent("2026-05-07")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let marker = dayDir.appendingPathComponent("091500_b71e0440_001.md")
        let keeper = dayDir.appendingPathComponent("091600_b71e0440_002.md")
        try "---\nsession_id: x\n---\n\n_(no speech detected)_"
            .write(to: marker, atomically: true, encoding: .utf8)
        try "---\nsession_id: x\n---\n\n[09:16:00 · mic] hi"
            .write(to: keeper, atomically: true, encoding: .utf8)

        let cold = TranscriptScanner.scan(root: root, cache: TranscriptScanCache())
        XCTAssertEqual(cold.days.first?.entries.map(\.chunkSeq), [2])
        XCTAssertEqual(cold.cache.count, 2)

        // Rewriting the marker with real content must re-read it, not serve
        // the stale "this is a marker" verdict.
        try "---\nsession_id: x\n---\n\n[09:15:00 · mic] actually spoke"
            .write(to: marker, atomically: true, encoding: .utf8)
        let rewritten = TranscriptScanner.scan(root: root, cache: cold.cache)
        XCTAssertEqual(rewritten.filesRead, 1)
        XCTAssertEqual(rewritten.days.first?.entries.map(\.chunkSeq), [2, 1])

        try fm.removeItem(at: marker)
        let pruned = TranscriptScanner.scan(root: root, cache: rewritten.cache)
        XCTAssertEqual(pruned.cache.count, 1, "deleted files must drop out of the cache")
    }
}
