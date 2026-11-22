import XCTest

@testable import HuskeSync

final class FramingTests: XCTestCase {
    private let manifest = RecordingManifest(
        id: "4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11",
        title: "Reunião com a Ana",
        startedAt: Date(timeIntervalSince1970: 1_763_571_780),
        durationSeconds: 1834.5,
        byteCount: 14_801_234,
        sha256: String(repeating: "ab", count: 32),
        fileExtension: "m4a",
        contentType: "audio/mp4",
        sampleRate: 48_000,
        channels: 1,
        timeZone: "America/Sao_Paulo",
        deviceName: "iPhone de Tiago")

    private var allMessages: [WireMessage] {
        let status = RemoteStatus(
            recordingID: "r1", state: .transcribing, detail: "1 of 3 chunks",
            updatedAt: Date(timeIntervalSince1970: 1_763_573_000), progress: 0.33)
        return [
            .hello(HelloMessage(protocolVersion: 1, deviceID: "d1", deviceName: "iPhone", deviceModel: "iPhone17,1", appVersion: "1.0")),
            .welcome(Welcome(protocolVersion: 1, macID: "m1", macName: "Mac", serverVersion: "0.14.0", engineAvailable: true)),
            .offer(OfferMessage(recording: manifest)),
            .offerReply(OfferReplyMessage(recordingID: "r1", action: .send, offset: 262_144)),
            .chunk(ChunkMessage(recordingID: "r1", offset: 0), body: Data(repeating: 7, count: 1000)),
            .chunkAck(ChunkAckMessage(recordingID: "r1", received: 1000)),
            .commit(CommitMessage(recordingID: "r1")),
            .committed(CommittedMessage(status: status)),
            .status(StatusRequestMessage(recordingIDs: ["r1", "r2"])),
            .statusReply(StatusReplyMessage(items: [status, .unknown("r2", now: Date(timeIntervalSince1970: 1_763_573_000))])),
            .transcript(TranscriptRequestMessage(recordingID: "r1")),
            .transcriptReply(TranscriptReplyMessage(recordingID: "r1", available: true), body: Data("# Olá\n".utf8)),
            .transcriptReply(TranscriptReplyMessage(recordingID: "r2", available: false), body: Data()),
            .bye,
            .error(ErrorMessage(code: .offsetMismatch, message: "expected 10", received: 10)),
        ]
    }

    private func decodeAll(_ bytes: Data, splitEvery step: Int) throws -> [WireMessage] {
        var decoder = FrameDecoder()
        var out: [WireMessage] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + step, bytes.count)
            decoder.append(bytes.subdata(in: index..<end))
            index = end
            while let frame = try decoder.nextFrame() {
                out.append(try WireCodec.decode(frame))
            }
        }
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        return out
    }

    func testEveryMessageRoundTrips() throws {
        for message in allMessages {
            let bytes = try WireCodec.encode(message)
            XCTAssertEqual(try decodeAll(bytes, splitEvery: bytes.count), [message], message.type)
        }
    }

    func testPartialReadsByteByByteAndOddSplits() throws {
        var stream = Data()
        for message in allMessages { stream.append(try WireCodec.encode(message)) }
        for step in [1, 2, 3, 5, 7, 64, 1021, stream.count] {
            XCTAssertEqual(try decodeAll(stream, splitEvery: step), allMessages, "split \(step)")
        }
    }

    func testIncompleteFrameWaitsForMoreBytes() throws {
        let bytes = try WireCodec.encode(.chunk(ChunkMessage(recordingID: "r", offset: 0), body: Data(count: 100)))
        var decoder = FrameDecoder()
        decoder.append(bytes.prefix(3))  // not even the length prefix
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(bytes.dropFirst(3).prefix(20))  // part of the header
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(bytes.dropFirst(23).dropLast(1))  // all but the last body byte
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(bytes.suffix(1))
        let frame = try XCTUnwrap(try decoder.nextFrame())
        XCTAssertEqual(frame.body.count, 100)
    }

    func testHeaderLayout() throws {
        let bytes = try WireCodec.encode(.chunk(ChunkMessage(recordingID: "r1", offset: 42), body: Data([1, 2, 3])))
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let header = bytes.dropFirst(4).prefix(length)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "chunk")
        XCTAssertEqual(json["bodyLength"] as? Int, 3)
        XCTAssertEqual(json["offset"] as? Int, 42)
        XCTAssertEqual(json["recordingID"] as? String, "r1")
        XCTAssertEqual(Array(bytes.suffix(3)), [1, 2, 3])

        // No body → no bodyLength key.
        let bye = try WireCodec.encode(.bye)
        let byeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: bye.dropFirst(4)) as? [String: Any])
        XCTAssertEqual(byeJSON.keys.sorted(), ["type"])
    }

    func testDatesCarryAUTCOffset() throws {
        let text = WireDate.format(
            Date(timeIntervalSince1970: 1_763_571_780), timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        XCTAssertEqual(text, "2025-11-19T14:03:00-03:00")
        XCTAssertEqual(WireDate.parse(text), Date(timeIntervalSince1970: 1_763_571_780))
        XCTAssertEqual(WireDate.parse("2025-11-19T17:03:00Z"), Date(timeIntervalSince1970: 1_763_571_780))
        XCTAssertEqual(WireDate.parse("2025-11-19T17:03:00.500Z"), Date(timeIntervalSince1970: 1_763_571_780.5))
    }

    func testDecodesTheContractExampleManifest() throws {
        let header = #"""
            {"type":"offer","recording":{"id":"4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11","title":"Reunião com a Ana",
            "startedAt":"2026-11-19T14:03:00-03:00","durationSeconds":1834.5,"byteCount":14801234,
            "sha256":"\#(String(repeating: "0", count: 64))","fileExtension":"m4a","contentType":"audio/mp4",
            "sampleRate":48000,"channels":1,"timeZone":"America/Sao_Paulo","deviceName":"iPhone de Tiago"}}
            """#
        let message = try WireCodec.decode(Frame(header: Data(header.utf8), body: Data()))
        guard case .offer(let offer) = message else { return XCTFail("not an offer") }
        XCTAssertEqual(offer.recording.byteCount, 14_801_234)
        XCTAssertEqual(offer.recording.startedAt, WireDate.parse("2026-11-19T17:03:00Z"))
    }

    func testLimitsAreEnforced() throws {
        var decoder = FrameDecoder()
        var tooLong = UInt32(SyncConstants.maxHeaderLength + 1).bigEndian
        decoder.append(withUnsafeBytes(of: &tooLong) { Data($0) })
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? SyncError, .protocolError(code: "too_large", message: "header length 65537 out of range"))
        }

        var bodyTooBig = FrameDecoder()
        let header = Data(#"{"type":"chunk","recordingID":"r","offset":0,"bodyLength":1048577}"#.utf8)
        var length = UInt32(header.count).bigEndian
        bodyTooBig.append(withUnsafeBytes(of: &length) { Data($0) } + header)
        XCTAssertThrowsError(try bodyTooBig.nextFrame())

        XCTAssertThrowsError(
            try WireCodec.encode(.chunk(ChunkMessage(recordingID: "r", offset: 0), body: Data(count: SyncConstants.maxBodyLength + 1))))
    }

    func testUnknownTypeAndMalformedHeaderAreBadRequests() {
        XCTAssertThrowsError(try WireCodec.decode(Frame(header: Data(#"{"type":"teleport"}"#.utf8), body: Data()))) {
            guard case .protocolError(let code, _) = $0 as? SyncError else { return XCTFail() }
            XCTAssertEqual(code, "bad_request")
        }
        XCTAssertThrowsError(try WireCodec.decode(Frame(header: Data(#"{"type":"chunk"}"#.utf8), body: Data()))) {
            guard case .protocolError(let code, _) = $0 as? SyncError else { return XCTFail() }
            XCTAssertEqual(code, "bad_request")
        }
    }

    func testTranscriptTruncationKeepsCharacterBoundaries() {
        let text = String(repeating: "ção ", count: 400_000)  // > 1 MiB of UTF-8
        let data = SyncServer.utf8Prefix(text, maxBytes: SyncConstants.maxBodyLength)
        XCTAssertLessThanOrEqual(data.count, SyncConstants.maxBodyLength)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }
}
