// State behind the Transcription card's model row and the "Transcription
// model" sheet: the catalog `huske models` reports, downloads in flight, Try
// results, and refusals. Every answer comes from the engine; this
// only remembers the last one and which call is running. It lives on the
// AppModel, so a download keeps going after the sheet is closed.

import Foundation
import HuskeKit
import Observation

@MainActor
@Observable
final class ModelsStore {
    private(set) var catalog: ModelCatalog?
    /// The list call itself failed.
    private(set) var loadError: String?
    private(set) var loading = false

    struct Download: Equatable {
        var bytes: Int64 = 0
        var total: Int64?

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, max(0, Double(bytes) / Double(total)))
        }
    }

    /// Downloads in flight, by model id.
    private(set) var downloads: [String: Download] = [:]
    private(set) var downloadErrors: [String: String] = [:]

    /// The model a Try is running for (one at a time: each loads a model).
    private(set) var trying: String?
    private(set) var tries: [String: ModelTryResult] = [:]
    private(set) var tryErrors: [String: String] = [:]

    /// The id or repo a `models use` is running for.
    private(set) var choosing: String?
    /// A refusal for a catalog row, by id.
    private(set) var useErrors: [String: String] = [:]
    /// A refusal for the "Another model" field, verbatim.
    private(set) var customError: String?

    /// A repo `models use` refused because it is a transformers Whisper
    /// fine-tune — `huske models convert` can make it loadable.
    private(set) var convertible: String?
    /// Progress of a running conversion (nil when none).
    private(set) var conversion: Download?
    private(set) var conversionError: String?
    @ObservationIgnored private var conversionTask: Task<Void, Never>?

    /// What is typed in the "Another model" field.
    var customDraft = ""
    var pickerVisible = false

    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tryTask: Task<Void, Never>?

    var current: TranscriptionModel? { catalog?.current }

    // MARK: list

    func refresh(binary: URL?) async {
        guard let binary else { return }
        listGeneration += 1
        let generation = listGeneration
        loading = true
        defer { if generation == listGeneration { loading = false } }
        do {
            let fresh = try await ModelsBridge.list(binary: binary)
            guard generation == listGeneration else { return }
            catalog = fresh
            loadError = nil
        } catch {
            guard generation == listGeneration else { return }
            loadError = AppModel.describe(error)
        }
    }

    // MARK: use

    /// Choose a model; the engine writes the config itself, so the config is
    /// reloaded afterwards. Returns whether it was accepted.
    @discardableResult
    func use(_ id: String, custom: Bool = false, binary: URL?, config: ConfigStore) async -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let binary, !id.isEmpty, choosing == nil else { return false }
        choosing = id
        if custom {
            customError = nil
            convertible = nil
            conversionError = nil
        } else {
            useErrors[id] = nil
        }
        defer { choosing = nil }
        var accepted = false
        do {
            let result = try await ModelsBridge.use(binary: binary, id: id)
            if let error = result.error {
                record(useError: error, for: id, custom: custom)
                if custom, result.needsConversion { convertible = result.repo ?? id }
            } else {
                accepted = true
                if custom { customDraft = "" }
            }
        } catch {
            record(useError: AppModel.describe(error), for: id, custom: custom)
        }
        if accepted {
            await config.reload(binary: binary)
            await refresh(binary: binary)
        }
        return accepted
    }

    private func record(useError error: String, for id: String, custom: Bool) {
        if custom { customError = error } else { useErrors[id] = error }
    }

    // MARK: convert

    /// Convert the refused fine-tune once, then choose the converted folder.
    func convertAndUse(binary: URL?, config: ConfigStore) {
        guard let binary, let repo = convertible, conversionTask == nil else { return }
        conversion = Download()
        conversionError = nil
        conversionTask = Task {
            do {
                let folder = try await ModelsBridge.convert(binary: binary, repo: repo) { event in
                    guard case .progress(let bytes, let total) = event else { return }
                    Task { @MainActor in
                        guard self.conversion != nil else { return }
                        self.conversion = Download(bytes: bytes, total: total)
                    }
                }
                self.conversion = nil
                self.conversionTask = nil
                self.convertible = nil
                self.customError = nil
                await self.use(folder, custom: true, binary: binary, config: config)
                return
            } catch is CancellationError {
                // Stopped on request.
            } catch {
                self.conversionError = AppModel.describe(error)
            }
            self.conversion = nil
            self.conversionTask = nil
        }
    }

    func cancelConversion() {
        conversionTask?.cancel()
    }

    // MARK: download

    func download(_ id: String, binary: URL?) {
        guard let binary, downloadTasks[id] == nil else { return }
        downloads[id] = Download()
        downloadErrors[id] = nil
        downloadTasks[id] = Task {
            do {
                let final = try await ModelsBridge.download(binary: binary, id: id) { event in
                    guard case .progress(let bytes, let total) = event else { return }
                    Task { @MainActor in
                        guard self.downloads[id] != nil else { return }
                        self.downloads[id] = Download(bytes: bytes, total: total)
                    }
                }
                if case .failed(let message) = final {
                    self.downloadErrors[id] = CleanupWords.sentence(message)
                }
            } catch is CancellationError {
                // Stopped on request: nothing to report.
            } catch {
                self.downloadErrors[id] = AppModel.describe(error)
            }
            self.downloads[id] = nil
            self.downloadTasks[id] = nil
            await self.refresh(binary: binary)
        }
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    // MARK: try

    func tryModel(_ id: String, binary: URL?) {
        guard let binary, trying == nil else { return }
        trying = id
        tries[id] = nil
        tryErrors[id] = nil
        tryTask = Task {
            do {
                let result = try await ModelsBridge.tryModel(binary: binary, id: id)
                if result.ok {
                    self.tries[id] = result
                } else {
                    self.tryErrors[id] = CleanupWords.sentence(
                        result.error ?? "the sample came back empty")
                }
            } catch is CancellationError {
            } catch {
                self.tryErrors[id] = AppModel.describe(error)
            }
            self.trying = nil
            self.tryTask = nil
            // A Try may have downloaded the model on the way.
            await self.refresh(binary: binary)
        }
    }

    func cancelTry() {
        tryTask?.cancel()
    }

    // MARK: render seam

    func _previewInject(
        catalog: ModelCatalog? = nil,
        downloads: [String: Download] = [:],
        tries: [String: ModelTryResult] = [:],
        customDraft: String? = nil,
        customError: String? = nil
    ) {
        if let catalog { self.catalog = catalog }
        self.downloads.merge(downloads) { $1 }
        self.tries.merge(tries) { $1 }
        if let customDraft { self.customDraft = customDraft }
        if let customError { self.customError = customError }
    }
}
