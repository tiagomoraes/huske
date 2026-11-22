import XCTest
@testable import Huske

final class TranscriptParserTests: XCTestCase {
    func testHeadingsAndRuns() {
        let markdown = """
        # 09:30 – 09:45 (Wed 2026-05-07)

        [09:30:00 · mic] Olá, vamos começar.

        [09:30:08 · mic · echo] Hoje queria revisar
        o roadmap.
        """
        XCTAssertEqual(TranscriptParser.parse(markdown), [
            .heading("09:30 – 09:45 (Wed 2026-05-07)"),
            .run(time: "09:30:00", source: "mic", text: "Olá, vamos começar."),
            .run(time: "09:30:08", source: "mic · echo", text: "Hoje queria revisar o roadmap."),
        ])
    }

    func testJoinedChunksWithoutBlankLinesStillSplitAtRunHeads() {
        let markdown = "# 10:00 – 10:15 (Thu)\n[10:00:01 · mic] one\n[10:00:09 · mic] two"
        let blocks = TranscriptParser.parse(markdown)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[2], .run(time: "10:00:09", source: "mic", text: "two"))
    }

    func testFrontmatterIsStrippedIfPresent() {
        let markdown = "---\nsession_id: x\nchunk_seq: 1\n---\n\n[10:00:01 · mic] hello"
        XCTAssertEqual(TranscriptParser.parse(markdown), [.run(time: "10:00:01", source: "mic", text: "hello")])
    }

    func testOtherTextIsAParagraph() {
        let blocks = TranscriptParser.parse("_(no speech detected)_\n\n[not a time] words")
        XCTAssertEqual(blocks, [.paragraph("_(no speech detected)_"), .paragraph("[not a time] words")])
    }

    func testDuplicateBlocksGetDistinctIDs() {
        let blocks = TranscriptParser.parse("[10:00:01 · mic] ok\n\n[10:00:01 · mic] ok")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertNotEqual(blocks[0].id, blocks[1].id)
    }

    func testExcerptSkipsHeadingsAndEmptyNotes() {
        XCTAssertEqual(TranscriptParser.excerpt("# 10:00\n\n[10:00:01 · mic] First words."), "First words.")
        XCTAssertNil(TranscriptParser.excerpt("_(no speech detected)_"))
    }
}
