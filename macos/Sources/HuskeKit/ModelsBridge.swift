// Transcription models through `huske models … --json`.
//
// The engine owns the catalog (ADR 0006): which models exist, what each one
// does with the language setting and the dictionary, how big it is, whether it
// is on disk, and which one the config picks. This file decodes its answers,
// runs its commands, and turns the facts into the plain words the
// Configuration pane shows. Decoding is lenient — a field an older or newer
// engine leaves out falls back to a neutral default — and the sentences the
// engine writes (`summary`, `note`, `measured`, `notes`, `error`) are passed
// through verbatim.

import Foundation

/// One transcription model: a catalog entry, or the ad-hoc repo or folder the
/// config names (`inCatalog == false`).
public struct TranscriptionModel: Equatable, Sendable, Identifiable {
    /// Catalog id, or the repo / folder itself for an ad-hoc model.
    public var id: String
    public var name: String
    /// `parakeet`, `whisper`, … — which runtime transcribes with it.
    public var family: String
    public var familyLabel: String
    public var repo: String
    /// What transcripts record in their `model:` frontmatter.
    public var label: String
    public var summary: String
    /// A caveat in one plain sentence; empty when there is none.
    public var note: String
    /// ISO codes it transcribes; nil = every Whisper language.
    public var languages: [String]?
    public var languageCount: Int
    /// The language setting is an input (Whisper) rather than a hint the
    /// model works out for itself (Parakeet).
    public var pinsLanguage: Bool
    /// What the dictionary does here: `prompt` (Whisper hears the words more
    /// readily), `boost` (Parakeet can listen for them), `none`.
    public var dictionary: String
    public var sizeMB: Int?
    /// `fastest`, `fast`, `moderate`, `slow`.
    public var speed: String?
    /// `basic`, `good`, `very good`, `best`.
    public var accuracy: String?
    /// The evidence behind speed and accuracy, as the engine words it.
    public var measured: String?
    public var isDefault: Bool
    public var recommended: Bool
    public var inCatalog: Bool
    public var downloaded: Bool
    public var inUse: Bool
    /// The engine has the runtime this family needs.
    public var runtimeAvailable: Bool

    public init(
        id: String, name: String = "", family: String = "", familyLabel: String = "",
        repo: String = "", label: String = "", summary: String = "", note: String = "",
        languages: [String]? = nil, languageCount: Int = 0, pinsLanguage: Bool = false,
        dictionary: String = "none", sizeMB: Int? = nil, speed: String? = nil,
        accuracy: String? = nil, measured: String? = nil, isDefault: Bool = false,
        recommended: Bool = false, inCatalog: Bool = true, downloaded: Bool = false,
        inUse: Bool = false, runtimeAvailable: Bool = true
    ) {
        self.id = id
        self.name = name.isEmpty ? id : name
        self.family = family
        self.familyLabel = familyLabel.isEmpty ? family.capitalized : familyLabel
        self.repo = repo
        self.label = label
        self.summary = summary
        self.note = note
        self.languages = languages
        self.languageCount = languageCount
        self.pinsLanguage = pinsLanguage
        self.dictionary = dictionary
        self.sizeMB = sizeMB
        self.speed = speed
        self.accuracy = accuracy
        self.measured = measured
        self.isDefault = isDefault
        self.recommended = recommended
        self.inCatalog = inCatalog
        self.downloaded = downloaded
        self.inUse = inUse
        self.runtimeAvailable = runtimeAvailable
    }

    /// Transcribes `code` (a config `language` value). An empty code means
    /// "work it out", which every model does; `languages == nil` means every
    /// Whisper language.
    public func covers(language code: String) -> Bool {
        let code = ModelWords.baseCode(code)
        guard !code.isEmpty, let languages else { return true }
        return languages.contains { $0.lowercased() == code }
    }
}

/// A runtime the engine knows (`families` in `huske models --json`).
public struct ModelFamily: Equatable, Sendable, Identifiable {
    public var name: String
    public var label: String
    public var pinsLanguage: Bool
    public var dictionary: String
    public var available: Bool

    public var id: String { name }

    public init(
        name: String, label: String = "", pinsLanguage: Bool = false,
        dictionary: String = "none", available: Bool = true
    ) {
        self.name = name
        self.label = label.isEmpty ? name.capitalized : label
        self.pinsLanguage = pinsLanguage
        self.dictionary = dictionary
        self.available = available
    }
}

/// `huske models --json`.
public struct ModelCatalog: Equatable, Sendable {
    /// What the config picks; nil only if the engine could not tell.
    public var current: TranscriptionModel?
    /// Catalog order — the engine's, never re-sorted. An ad-hoc current model
    /// comes first.
    public var models: [TranscriptionModel]
    public var families: [ModelFamily]

    public init(
        current: TranscriptionModel? = nil, models: [TranscriptionModel] = [],
        families: [ModelFamily] = []
    ) {
        self.current = current
        self.models = models
        self.families = families
    }

    public func model(id: String) -> TranscriptionModel? {
        models.first { $0.id == id } ?? (current?.id == id ? current : nil)
    }

    /// The model to name when someone needs the language locked: the first
    /// recommended one that locks it, else the first that does.
    public var languageLockingChoice: TranscriptionModel? {
        let locking = models.filter { $0.pinsLanguage && $0.inCatalog }
        return locking.first { $0.recommended } ?? locking.first
    }
}

/// `huske models use … --json`.
public struct ModelUseResult: Equatable, Sendable {
    public var model: TranscriptionModel?
    /// The config keys the engine wrote.
    public var written: [String: JSONValue]
    /// Plain sentences worth showing (first-use download, running session).
    public var notes: [String]
    public var error: String?
    /// Machine reason for a refusal: `needs_conversion` (a transformers
    /// Whisper fine-tune — `huske models convert` can make it loadable) or
    /// `unloadable`. `nil` from older engines.
    public var code: String?
    /// The repo the refusal is about.
    public var repo: String?

    public init(
        model: TranscriptionModel? = nil, written: [String: JSONValue] = [:],
        notes: [String] = [], error: String? = nil, code: String? = nil, repo: String? = nil
    ) {
        self.model = model
        self.written = written
        self.notes = notes
        self.error = error
        self.code = code
        self.repo = repo
    }

    public var needsConversion: Bool { code == "needs_conversion" }
}

/// `huske models try … --json` — a synthetic `say` sample, never a recording.
public struct ModelTryResult: Equatable, Sendable {
    public var ok = false
    public var model: TranscriptionModel?
    public var audioSeconds: Double?
    public var loadSeconds: Double?
    public var seconds: Double?
    /// Audio seconds transcribed per second of work.
    public var xRealtime: Double?
    public var language: String?
    public var synthetic = true
    public var text = ""
    public var error: String?

    public init() {}
}

/// One line of `huske models download … --json`.
public enum ModelDownloadEvent: Equatable, Sendable {
    case progress(bytes: Int64, total: Int64?)
    case done(already: Bool)
    case failed(String)

    /// 0…1 when the total is known.
    public var fraction: Double? {
        guard case .progress(let bytes, let total?) = self, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }
}

public enum ModelsBridgeError: Error, Equatable {
    /// The engine answered something that is not the expected JSON.
    case badOutput(String)
    /// The engine answered with `{"error": …}`; shown verbatim.
    case failed(String)
}

public enum ModelsBridge {
    // MARK: decoding (pure)

    public static func parseCatalog(_ text: String) throws -> ModelCatalog {
        let obj = try LLMBridge.object(from: text)
        if let error = string(obj["error"]), obj["models"] == nil {
            throw ModelsBridgeError.failed(error)
        }
        let models = (obj["models"] as? [[String: Any]])?.compactMap(model(from:)) ?? []
        let families = (obj["families"] as? [[String: Any]])?.compactMap { row -> ModelFamily? in
            guard let name = string(row["name"]) else { return nil }
            return ModelFamily(
                name: name,
                label: string(row["label"]) ?? "",
                pinsLanguage: bool(row["pins_language"]) ?? false,
                dictionary: string(row["dictionary"]) ?? "none",
                available: bool(row["available"]) ?? true)
        } ?? []
        let current = (obj["current"] as? [String: Any]).flatMap(model(from:))
            ?? models.first { $0.inUse }
        return ModelCatalog(current: current, models: models, families: families)
    }

    public static func parseModel(_ text: String) throws -> TranscriptionModel {
        let obj = try LLMBridge.object(from: text)
        if let error = string(obj["error"]), obj["id"] == nil {
            throw ModelsBridgeError.failed(error)
        }
        guard let model = model(from: obj) else {
            throw ModelsBridgeError.badOutput("the engine described no model")
        }
        return model
    }

    public static func parseUse(_ text: String) throws -> ModelUseResult {
        let obj = try LLMBridge.object(from: text)
        return ModelUseResult(
            model: (obj["model"] as? [String: Any]).flatMap(model(from:)),
            written: (obj["written"] as? [String: Any])?.mapValues { JSONValue.from(any: $0) } ?? [:],
            notes: (obj["notes"] as? [Any])?.compactMap { string($0) } ?? [],
            error: string(obj["error"]),
            code: string(obj["code"]),
            repo: string(obj["repo"]))
    }

    /// The folder a finished `models convert --json` stream wrote, if any.
    public static func parseConvertedPath(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              string(obj["event"]) == "done"
        else { return nil }
        return string(obj["path"])
    }

    public static func parseTry(_ text: String) throws -> ModelTryResult {
        let obj = try LLMBridge.object(from: text)
        var result = ModelTryResult()
        result.error = string(obj["error"])
        result.ok = bool(obj["ok"]) ?? (result.error == nil)
        result.model = (obj["model"] as? [String: Any]).flatMap(model(from:))
        result.audioSeconds = double(obj["audio_seconds"])
        result.loadSeconds = double(obj["load_seconds"])
        result.seconds = double(obj["seconds"])
        result.xRealtime = double(obj["x_realtime"])
        result.language = string(obj["language"])
        result.synthetic = bool(obj["synthetic"]) ?? true
        result.text = string(obj["text"]) ?? ""
        return result
    }

    /// One line of the download stream; nil for anything that is not one of
    /// its events (a stray log line must not end the download).
    public static func parseDownloadLine(_ line: String) -> ModelDownloadEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let error = string(obj["error"])
        switch string(obj["event"]) {
        case "progress":
            return .progress(
                bytes: int64(obj["bytes"]) ?? 0,
                total: int64(obj["total"]).flatMap { $0 > 0 ? $0 : nil })
        case "done":
            if let error { return .failed(error) }
            return .done(already: bool(obj["already"]) ?? false)
        case "error":
            return .failed(error ?? "the download failed")
        default:
            // Refused before it started (unknown id): `{"error": …}`, no event.
            return error.map { .failed($0) }
        }
    }

    // MARK: commands

    public static func list(binary: URL) async throws -> ModelCatalog {
        try parseCatalog(try await output(binary, ["models", "--json"], timeout: 60))
    }

    public static func info(binary: URL, id: String) async throws -> TranscriptionModel {
        try parseModel(try await output(binary, ["models", "info", id, "--json"], timeout: 60))
    }

    /// Choose the model (catalog id, Hugging Face repo, or folder). The
    /// engine validates and writes the config; a refusal comes back as
    /// `ModelUseResult.error` in its own words.
    public static func use(binary: URL, id: String) async throws -> ModelUseResult {
        try parseUse(try await output(binary, ["models", "use", id, "--json"], timeout: 60))
    }

    /// Transcribe the engine's synthetic sample with `id`. May download the
    /// model first, so there is no timeout — cancel the task to stop it.
    public static func tryModel(binary: URL, id: String) async throws -> ModelTryResult {
        let result = try await CLIRunner.streamLines(
            binary: binary, arguments: ["models", "try", id, "--json"]) { _ in }
        try Task.checkCancellation()
        return try parseTry(try json(from: result))
    }

    /// Download `id`, reporting each event as it arrives (on a background
    /// queue). Returns the final event: `.done`, or `.failed` with the
    /// engine's words. Cancelling the task stops the download and throws
    /// `CancellationError`; the next attempt resumes where it stopped.
    @discardableResult
    public static func download(
        binary: URL, id: String,
        onEvent: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> ModelDownloadEvent {
        let last = LastEvent()
        let result = try await CLIRunner.streamLines(
            binary: binary, arguments: ["models", "download", id, "--json"]
        ) { line in
            guard let event = parseDownloadLine(line) else { return }
            last.set(event)
            onEvent(event)
        }
        try Task.checkCancellation()
        return finalEvent(last.value, status: result.status, stderr: result.stderr)
    }

    /// Convert a transformers Whisper fine-tune (`huske models convert`),
    /// reporting progress like a download. Returns the converted folder, or
    /// throws `ModelsBridgeError.failed` with the engine's words.
    public static func convert(
        binary: URL, repo: String,
        onEvent: @escaping @Sendable (ModelDownloadEvent) -> Void
    ) async throws -> String {
        let last = LastEvent()
        let path = LastPath()
        let result = try await CLIRunner.streamLines(
            binary: binary, arguments: ["models", "convert", repo, "--json"]
        ) { line in
            if let found = parseConvertedPath(line) { path.set(found) }
            guard let event = parseDownloadLine(line) else { return }
            last.set(event)
            onEvent(event)
        }
        try Task.checkCancellation()
        if let folder = path.value { return folder }
        if case .failed(let message) = finalEvent(last.value, status: result.status, stderr: result.stderr) {
            throw ModelsBridgeError.failed(message)
        }
        throw ModelsBridgeError.failed("the conversion stopped without a result")
    }

    /// What a finished download stream amounts to.
    static func finalEvent(
        _ last: ModelDownloadEvent?, status: Int32, stderr: String
    ) -> ModelDownloadEvent {
        switch last {
        case .done(let already)?:
            return .done(already: already)
        case .failed(let error)?:
            return .failed(error)
        case .progress?, nil:
            if status == 0 { return .done(already: false) }
            let said = stderr.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            return .failed(said ?? "the download stopped (exit \(status))")
        }
    }

    // MARK: helpers

    /// Failures still answer with JSON (`{"error": …}`, exit 2), so the exit
    /// status is not a reason to stop reading.
    private static func output(
        _ binary: URL, _ arguments: [String], timeout: TimeInterval
    ) async throws -> String {
        try json(from: try await CLIRunner.run(binary: binary, arguments: arguments, timeout: timeout))
    }

    private static func json(from result: CLIResult) throws -> String {
        if (try? LLMBridge.object(from: result.stdout)) != nil { return result.stdout }
        let said = (result.stderr + "\n" + result.stdout)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        throw ModelsBridgeError.badOutput(
            said ?? "the engine gave no answer (exit \(result.status))")
    }

    static func model(from obj: [String: Any]) -> TranscriptionModel? {
        guard let id = string(obj["id"]), !id.isEmpty else { return nil }
        let languages = (obj["languages"] as? [Any])?.compactMap { string($0) }
        return TranscriptionModel(
            id: id,
            name: string(obj["name"]) ?? "",
            family: string(obj["family"]) ?? "",
            familyLabel: string(obj["family_label"]) ?? "",
            repo: string(obj["repo"]) ?? id,
            label: string(obj["label"]) ?? "",
            summary: string(obj["summary"]) ?? "",
            note: string(obj["note"]) ?? "",
            languages: languages,
            languageCount: int(obj["language_count"]) ?? languages?.count ?? 0,
            pinsLanguage: bool(obj["pins_language"]) ?? false,
            dictionary: string(obj["dictionary"]) ?? "none",
            sizeMB: int(obj["size_mb"]),
            speed: string(obj["speed"]),
            accuracy: string(obj["accuracy"]),
            measured: string(obj["measured"]).flatMap { $0.isEmpty ? nil : $0 },
            isDefault: bool(obj["default"]) ?? false,
            recommended: bool(obj["recommended"]) ?? false,
            inCatalog: bool(obj["in_catalog"]) ?? true,
            downloaded: bool(obj["downloaded"]) ?? false,
            inUse: bool(obj["in_use"]) ?? false,
            runtimeAvailable: bool(obj["runtime_available"]) ?? true)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func double(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0.rounded()) }
    }

    private static func int64(_ value: Any?) -> Int64? {
        double(value).map { Int64($0) }
    }
}

private final class LastEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var event: ModelDownloadEvent?

    func set(_ value: ModelDownloadEvent) {
        lock.lock()
        event = value
        lock.unlock()
    }

    var value: ModelDownloadEvent? {
        lock.lock()
        defer { lock.unlock() }
        return event
    }
}

private final class LastPath: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?

    func set(_ value: String) {
        lock.lock()
        path = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return path
    }
}

// MARK: - words for the Configuration pane (pure, so they are tested)

public enum ModelWords {
    /// "1.6 GB", "464 MB", "12 GB" — decimal units, like the download itself.
    public static func size(mb: Int) -> String {
        if mb >= 10_000 { return "\(Int((Double(mb) / 1000).rounded())) GB" }
        if mb >= 1000 { return String(format: "%.1f GB", Double(mb) / 1000) }
        return "\(max(mb, 1)) MB"
    }

    /// What the model does with the language setting, and how many it knows:
    /// "Works out the language · 25 languages", "Locks the language you
    /// choose · 100 languages", "English only".
    public static func languagesPhrase(
        _ model: TranscriptionModel, names: [LanguageInfo] = []
    ) -> String {
        if let only = model.languages, only.count == 1 {
            return "\(languageName(only[0], names: names)) only"
        }
        let how = model.pinsLanguage ? "Locks the language you choose" : "Works out the language"
        let count = model.languages?.count ?? model.languageCount
        return count > 1 ? "\(how) · \(count) languages" : how
    }

    /// "Fast · Very good accuracy"; nil when the engine rated neither.
    public static func speedAndAccuracy(_ model: TranscriptionModel) -> String? {
        var parts: [String] = []
        switch model.speed {
        case "fastest": parts.append("Fastest")
        case "fast": parts.append("Fast")
        case "moderate": parts.append("Moderate speed")
        case "slow": parts.append("Slow")
        case let other?: parts.append(sentence(other))
        case nil: break
        }
        if let accuracy = model.accuracy, !accuracy.isEmpty {
            parts.append(sentence(accuracy) + " accuracy")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Downloaded", "Downloads 1.6 GB the first time".
    public static func downloadPhrase(_ model: TranscriptionModel) -> String {
        if model.downloaded { return "Downloaded" }
        if let mb = model.sizeMB { return "Downloads \(size(mb: mb)) the first time" }
        return "Downloads the first time it's used"
    }

    /// The facts line under the chosen model on the Transcription card.
    public static func cardFacts(
        _ model: TranscriptionModel, names: [LanguageInfo] = []
    ) -> String {
        var parts = [languagesPhrase(model, names: names)]
        if model.downloaded, let mb = model.sizeMB { parts.append(size(mb: mb)) }
        parts.append(downloadPhrase(model))
        return parts.joined(separator: " · ")
    }

    /// The facts line of a row in the model picker.
    public static func rowFacts(
        _ model: TranscriptionModel, names: [LanguageInfo] = []
    ) -> String {
        rowFactParts(model, names: names).joined(separator: " · ")
    }

    /// The same facts as separate phrases, so a narrow line can wrap between
    /// them instead of inside one ("Very / good accuracy").
    public static func rowFactParts(
        _ model: TranscriptionModel, names: [LanguageInfo] = []
    ) -> [String] {
        var parts: [String] = []
        // A repo from outside the catalog: say which runtime it runs on.
        if !model.inCatalog, !model.familyLabel.isEmpty {
            parts.append("\(model.familyLabel) model")
        }
        parts += languagesPhrase(model, names: names).components(separatedBy: " · ")
        if let mb = model.sizeMB { parts.append(size(mb: mb)) }
        if let rating = speedAndAccuracy(model) {
            parts += rating.components(separatedBy: " · ")
        }
        return parts
    }

    /// The engine's caveat, unless it only repeats the facts line
    /// ("English only." beside "English only").
    public static func rowNote(_ model: TranscriptionModel, names: [LanguageInfo] = []) -> String? {
        let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        let bare = note.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let facts = rowFactParts(model, names: names).map { $0.lowercased() }
        return facts.contains(bare) ? nil : note
    }

    /// "Doesn't transcribe Portuguese"; nil when `code` is covered.
    public static func notCovered(
        _ model: TranscriptionModel, code: String, names: [LanguageInfo] = []
    ) -> String? {
        guard !model.covers(language: code) else { return nil }
        return "Doesn't transcribe \(languageName(code, names: names))"
    }

    /// "12.8× real time · loads in 2.8s" — pieces kept apart so the numbers
    /// can be set in mono.
    public static func tryPieces(_ result: ModelTryResult) -> [(text: String, number: Bool)] {
        var pieces: [(String, Bool)] = []
        if let x = result.xRealtime {
            pieces.append((multiplier(x), true))
            pieces.append((" real time", false))
        }
        if let load = result.loadSeconds {
            pieces.append((pieces.isEmpty ? "Loads in " : " · loads in ", false))
            pieces.append((CleanupWords.seconds(load), true))
        }
        return pieces
    }

    /// "12.8×", "121×", "24×".
    public static func multiplier(_ value: Double) -> String {
        if value >= 100 || value == value.rounded() { return "\(Int(value.rounded()))×" }
        return String(format: "%.1f×", value)
    }

    /// The first ~`limit` characters of a sample, cut at a word.
    public static func excerpt(_ text: String, limit: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.")) + "…"
    }

    /// The line under the Language picker, from what the chosen model does
    /// with the setting. `lockingChoice` names a model that locks the
    /// language, for the models that can't.
    public static func languageNote(
        model: TranscriptionModel, code rawCode: String, names: [LanguageInfo] = [],
        lockingChoice: TranscriptionModel? = nil
    ) -> String {
        let code = baseCode(rawCode)
        let family = model.familyLabel.isEmpty ? "This model" : model.familyLabel
        let lockTarget = lockingChoice.map { $0.name } ?? "a Whisper model"
        if let only = model.languages, only.count == 1 {
            let onlyName = languageName(only[0], names: names)
            if code.isEmpty || model.covers(language: code) {
                return "This model transcribes \(onlyName) only."
            }
            return "This model doesn't transcribe \(languageName(code, names: names)) — it knows "
                + "\(onlyName) only. To transcribe it, change the model to \(lockTarget)."
        }
        if model.pinsLanguage {
            if code.isEmpty {
                return "\(family) works out the language of each recording on its own."
            }
            if !model.covers(language: code) {
                return "\(model.name) doesn't transcribe \(languageName(code, names: names))."
            }
            return "\(family) transcribes in this language only."
        }
        let lock = "To lock the language, change the model to \(lockTarget)."
        guard !code.isEmpty else {
            return "\(family) works out the language as it goes. Choose one here to catch "
                + "stretches that slip into English. \(lock)"
        }
        if !model.covers(language: code) {
            return "\(family) doesn't understand \(languageName(code, names: names)). To transcribe "
                + "it, change the model to \(lockTarget)."
        }
        if code == "en" {
            return "\(family) can't be told the language — it works it out as it goes. \(lock)"
        }
        return "\(family) can't be told the language — it works it out as it goes. Huske uses "
            + "this setting to catch stretches that slip into English and redo them. \(lock)"
    }

    /// The Dictionary card's line under the word list.
    public static func dictionaryNote(_ model: TranscriptionModel) -> String {
        guard model.dictionary == "prompt" else { return "One per line, most important first." }
        let family = model.familyLabel.isEmpty ? "This model" : model.familyLabel
        return "One per line, most important first. \(family) also hears these words more readily."
    }

    /// The language name for a config code: the engine's own list first.
    public static func languageName(_ code: String, names: [LanguageInfo] = []) -> String {
        let base = baseCode(code)
        if let known = names.first(where: { $0.code == base }) { return known.name }
        return Locale(identifier: "en").localizedString(forLanguageCode: base) ?? code
    }

    /// "pt-BR" → "pt"; trims and lower-cases.
    public static func baseCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    static func sentence(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
