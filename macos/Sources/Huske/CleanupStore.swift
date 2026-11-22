// State behind the "Transcript cleanup" card: what `huske llm` says about the
// configured provider, the models it offers, the result of a test, and the
// key / consent operations. Every answer comes from the engine; this only
// remembers the last one and which call is in flight.

import Foundation
import HuskeKit
import Observation

@MainActor
@Observable
final class CleanupStore {
    private(set) var status: LLMStatus?
    /// The status call itself failed (not "the provider isn't ready").
    private(set) var statusError: String?
    private(set) var checking = false

    private(set) var models: LLMModelList?
    /// Which provider `models` belongs to.
    private(set) var modelsBackend: String?
    private(set) var loadingModels = false

    private(set) var test: LLMTestResult?
    private(set) var testError: String?
    private(set) var testing = false

    private(set) var keyBusy = false
    private(set) var keyError: String?
    private(set) var consentBusy = false
    private(set) var consentError: String?

    private(set) var languages: [LanguageInfo] = []

    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private var modelsGeneration = 0
    @ObservationIgnored private var languagesLoaded = false

    // MARK: status + models

    func refreshStatus(binary: URL?) async {
        guard let binary else { return }
        statusGeneration += 1
        let generation = statusGeneration
        checking = true
        defer { if generation == statusGeneration { checking = false } }
        do {
            let fresh = try await LLMBridge.status(binary: binary)
            guard generation == statusGeneration else { return }
            status = fresh
            statusError = nil
        } catch {
            guard generation == statusGeneration else { return }
            statusError = AppModel.describe(error)
        }
    }

    func refreshModels(binary: URL?, backend: String) async {
        guard let binary else { return }
        modelsGeneration += 1
        let generation = modelsGeneration
        if modelsBackend != backend {
            models = nil
            modelsBackend = backend
        }
        loadingModels = true
        defer { if generation == modelsGeneration { loadingModels = false } }
        let list: LLMModelList
        do {
            list = try await LLMBridge.models(binary: binary, backend: backend)
        } catch {
            list = LLMModelList(backend: backend, error: AppModel.describe(error))
        }
        guard generation == modelsGeneration else { return }
        models = list
        modelsBackend = backend
    }

    /// A different provider was picked: its test result and errors no
    /// longer describe anything on screen.
    func providerChanged() {
        test = nil
        testError = nil
        keyError = nil
        consentError = nil
    }

    // MARK: test

    func runTest(binary: URL?) async {
        guard let binary, !testing else { return }
        testing = true
        testError = nil
        test = nil
        defer { testing = false }
        do {
            let result = try await LLMBridge.test(binary: binary)
            if result.ok {
                test = result
            } else {
                testError = result.error ?? "the sample came back unchanged"
            }
        } catch {
            testError = AppModel.describe(error)
        }
    }

    // MARK: keys

    /// Hand `key` to the engine (stdin → Keychain). Returns whether it was
    /// kept; the caller clears its field either way.
    func saveKey(binary: URL?, provider: String, key: String) async -> Bool {
        guard let binary, !keyBusy else { return false }
        keyBusy = true
        keyError = nil
        defer { keyBusy = false }
        do {
            let result = try await LLMBridge.saveKey(binary: binary, provider: provider, key: key)
            if !result.done {
                keyError = result.error ?? "the Keychain did not keep the key"
            }
            await refreshStatus(binary: binary)
            return result.done
        } catch {
            keyError = AppModel.describe(error)
            return false
        }
    }

    func removeKey(binary: URL?, provider: String) async {
        guard let binary, !keyBusy else { return }
        keyBusy = true
        keyError = nil
        defer { keyBusy = false }
        do {
            let result = try await LLMBridge.removeKey(binary: binary, provider: provider)
            if let error = result.error { keyError = error }
        } catch {
            keyError = AppModel.describe(error)
        }
        await refreshStatus(binary: binary)
    }

    // MARK: consent

    /// Allow (or stop) sending transcripts to the configured provider's
    /// host. The engine writes `distill_cloud_consent` itself, so the config
    /// is reloaded afterwards.
    func setCloudConsent(_ allow: Bool, binary: URL?, config: ConfigStore) async {
        guard let binary, !consentBusy else { return }
        consentBusy = true
        consentError = nil
        defer { consentBusy = false }
        do {
            let result =
                allow
                ? try await LLMBridge.allowCloud(binary: binary)
                : try await LLMBridge.revokeCloud(binary: binary)
            if let error = result.error { consentError = error }
        } catch {
            consentError = AppModel.describe(error)
        }
        await config.reload(binary: binary)
        await refreshStatus(binary: binary)
    }

    // MARK: languages

    func loadLanguagesIfNeeded(binary: URL?, supported: Bool) async {
        guard let binary, supported, !languagesLoaded else { return }
        languagesLoaded = true
        if let list = try? await LLMBridge.languages(binary: binary) {
            languages = list
        } else {
            languagesLoaded = false
        }
    }

    // MARK: render seam

    func _previewInject(
        status: LLMStatus? = nil, models: LLMModelList? = nil, test: LLMTestResult? = nil
    ) {
        if let status { self.status = status }
        if let models {
            self.models = models
            modelsBackend = models.backend
        }
        if let test { self.test = test }
    }
}
