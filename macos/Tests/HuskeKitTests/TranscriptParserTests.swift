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
    func testScansDayFoldersNewestFirst() throws {
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
        XCTAssertEqual(days[1].entries.map(\.chunkSeq), [1, 2])
        XCTAssertEqual(days[1].entries[0].timeString, "08:45:00")
    }
}
