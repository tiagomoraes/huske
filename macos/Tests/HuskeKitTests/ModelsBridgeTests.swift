import XCTest

@testable import HuskeKit

/// `huske models … --json`, decoded from samples shaped exactly like the
/// engine's output (taken from a real run), plus the words the
/// Configuration pane builds from them.
final class ModelsBridgeTests: XCTestCase {
    private static let parakeetV3 = """
        {"id": "parakeet-tdt-0.6b-v3", "name": "Parakeet v3", "family": "parakeet",
         "family_label": "Parakeet", "repo": "mlx-community/parakeet-tdt-0.6b-v3",
         "label": "parakeet:tdt-0.6b-v3",
         "summary": "Fast and quiet on silence; 25 European languages, recognised automatically.",
         "note": "Can't be told the language: mixed Portuguese and English can slip into English.",
         "languages": ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                       "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"],
         "language_count": 25, "pins_language": false, "dictionary": "boost", "size_mb": 2508,
         "speed": "fastest", "accuracy": "very good",
         "measured": "51x real time on an M3 Pro; 5 of 10 jargon terms right in Portuguese, 9 in English",
         "default": true, "recommended": true, "in_catalog": true, "downloaded": true,
         "in_use": false, "runtime_available": true}
        """

    private static let turbo = """
        {"id": "whisper-large-v3-turbo", "name": "Whisper large-v3 turbo", "family": "whisper",
         "family_label": "Whisper", "repo": "mlx-community/whisper-large-v3-turbo",
         "label": "mlx-whisper:large-v3-turbo",
         "summary": "Locks the language you choose and spells jargon well; the pick for mixed-language meetings.",
         "note": "", "languages": null, "language_count": 100, "pins_language": true,
         "dictionary": "prompt", "size_mb": 1614, "speed": "fast", "accuracy": "very good",
         "measured": "24x real time on an M3 Pro; 7 of 10 jargon terms right in Portuguese, 10 in English",
         "default": false, "recommended": true, "in_catalog": true, "downloaded": false,
         "in_use": false, "runtime_available": true}
        """

    private static let english110M = """
        {"id": "parakeet-tdt_ctc-110m", "name": "Parakeet 110M, English", "family": "parakeet",
         "family_label": "Parakeet", "repo": "mlx-community/parakeet-tdt_ctc-110m",
         "label": "parakeet:tdt_ctc-110m",
         "summary": "English only and very light: the fastest model here.", "note": "English only.",
         "languages": ["en"], "language_count": 1, "pins_language": false, "dictionary": "boost",
         "size_mb": 459, "speed": "fastest", "accuracy": "good",
         "measured": "81x real time on an M3 Pro; 6 of 10 jargon terms right in English",
         "default": false, "recommended": false, "in_catalog": true, "downloaded": true,
         "in_use": false, "runtime_available": true}
        """

    /// What `huske models use someone/whisper-large-v4-mlx` leaves
    /// behind: an ad-hoc current model, listed first, facts unknown.
    private static let adhoc = """
        {"id": "someone/whisper-large-v4-mlx", "name": "large-v4",
         "family": "whisper", "family_label": "Whisper",
         "repo": "someone/whisper-large-v4-mlx",
         "label": "mlx-whisper:large-v4", "summary": "", "note": "", "languages": null,
         "language_count": 100, "pins_language": true, "dictionary": "prompt", "size_mb": null,
         "speed": null, "accuracy": null, "measured": null, "default": false, "recommended": false,
         "in_catalog": false, "downloaded": false, "in_use": true, "runtime_available": true}
        """

    private static let families = """
        [{"name": "parakeet", "label": "Parakeet", "pins_language": false, "dictionary": "boost", "available": true},
         {"name": "whisper", "label": "Whisper", "pins_language": true, "dictionary": "prompt", "available": true}]
        """

    private static func model(_ json: String) throws -> TranscriptionModel {
        try ModelsBridge.parseModel(json)
    }

    // MARK: list

    func testCatalogDecodesInEngineOrder() throws {
        let current = Self.turbo.replacingOccurrences(of: #""in_use": false"#, with: #""in_use": true"#)
        let catalog = try ModelsBridge.parseCatalog("""
            {"current": \(current), "models": [\(Self.parakeetV3), \(current), \(Self.english110M)],
             "families": \(Self.families)}
            """)
        XCTAssertEqual(catalog.models.map(\.id), [
            "parakeet-tdt-0.6b-v3", "whisper-large-v3-turbo", "parakeet-tdt_ctc-110m",
        ])
        XCTAssertEqual(catalog.current?.id, "whisper-large-v3-turbo")
        XCTAssertEqual(catalog.current?.inUse, true)
        XCTAssertEqual(catalog.families.map(\.label), ["Parakeet", "Whisper"])
        XCTAssertEqual(catalog.families.last?.pinsLanguage, true)
        XCTAssertEqual(catalog.languageLockingChoice?.id, "whisper-large-v3-turbo")

        let parakeet = catalog.models[0]
        XCTAssertEqual(parakeet.name, "Parakeet v3")
        XCTAssertEqual(parakeet.familyLabel, "Parakeet")
        XCTAssertEqual(parakeet.languages?.count, 25)
        XCTAssertEqual(parakeet.languageCount, 25)
        XCTAssertFalse(parakeet.pinsLanguage)
        XCTAssertEqual(parakeet.dictionary, "boost")
        XCTAssertEqual(parakeet.sizeMB, 2508)
        XCTAssertEqual(parakeet.speed, "fastest")
        XCTAssertEqual(parakeet.accuracy, "very good")
        XCTAssertTrue(parakeet.isDefault)
        XCTAssertTrue(parakeet.recommended)
        XCTAssertTrue(parakeet.downloaded)
        XCTAssertTrue(parakeet.measured?.hasPrefix("51x real time") ?? false)

        let turbo = catalog.models[1]
        XCTAssertNil(turbo.languages, "null means every Whisper language")
        XCTAssertEqual(turbo.languageCount, 100)
        XCTAssertEqual(turbo.note, "")
        XCTAssertFalse(turbo.downloaded)
    }

    func testAdHocCurrentModelComesFirstWithUnknownFacts() throws {
        let catalog = try ModelsBridge.parseCatalog("""
            {"current": \(Self.adhoc), "models": [\(Self.adhoc), \(Self.parakeetV3)],
             "families": \(Self.families)}
            """)
        let current = try XCTUnwrap(catalog.current)
        XCTAssertEqual(catalog.models.first?.id, current.id)
        XCTAssertFalse(current.inCatalog)
        XCTAssertNil(current.sizeMB)
        XCTAssertNil(current.speed)
        XCTAssertNil(current.measured)
        XCTAssertEqual(current.summary, "")
        XCTAssertEqual(ModelWords.downloadPhrase(current), "Downloads the first time it's used")
        XCTAssertNil(ModelWords.speedAndAccuracy(current))
        XCTAssertEqual(
            ModelWords.rowFacts(current), "Whisper model · Locks the language you choose · 100 languages")
        XCTAssertEqual(catalog.model(id: "someone/whisper-large-v4-mlx")?.name, "large-v4")
    }

    func testMissingCurrentFallsBackToTheModelInUseAndFieldsDefault() throws {
        let catalog = try ModelsBridge.parseCatalog("""
            {"models": [{"id": "whisper-tiny", "in_use": true}, {"name": "no id"}]}
            """)
        XCTAssertEqual(catalog.models.count, 1, "rows without an id are skipped")
        let tiny = try XCTUnwrap(catalog.current)
        XCTAssertEqual(tiny.id, "whisper-tiny")
        XCTAssertEqual(tiny.name, "whisper-tiny")
        XCTAssertEqual(tiny.repo, "whisper-tiny")
        XCTAssertEqual(tiny.dictionary, "none")
        XCTAssertTrue(tiny.inCatalog)
        XCTAssertTrue(tiny.runtimeAvailable)
        XCTAssertTrue(catalog.families.isEmpty)
    }

    func testListFailureAndInfoFailureThrowTheEnginesWords() {
        let refusal = #"{"error": "'nope' is not a model Huske knows: use an id from `huske models`, a Hugging Face repo (owner/name) or a local folder"}"#
        XCTAssertThrowsError(try ModelsBridge.parseModel(refusal)) { error in
            guard case ModelsBridgeError.failed(let message) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(message.hasPrefix("'nope' is not a model Huske knows"))
        }
        XCTAssertThrowsError(try ModelsBridge.parseCatalog(#"{"error": "config is broken"}"#))
        XCTAssertThrowsError(try ModelsBridge.parseCatalog("Traceback (most recent call last):"))
    }

    // MARK: use

    func testUseSuccessDecodes() throws {
        let result = try ModelsBridge.parseUse("""
            {"model": \(Self.turbo.replacingOccurrences(of: #""in_use": false"#, with: #""in_use": true"#)),
             "written": {"asr_model": "whisper-large-v3-turbo", "asr_engine": "whisper"},
             "notes": ["Downloads 1.6 GB the first time it's used (`huske models download whisper-large-v3-turbo` fetches it now).",
                       "A running session keeps its model; the next one uses this."],
             "error": null}
            """)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.model?.id, "whisper-large-v3-turbo")
        XCTAssertEqual(result.model?.inUse, true)
        XCTAssertEqual(result.written["asr_model"], .string("whisper-large-v3-turbo"))
        XCTAssertEqual(result.written["asr_engine"], .string("whisper"))
        XCTAssertEqual(result.notes.count, 2)
    }

    func testUseRefusalKeepsTheEnginesSentence() throws {
        let result = try ModelsBridge.parseUse(
            #"{"error": "Huske can't tell which engine runs 'foo/bar' (it knows: parakeet, whisper). Repos are matched by name, folders by their config.json."}"#
        )
        XCTAssertNil(result.model)
        XCTAssertTrue(result.written.isEmpty)
        XCTAssertEqual(
            result.error,
            "Huske can't tell which engine runs 'foo/bar' (it knows: parakeet, whisper). "
                + "Repos are matched by name, folders by their config.json.")
    }

    // MARK: try

    func testTrySuccessDecodes() throws {
        let result = try ModelsBridge.parseTry("""
            {"ok": true, "model": \(Self.turbo), "audio_seconds": 10.4, "load_seconds": 2.2,
             "seconds": 0.09, "x_realtime": 121.0, "language": "pt", "synthetic": true,
             "text": "Bom dia, pessoal, hoje a gente vai revisar o planejamento do trimestre.",
             "error": null}
            """)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.model?.id, "whisper-large-v3-turbo")
        XCTAssertEqual(result.audioSeconds, 10.4)
        XCTAssertEqual(result.loadSeconds, 2.2)
        XCTAssertEqual(result.xRealtime, 121.0)
        XCTAssertEqual(result.language, "pt")
        XCTAssertTrue(result.synthetic)
        XCTAssertTrue(result.text.hasPrefix("Bom dia"))
        let pieces = ModelWords.tryPieces(result)
        XCTAssertEqual(pieces.map(\.text).joined(), "121× real time · loads in 2.2s")
        XCTAssertEqual(pieces.filter(\.number).map(\.text), ["121×", "2.2s"])
    }

    func testTryFailureDecodes() throws {
        let result = try ModelsBridge.parseTry(
            #"{"error": "'nope' is not a model Huske knows: use an id from `huske models`, a Hugging Face repo (owner/name) or a local folder", "ok": false}"#
        )
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.model)
        XCTAssertTrue(result.error?.contains("is not a model Huske knows") ?? false)
    }

    // MARK: download stream

    func testDownloadLinesDecode() {
        XCTAssertEqual(
            ModelsBridge.parseDownloadLine(
                #"{"event": "progress", "id": "whisper-base", "bytes": 2122, "total": 143726326}"#),
            .progress(bytes: 2122, total: 143_726_326))
        let half = ModelsBridge.parseDownloadLine(
            #"{"event": "progress", "id": "whisper-base", "bytes": 71863163, "total": 143726326}"#)
        XCTAssertEqual(half?.fraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(
            ModelsBridge.parseDownloadLine(
                #"{"event": "progress", "id": "x", "bytes": 10, "total": 0}"#),
            .progress(bytes: 10, total: nil), "an unknown total is not a total")
        XCTAssertNil(ModelsBridge.parseDownloadLine(#"{"event": "progress", "bytes": 1, "total": 0}"#)?.fraction)
        XCTAssertEqual(
            ModelsBridge.parseDownloadLine(
                #"{"event": "done", "id": "whisper-base", "already": false, "error": null}"#),
            .done(already: false))
        XCTAssertEqual(
            ModelsBridge.parseDownloadLine(
                #"{"event": "done", "id": "whisper-tiny", "already": true, "error": null}"#),
            .done(already: true))
        XCTAssertEqual(
            ModelsBridge.parseDownloadLine(
                #"{"error": "download failed: 404 Client Error", "event": "error", "id": "x"}"#),
            .failed("download failed: 404 Client Error"))
        XCTAssertEqual(
            ModelsBridge.parseDownloadLine(#"{"error": "'nope' is not a model Huske knows"}"#),
            .failed("'nope' is not a model Huske knows"), "a refusal before any event")
        XCTAssertNil(ModelsBridge.parseDownloadLine("Fetching 4 files:  25%|██▌       | 1/4"))
        XCTAssertNil(ModelsBridge.parseDownloadLine(#"{"event": "something-new"}"#))
    }

    func testFinalEventFallsBackOnTheExitStatus() {
        XCTAssertEqual(
            ModelsBridge.finalEvent(.done(already: true), status: 0, stderr: ""), .done(already: true))
        XCTAssertEqual(
            ModelsBridge.finalEvent(.progress(bytes: 5, total: 5), status: 0, stderr: ""),
            .done(already: false))
        XCTAssertEqual(
            ModelsBridge.finalEvent(
                .progress(bytes: 5, total: 9), status: 1, stderr: "warning\nOSError: disk full\n"),
            .failed("OSError: disk full"))
        XCTAssertEqual(
            ModelsBridge.finalEvent(nil, status: 3, stderr: ""),
            .failed("the download stopped (exit 3)"))
    }

    /// The whole path — a child printing the engine's JSON lines, with
    /// library noise on stderr — through `ModelsBridge.download`.
    func testDownloadStreamsProgressAndReturnsTheFinalEvent() async throws {
        let script = try fakeEngine("""
            echo 'Warning: unauthenticated requests to the HF Hub' >&2
            echo '{"event": "progress", "id": "whisper-base", "bytes": 0, "total": 100}'
            echo '{"event": "progress", "id": "whisper-base", "bytes": 42, "total": 100}'
            echo 'not json'
            echo '{"event": "progress", "id": "whisper-base", "bytes": 100, "total": 100}'
            echo '{"event": "done", "id": "whisper-base", "already": false, "error": null}'
            """)
        let seen = EventLog()
        let final = try await ModelsBridge.download(binary: script, id: "whisper-base") { event in
            seen.append(event)
        }
        XCTAssertEqual(final, .done(already: false))
        XCTAssertEqual(seen.events.count, 4)
        XCTAssertEqual(seen.events[1].fraction, 0.42)
    }

    func testCancellingADownloadStopsTheChild() async throws {
        let script = try fakeEngine("""
            echo '{"event": "progress", "id": "big", "bytes": 1, "total": 100}'
            sleep 30
            echo '{"event": "done", "id": "big", "already": false, "error": null}'
            """)
        let started = Date()
        let task = Task {
            try await ModelsBridge.download(binary: script, id: "big") { _ in }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled download must not report done")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testStreamLinesKeepsStderrApart() async throws {
        let script = try fakeEngine("""
            echo one
            echo noise >&2
            printf 'two\\nthree'
            exit 4
            """)
        let lines = EventLog()
        let result = try await CLIRunner.streamLines(binary: script, arguments: []) { line in
            lines.append(.failed(line))
        }
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(lines.events, [.failed("one"), .failed("two"), .failed("three")])
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "noise")
        XCTAssertTrue(result.stdout.hasPrefix("one\n"))
    }

    // MARK: words

    func testSizes() {
        XCTAssertEqual(ModelWords.size(mb: 1614), "1.6 GB")
        XCTAssertEqual(ModelWords.size(mb: 2508), "2.5 GB")
        XCTAssertEqual(ModelWords.size(mb: 464), "464 MB")
        XCTAssertEqual(ModelWords.size(mb: 74), "74 MB")
        XCTAssertEqual(ModelWords.size(mb: 1000), "1.0 GB")
        XCTAssertEqual(ModelWords.size(mb: 12_400), "12 GB")
    }

    func testLanguagesPhrase() throws {
        XCTAssertEqual(
            ModelWords.languagesPhrase(try Self.model(Self.parakeetV3)),
            "Works out the language · 25 languages")
        XCTAssertEqual(
            ModelWords.languagesPhrase(try Self.model(Self.turbo)),
            "Locks the language you choose · 100 languages")
        XCTAssertEqual(ModelWords.languagesPhrase(try Self.model(Self.english110M)), "English only")
        XCTAssertEqual(
            ModelWords.languagesPhrase(TranscriptionModel(id: "x", pinsLanguage: true)),
            "Locks the language you choose", "no count when the engine gave none")
    }

    func testCoverage() throws {
        let parakeet = try Self.model(Self.parakeetV3)
        let turbo = try Self.model(Self.turbo)
        let english = try Self.model(Self.english110M)
        XCTAssertTrue(parakeet.covers(language: "pt"))
        XCTAssertTrue(parakeet.covers(language: "PT-br"))
        XCTAssertFalse(parakeet.covers(language: "ja"))
        XCTAssertTrue(parakeet.covers(language: ""), "auto-detect is always covered")
        XCTAssertTrue(turbo.covers(language: "ja"), "nil languages = every Whisper language")
        XCTAssertFalse(english.covers(language: "pt"))
        XCTAssertEqual(ModelWords.notCovered(english, code: "pt"), "Doesn't transcribe Portuguese")
        XCTAssertNil(ModelWords.notCovered(english, code: "en"))
        XCTAssertEqual(
            ModelWords.notCovered(
                parakeet, code: "ja",
                names: [LanguageInfo(code: "ja", name: "Japanese (日本語)", parakeet: "unsupported")]),
            "Doesn't transcribe Japanese (日本語)", "the engine's own language names win")
    }

    func testFactsLines() throws {
        let parakeet = try Self.model(Self.parakeetV3)
        let turbo = try Self.model(Self.turbo)
        XCTAssertEqual(ModelWords.speedAndAccuracy(turbo), "Fast · Very good accuracy")
        XCTAssertEqual(
            ModelWords.speedAndAccuracy(TranscriptionModel(id: "m", speed: "moderate", accuracy: "good")),
            "Moderate speed · Good accuracy")
        XCTAssertEqual(
            ModelWords.cardFacts(parakeet), "Works out the language · 25 languages · 2.5 GB · Downloaded")
        XCTAssertEqual(
            ModelWords.cardFacts(turbo),
            "Locks the language you choose · 100 languages · Downloads 1.6 GB the first time")
        XCTAssertEqual(
            ModelWords.rowFacts(parakeet),
            "Works out the language · 25 languages · 2.5 GB · Fastest · Very good accuracy")
        XCTAssertEqual(
            ModelWords.rowFactParts(turbo),
            ["Locks the language you choose", "100 languages", "1.6 GB", "Fast", "Very good accuracy"])
    }

    func testRowNoteDropsWhatTheFactsAlreadySay() throws {
        XCTAssertNil(ModelWords.rowNote(try Self.model(Self.english110M)))
        XCTAssertNil(ModelWords.rowNote(try Self.model(Self.turbo)))
        XCTAssertEqual(
            ModelWords.rowNote(try Self.model(Self.parakeetV3)),
            "Can't be told the language: mixed Portuguese and English can slip into English.")
    }

    func testTryWords() {
        XCTAssertEqual(ModelWords.multiplier(12.8), "12.8×")
        XCTAssertEqual(ModelWords.multiplier(24), "24×")
        XCTAssertEqual(ModelWords.multiplier(121.4), "121×")
        var result = ModelTryResult()
        result.loadSeconds = 2.8
        XCTAssertEqual(ModelWords.tryPieces(result).map(\.text).joined(), "Loads in 2.8s")
        let long = "Bom dia, pessoal, hoje a gente vai revisar o planejamento do trimestre, conferir os "
            + "números da última semana e combinar os próximos passos com o time."
        let cut = ModelWords.excerpt(long)
        XCTAssertLessThanOrEqual(cut.count, 121)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.contains(", …"))
        XCTAssertEqual(ModelWords.excerpt("Short sample."), "Short sample.")
    }

    func testLanguageNoteFollowsTheModel() throws {
        let parakeet = try Self.model(Self.parakeetV3)
        let turbo = try Self.model(Self.turbo)
        let english = try Self.model(Self.english110M)
        XCTAssertEqual(
            ModelWords.languageNote(model: turbo, code: ""),
            "Whisper works out the language of each recording on its own.")
        XCTAssertEqual(
            ModelWords.languageNote(model: turbo, code: "pt"),
            "Whisper transcribes in this language only.")
        XCTAssertEqual(
            ModelWords.languageNote(model: parakeet, code: "pt", lockingChoice: turbo),
            "Parakeet can't be told the language — it works it out as it goes. Huske uses this "
                + "setting to catch stretches that slip into English and redo them. To lock the "
                + "language, change the model to Whisper large-v3 turbo.")
        XCTAssertEqual(
            ModelWords.languageNote(model: parakeet, code: "ja", lockingChoice: turbo),
            "Parakeet doesn't understand Japanese. To transcribe it, change the model to "
                + "Whisper large-v3 turbo.")
        XCTAssertTrue(
            ModelWords.languageNote(model: parakeet, code: "").hasSuffix(
                "To lock the language, change the model to a Whisper model."))
        XCTAssertEqual(
            ModelWords.languageNote(model: english, code: "en"), "This model transcribes English only.")
        XCTAssertEqual(
            ModelWords.languageNote(model: english, code: "pt", lockingChoice: turbo),
            "This model doesn't transcribe Portuguese — it knows English only. To transcribe it, "
                + "change the model to Whisper large-v3 turbo.")
    }

    func testDictionaryNoteFollowsTheModel() throws {
        XCTAssertEqual(
            ModelWords.dictionaryNote(try Self.model(Self.turbo)),
            "One per line, most important first. Whisper also hears these words more readily.")
        XCTAssertEqual(
            ModelWords.dictionaryNote(try Self.model(Self.parakeetV3)),
            "One per line, most important first.")
    }

    func testBaseCode() {
        XCTAssertEqual(ModelWords.baseCode(" pt-BR "), "pt")
        XCTAssertEqual(ModelWords.baseCode("zh_Hans"), "zh")
        XCTAssertEqual(ModelWords.baseCode(""), "")
    }

    // MARK: helpers

    /// An executable shell script standing in for the engine.
    private func fakeEngine(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-fake-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUseRefusalCarriesTheConversionCode() throws {
        let result = try ModelsBridge.parseUse("""
            {"error": "someone/whisper-large-v3-pt is a transformers checkpoint; convert it first: huske models convert someone/whisper-large-v3-pt", "code": "needs_conversion", "repo": "someone/whisper-large-v3-pt"}
            """)
        XCTAssertTrue(result.needsConversion)
        XCTAssertEqual(result.repo, "someone/whisper-large-v3-pt")
        let older = try ModelsBridge.parseUse(#"{"error": "nope"}"#)
        XCTAssertFalse(older.needsConversion)
        XCTAssertNil(older.code)
    }

    func testConvertedPathComesFromTheDoneLine() {
        XCTAssertEqual(
            ModelsBridge.parseConvertedPath(
                #"{"event": "done", "id": "a/b", "path": "/Users/x/huske/models/b", "error": null}"#),
            "/Users/x/huske/models/b")
        XCTAssertNil(ModelsBridge.parseConvertedPath(#"{"event": "progress", "bytes": 1, "total": 2}"#))
        XCTAssertNil(ModelsBridge.parseConvertedPath("not json"))
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ModelDownloadEvent] = []

    func append(_ event: ModelDownloadEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [ModelDownloadEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
