// Copyright © 2026 Apple Inc.

#if FoundationModelsIntegration
// `_version: 2` gates on the FoundationModels *framework* major version, which
// is 1.4.x on the macOS/iOS 26 SDK and 2.0.x on 27. The third-party-model
// surface this adapter uses (`LanguageModel`, `LanguageModelCapabilities`, the
// generic `LanguageModelSession(model:)` init) only exists on the 27 SDK, so
// this excludes the whole adapter from older SDKs where those symbols are
// absent. A plain `canImport(FoundationModels)` is insufficient — the module
// also ships in 26 — and `@available` cannot help, since it gates runtime
// availability, not the compile-time presence of a symbol in the SDK.
#if canImport(FoundationModels, _version: 2)

import Foundation
import FoundationModels
import MLXLMCommon
import MLX
import os.log
import MLXGuidedGeneration

// MARK: - Constraint Cache Kind

/// Selects which xgrammar constructor a cached template was compiled
/// with. Used by the constraint cache so a JSON-schema source and a
/// structural-tag source can never alias even if their text collides.
enum ConstraintKind {
    case json
    case structuralTag
}

// MARK: - Tokenizer Bias Cache Entry

/// Tokenizer-derived logit biases, cached per model. Both arrays are pure
/// functions of the tokenizer, so they are identical for a model's lifetime.
/// `@unchecked Sendable`: every field is `let` and read-only after construction
/// (the arrays are only *added* to logits in `GuidedGenerationLoop`, never
/// mutated), and the entry is shared across actors via
/// `DerivedArtifactCache`, following the same pattern as
/// `GrammarTokenizer`/`GrammarConstraint` in `XGrammarBridge.swift`.
final class TokenizerBias: @unchecked Sendable {
    let closing: MLXArray
    let whitespace: MLXArray
    let whitespaceTokenIDs: Set<Int>

    init(closing: MLXArray, whitespace: MLXArray, whitespaceTokenIDs: Set<Int>) {
        self.closing = closing
        self.whitespace = whitespace
        self.whitespaceTokenIDs = whitespaceTokenIDs
    }
}

// MARK: - Deferred Model Cache Actor

/// Thread-safe model cache using Swift actor isolation.
/// Prevents race conditions when multiple concurrent requests try to load the model.
/// Supports caching multiple models by their identifiers.
private actor DeferredModelCache {
    /// Class wrapper around `Task` so actor-reentrancy supersession guards can
    /// use `===` identity comparison. `Task` is a value type; a wrapper lets us
    /// detect whether `evictAll()` replaced a loading entry mid-flight.
    private final class LoadTask {
        let task: Task<ModelContainer, Error>
        init(_ task: Task<ModelContainer, Error>) { self.task = task }
    }

    private var containers: [String: ModelContainer] = [:]
    private var loadingTasks: [String: LoadTask] = [:]
    /// In-flight loads tagged as a warmup of an already-present model, which
    /// must NOT surface as `.downloading` (there is no user-facing download).
    /// A subset of `loadingTasks`' keys. See `load` and `isDownloading`.
    private var suppressedLoadIDs: Set<String> = []
    /// Most recent load error per model. Cleared on a subsequent successful
    /// load. Surfaced through `MLXLanguageModel.availability` so callers can
    /// distinguish "never tried" from "tried and failed".
    private var lastErrors: [String: any Error] = [:]
    private var mutationGeneration = 0

    /// Gets the cached model container for the given model ID, loading it if necessary.
    /// Concurrent callers for the same model will share the same loading task, preventing duplicate loads.
    ///
    /// The `loader` closure carries the transport types (downloader, tokenizer
    /// loader). Keeping them out of the cache means the cache itself stays
    /// agnostic of how a container is acquired -- first caller wins; later
    /// callers reuse the cached container regardless of which loader they
    /// brought along.
    func load(
        modelID: String,
        suppressDownloadingState: Bool = false,
        loader: @Sendable @escaping () async throws -> ModelContainer
    ) async throws -> ModelContainer {
        if let cached = containers[modelID] {
            return cached
        }

        if let existingLoadTask = loadingTasks[modelID] {
            // Coalesced onto an in-flight load: the first caller's
            // classification (downloading vs. suppressed) stands — we do not
            // re-tag. This collision is benign because the suppress decision is
            // conditioned on disk-presence: a warmup and a genuine download for
            // a not-yet-present model both classify as downloading, so they
            // agree; when the model IS present, `availability` resolves to
            // `.available` regardless of the in-flight load.
            return try await existingLoadTask.task.value
        }

        let loadTask = LoadTask(
            Task<ModelContainer, Error> {
                try await loader()
            })
        loadingTasks[modelID] = loadTask
        // Tag a warmup-of-an-already-present model out of the `.downloading`
        // signal (computed by the caller as warmup AND modelExistsOnDisk()).
        if suppressDownloadingState {
            suppressedLoadIDs.insert(modelID)
        }

        do {
            let loaded = try await loadTask.task.value
            // Supersession guard: `evict()`/`evictAll()` may have removed this
            // load while it was suspended (actor reentrancy). If we are no longer
            // the registered task, hand the awaiter its container but do NOT
            // re-populate the cache — ARC frees the weights when the awaiter
            // releases it.
            guard loadingTasks[modelID] === loadTask else { return loaded }
            containers[modelID] = loaded
            loadingTasks[modelID] = nil
            suppressedLoadIDs.remove(modelID)
            lastErrors[modelID] = nil
            return loaded
        } catch {
            // Same guard on the failure path: a superseded load must not re-add a
            // stale lastErrors entry for a model nobody holds.
            if loadingTasks[modelID] === loadTask {
                loadingTasks[modelID] = nil
                suppressedLoadIDs.remove(modelID)
                lastErrors[modelID] = error
            }
            throw error
        }
    }

    /// Whether a *genuine download* is in flight for the given model: a load
    /// task is running and it was not tagged as a warmup of an already-present
    /// model. Drives `availability`'s `.downloading` state, so a background
    /// warmup of an already-downloaded model does not spuriously report
    /// `.downloading`. (A warmup that triggers a real fetch is not tagged and
    /// does report here.)
    func isDownloading(modelID: String) -> Bool {
        loadingTasks[modelID] != nil && !suppressedLoadIDs.contains(modelID)
    }

    /// The most recent load error for the given model, if a previous attempt
    /// failed and no successful load has happened since.
    func lastError(modelID: String) -> (any Error)? {
        lastErrors[modelID]
    }

    /// Evicts only deferred container state. No GPU-stream synchronization
    /// is required — in-flight callers retain their own `ModelContainer` and
    /// free it via ARC on completion.
    func evictAll() {
        mutationGeneration += 1
        containers.removeAll()
        loadingTasks.removeAll()
        suppressedLoadIDs.removeAll()
        lastErrors.removeAll()
    }

    /// Evicts a single deferred model's container, last error, suppressed-load
    /// tag, and any in-flight load registration.
    /// Best-effort cancels an in-flight load (the load path is not
    /// cancellation-aware today, so this is a no-op safety net); the
    /// load-completion guard in `load()` is what prevents a superseded load
    /// from re-populating after removal.
    func remove(modelID: String) {
        mutationGeneration += 1
        // `loadingTasks` holds a `LoadTask` box; cancel the wrapped `Task`.
        loadingTasks[modelID]?.task.cancel()
        loadingTasks.removeValue(forKey: modelID)
        suppressedLoadIDs.remove(modelID)
        containers.removeValue(forKey: modelID)
        lastErrors.removeValue(forKey: modelID)
    }

    func currentMutationGeneration() -> Int { mutationGeneration }
}

// MARK: - Derived Artifact Cache Actor

/// Instance-bound grammar and tokenizer artifacts. This actor deliberately
/// contains no containers, load tasks, paths, loaders, downloads, or errors.
private actor DerivedArtifactCache {
    nonisolated let identity = UUID()
    private var xgTokenizers: [String: GrammarTokenizer] = [:]
    private var constraintTemplates: [String: GrammarConstraint] = [:]
    private var tokenizerBiases: [String: TokenizerBias] = [:]

    func makeXGTokenizer(modelID: String, tokenizer: any Tokenizer) throws -> GrammarTokenizer {
        if let cached = xgTokenizers[modelID] { return cached }
        let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
        let grammarTokenizer = try GrammarTokenizer(
            vocab: vocab.vocab,
            vocabType: vocab.vocabType,
            eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
        xgTokenizers[modelID] = grammarTokenizer
        return grammarTokenizer
    }

    func makeTokenizerBias(modelID: String, tokenizer: any Tokenizer) -> TokenizerBias {
        if let cached = tokenizerBiases[modelID] { return cached }
        let (whitespace, whitespaceTokenIDs) = WhitespaceTokenBias.compute(tokenizer: tokenizer)
        let bias = TokenizerBias(
            closing: ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId),
            whitespace: whitespace,
            whitespaceTokenIDs: whitespaceTokenIDs)
        tokenizerBiases[modelID] = bias
        return bias
    }

    func makeConstraint(
        modelID: String, kind: ConstraintKind, source: String,
        tokenizer: GrammarTokenizer, hostTokenizer: any Tokenizer, fastForward: Bool
    ) throws -> GrammarConstraint {
        let key = "\(modelID):\(kind):\(source)"
        if let template = constraintTemplates[key] {
            do { return try template.clone() }
            catch GrammarError.forkFailed { constraintTemplates.removeValue(forKey: key) }
        }
        let constraint: GrammarConstraint
        switch kind {
        case .json:
            constraint = try GrammarConstraint(
                tokenizer: tokenizer, jsonSchema: source, fastForward: fastForward,
                hostTokenizer: hostTokenizer)
        case .structuralTag:
            constraint = try GrammarConstraint(
                tokenizer: tokenizer, structuralTag: source, fastForward: fastForward,
                hostTokenizer: hostTokenizer)
        }
        if let clone = try? constraint.clone() {
            constraintTemplates[key] = constraint
            return clone
        }
        return constraint
    }

    func remove(modelID: String) {
        xgTokenizers.removeValue(forKey: modelID)
        constraintTemplates = constraintTemplates.filter { !$0.key.hasPrefix("\(modelID):") }
        tokenizerBiases.removeValue(forKey: modelID)
    }

    func removeAll() {
        xgTokenizers.removeAll()
        constraintTemplates.removeAll()
        tokenizerBiases.removeAll()
    }
}

// MARK: - MLXLanguageModel

/// A language model implementation that uses MLX for local inference.
///
/// Conforms to the FoundationModels `LanguageModel` protocol, allowing MLX models
/// to be used with `LanguageModelSession`.
///
/// Example usage:
/// ```swift
/// import StenoMLXFoundationModels
/// import MLXHuggingFace
/// import MLXLMCommon
/// import HuggingFace
/// import Tokenizers
///
/// let model = MLXLanguageModel(
///     configuration: ModelConfiguration(id: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
///     capabilities: [.guidedGeneration, .toolCalling],
///     weightsLocation: { id in
///         // Resolve against the same HubClient cache the loader below downloads
///         // into, so the availability checks see the downloaded weights.
///         let cache = HubCache.default
///         guard let repo = Repo.ID(rawValue: id) else { return cache.cacheDirectory }
///         if let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
///             let snapshot = try? cache.snapshotPath(
///                 repo: repo, kind: .model, commitHash: commit)
///         {
///             return snapshot
///         }
///         return cache.repoDirectory(repo: repo, kind: .model)
///     },
///     load: { configuration, progressHandler in
///         try await loadModelContainer(
///             from: #hubDownloader(),
///             using: #huggingFaceTokenizerLoader(),
///             configuration: configuration,
///             progressHandler: progressHandler)
///     })
/// let session = LanguageModelSession(model: model, tools: [], instructions: nil)
/// let response = try await session.respond(to: "Hello!")
/// print(response.content)
/// ```
///
/// **Factory registration**: this target deliberately does not depend on
/// `MLXLLM`. Consumers who want LLM inference must import `MLXLLM` (or another
/// factory provider) in their own target so that
/// `MLXLLM.TrampolineModelFactory` is linked into the binary; otherwise
/// `loadModelContainer` fails with `noModelFactoryAvailable`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct MLXLanguageModel: FoundationModels.LanguageModel, Sendable {

    private struct StoredContainerSnapshot: Sendable {
        let configuration: ModelConfiguration
        let tokenizer: any Tokenizer
    }

    /// The mutually exclusive generation paths selected for one request.
    /// Kept internal so routing and vendored protocol support are model-free
    /// testable without constructing an inference request.
    enum GenerationRoute: Equatable, Sendable {
        case allowedTools
        case requiredTools
        case schema
        case reasoning
        case plain
    }

    /// A stored container must have exactly the adapter configuration supplied
    /// by the caller. The package-local activation factory remains responsible
    /// for proving that its verified model-type and config bytes produced the
    /// loaded weights.
    package enum StoredContainerInitializationError: Error, Equatable, Sendable {
        case containerConfigurationMismatch
    }

    /// Framed response protocols rely on MLXLMCommon package-only APIs and
    /// are intentionally not enabled by this locally vendored Gemma adapter.
    public enum UnsupportedProtocolError: Error, Equatable, Sendable {
        case framedToolProtocol(ToolCallFormat)
    }

    /// The two supported ownership models for a container.
    ///
    /// The deferred form is the upstream compatibility surface. The stored
    /// form deliberately owns a container supplied by the caller. It never
    /// consults the process-global cache or a path/loader closure.
    private enum ContainerSource: Sendable {
        case deferred(
            weightsLocation: @Sendable (String) -> URL,
            load: ContainerLoader
        )
        case stored(
            container: ModelContainer,
            descriptor: ModelDescriptor,
            derivedCache: DerivedArtifactCache
        )
    }

    // MARK: - Model Caching (CRITICAL for performance)

    /// Shared model cache - thread-safe via actor isolation.
    /// Without caching, model loading takes 2-30 seconds per request.
    private static let deferredModelCache = DeferredModelCache()
    private static let deferredDerivedArtifactCache = DerivedArtifactCache()

    /// The configuration identifying and parameterizing the model to load.
    public let configuration: ModelConfiguration

    /// Resolves a model identifier to its on-disk weights directory for the
    /// deferred compatibility initializer.
    ///
    /// A stored-container model has no weights location and returns `nil`.
    public var weightsLocation: (@Sendable (String) -> URL)? {
        guard case .deferred(let weightsLocation, _) = source else {
            return nil
        }
        return weightsLocation
    }

    /// Loads the model container for a configuration, forwarding download
    /// progress. Injected so this module carries no HuggingFace or
    /// swift-transformers dependency; the HuggingFace wiring lives in callers.
    public typealias ContainerLoader =
        @Sendable (
            _ configuration: ModelConfiguration,
            _ progressHandler: @Sendable @escaping (Progress) -> Void
        ) async throws -> ModelContainer

    private let source: ContainerSource

    /// The immutable descriptor supplied with a stored container, if any.
    /// Internal for focused model-free verification; response generation uses
    /// this exact value instead of reopening `config.json`.
    var storedDescriptor: ModelDescriptor? {
        guard case .stored(_, let descriptor, _) = source else { return nil }
        return descriptor
    }

    var hasStoredContainer: Bool {
        if case .stored = source { return true }
        return false
    }

    /// Stored models own a private derived-data cache for tokenizer, grammar,
    /// and bias artifacts. It cannot collide with another adapter instance that
    /// happens to share the same public model identifier.
    private var derivedCache: DerivedArtifactCache {
        switch source {
        case .deferred:
            Self.deferredDerivedArtifactCache
        case .stored(_, _, let derivedCache):
            derivedCache
        }
    }

    /// Internal structural seams for the model-free adapter tests.
    var storedDerivedArtifactCacheIdentity: UUID? {
        guard case .stored(_, _, let cache) = source else { return nil }
        return cache.identity
    }

    var usesDeferredModelCache: Bool {
        if case .deferred = source { return true }
        return false
    }

    var shouldConfigureGPUCacheOnLoad: Bool { usesDeferredModelCache }
    var shouldScheduleFrameworkPrewarm: Bool { !hasStoredContainer }

    static func deferredCacheMutationGeneration() async -> Int {
        await deferredModelCache.currentMutationGeneration()
    }

    /// Stable identity for the model cache, executor configuration, tokenizer
    /// caches, availability, and progress reporting. Derived from the
    /// configuration so it is the single place identity is defined.
    public var modelID: String { configuration.name }

    /// Loads the model container for this model. Deferred models reuse the
    /// process-global deferred cache; stored models return the exact
    /// caller-supplied container without entering that cache.
    public func loadContainer() async throws -> ModelContainer {
        try await loadContainer(suppressDownloadingState: false)
    }

    /// Internal variant that keeps an in-flight load of an already-present
    /// model out of the `.downloading` availability signal.
    func loadContainer(suppressDownloadingState: Bool) async throws -> ModelContainer {
        switch source {
        case .stored(let container, _, _):
            return container
        case .deferred(_, let load):
            return try await Self.deferredModelCache.load(
                modelID: modelID,
                suppressDownloadingState: suppressDownloadingState,
                loader: makeContainerLoader(load: load))
        }
    }

    /// Sets the process-global MLX buffer-reuse pool limit a single time. A
    /// `static let` initializer runs lazily and exactly once (thread-safe), so
    /// repeated model loads don't re-stomp a consumer's own `Memory.cacheLimit`.
    ///
    /// Higher = less allocator thrash at the cost of slightly higher resident GPU
    /// memory. 256MB comfortably holds activations and KV cache for a 3B model
    /// without forcing pool evictions mid-forward-pass.
    private static let configureGPUCacheOnce: Void = {
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }()

    private func makeContainerLoader(
        load: @escaping ContainerLoader
    ) -> @Sendable () async throws -> ModelContainer {
        let configuration = self.configuration
        return {
            // Configure the buffer pool once per process rather than on every
            // load, so a consumer's own `Memory.cacheLimit` survives our loads.
            _ = Self.configureGPUCacheOnce
            let container = try await load(configuration) { progress in
                MLXDownloadProgress.report(progress: progress, modelID: configuration.name)
            }
            MLXDownloadProgress.reportCompleted()
            return container
        }
    }

    /// Gets or creates a cached GrammarTokenizer for the given model.
    private static func makeXGTokenizer(
        cache: DerivedArtifactCache,
        modelID: String,
        tokenizer: any Tokenizer
    ) async throws -> GrammarTokenizer {
        try await cache.makeXGTokenizer(modelID: modelID, tokenizer: tokenizer)
    }

    /// Gets the cached per-model tokenizer-derived logit biases (closing +
    /// whitespace), computing them on first use.
    private static func makeTokenizerBias(
        cache: DerivedArtifactCache,
        modelID: String,
        tokenizer: any Tokenizer
    ) async -> TokenizerBias {
        await cache.makeTokenizerBias(modelID: modelID, tokenizer: tokenizer)
    }

    /// Gets a constraint by cloning a cached compiled template (or compiling one first).
    private static func makeConstraint(
        cache: DerivedArtifactCache,
        modelID: String,
        kind: ConstraintKind,
        source: String,
        tokenizer: GrammarTokenizer,
        hostTokenizer: any Tokenizer,
        fastForward: Bool
    ) async throws -> GrammarConstraint {
        try await cache.makeConstraint(
            modelID: modelID,
            kind: kind,
            source: source,
            tokenizer: tokenizer,
            hostTokenizer: hostTokenizer,
            fastForward: fastForward
        )
    }

    /// Evicts every deferred model and its shared derived artifacts.
    /// Stored containers and their instance-bound artifacts are unaffected.
    ///
    /// Safe to call during in-flight `respond()`/`warmUp()` work: each holds its
    /// own strong reference to the `ModelContainer` and synchronizes the GPU on
    /// exit, so dropping the cache's reference cannot free weights out from under
    /// a live kernel — the weights free via ARC once that work returns.
    public static func evictAll() async {
        await deferredModelCache.evictAll()
        await deferredDerivedArtifactCache.removeAll()
    }

    /// Evicts deferred model state, freeing the cached GPU weights. A subsequent
    /// deferred `respond()`/`preload()` triggers a fresh load (reusing the
    /// on-disk snapshot if the model was previously downloaded). For stored
    /// models this only clears instance-bound derived artifacts; the caller's
    /// container remains retained.
    ///
    /// Safe to call during an in-flight `respond()`: that call retains its own
    /// `ModelContainer` and finishes normally; the weights free via ARC once it
    /// returns. Evicting a model whose load is still in flight removes it cleanly
    /// — the in-flight load completes but does not re-populate the cache.
    public func evict() async {
        switch source {
        case .deferred:
            await Self.deferredModelCache.remove(modelID: modelID)
            await Self.deferredDerivedArtifactCache.remove(modelID: modelID)
        case .stored(_, _, let derivedCache):
            // Only derived tokenizer/grammar artifacts are released. The
            // caller-owned stored container remains strongly held by `source`.
            await derivedCache.remove(modelID: modelID)
        }
    }

    /// Whether the shared cache has a *genuine download* in flight for the
    /// given model — excludes a warmup of an already-present model. Used by
    /// ``availability`` to surface a `.downloading` state.
    static func isDownloadingInCache(modelID: String) async -> Bool {
        await deferredModelCache.isDownloading(modelID: modelID)
    }

    /// The most recent load error for the given model, if any. Cleared on a
    /// subsequent successful load. Used by ``availability`` to surface a
    /// `.downloadFailed` state after a failed ``preload()``.
    static func lastLoadErrorInCache(modelID: String) async -> (any Error)? {
        await deferredModelCache.lastError(modelID: modelID)
    }

    // MARK: - LanguageModel Conformance

    /// MLX supports guided generation via xgrammar grammar-constrained
    /// decoding (provided by the MLXGuidedGeneration library), native
    /// `.allowed` tool routing, guided `.required` developer tool calls,
    /// and reasoning (chain-of-thought) routing.
    ///
    /// Capabilities are declared explicitly by the caller at ``init(configuration:capabilities:configurationResolver:weightsLocation:load:)``
    /// and stored verbatim. The caller includes
    /// `.guidedGeneration`/`.toolCalling`/`.reasoning` as appropriate; the
    /// adapter does not consult ``ReasoningHeuristics`` (which remains a
    /// standalone helper a caller may use to compute their own capability set).
    ///
    /// Declaring `.reasoning` matters for request routing: the framework only
    /// forwards a `reasoningLevel` to executors that declare `.reasoning`, and
    /// auto-rejects one otherwise (on the developer's behalf) before `respond`
    /// runs. The executor in turn emits `.reasoning` events only when this
    /// capability was declared.
    public let capabilities: LanguageModelCapabilities

    /// The configuration resolver that patches a per-call ``ModelConfiguration``
    /// for this instance. Defaults to ``DefaultConfigurationResolver`` when
    /// omitted.
    public let configurationResolver: any ModelConfigurationResolver

    /// Configuration the framework uses to create and cache executors.
    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(modelID: modelID)
    }

    // MARK: - Initialization

    /// Creates an MLXLanguageModel from a configuration, deferring model
    /// loading until first inference or `preload()`.
    ///
    /// - Parameters:
    ///   - configuration: Identifies and parameterizes the model (e.g.
    ///     `LLMRegistry.gemma3_1B_qat_4bit` or `ModelConfiguration(id:)`).
    ///   - capabilities: The capabilities this model supports
    ///     (`.guidedGeneration`, `.toolCalling`, `.reasoning`, `.vision`).
    ///     Stored verbatim; the adapter never infers or expands the set.
    ///   - configurationResolver: Patches a per-call ``ModelConfiguration``
    ///     (reasoning config, extra stop tokens) for this instance.
    ///   - weightsLocation: Resolves a model identifier to its on-disk weights
    ///     directory, for the availability checks.
    ///   - load: Loads the model container for a configuration.
    ///
    /// For example, to read weights from a fixed directory:
    ///
    /// ```swift
    /// weightsLocation: { id in
    ///     URL(fileURLWithPath: "/Volumes/SharedCache/models/\(id)")
    /// }
    /// ```
    public init(
        configuration: ModelConfiguration,
        capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration],
        configurationResolver: any ModelConfigurationResolver =
            DefaultConfigurationResolver(),
        weightsLocation: @Sendable @escaping (String) -> URL,
        load: @escaping ContainerLoader
    ) {
        self.configuration = configuration
        self.capabilities = LanguageModelCapabilities(capabilities)
        self.configurationResolver = configurationResolver
        self.source = .deferred(weightsLocation: weightsLocation, load: load)
    }

    /// Creates a package-local adapter around a container that has already
    /// been loaded and verified by the caller.
    ///
    /// This path intentionally has neither a weights location nor a loader.
    /// It preserves container identity across loads and eviction calls, keeps
    /// its internally derived descriptor immutable, and leaves all warm-up
    /// timing to the caller. The tokenizer is read from the same atomic
    /// container snapshot as the checked configuration so it cannot be supplied
    /// independently.
    package init(
        configuration: ModelConfiguration,
        capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration],
        configurationResolver: any ModelConfigurationResolver =
            DefaultConfigurationResolver(),
        container: ModelContainer,
        descriptorModelType: String,
        descriptorConfigData: Data?
    ) async throws {
        let snapshot = await container.perform { context in
            StoredContainerSnapshot(
                configuration: context.configuration,
                tokenizer: context.tokenizer)
        }
        guard snapshot.configuration == configuration else {
            throw StoredContainerInitializationError.containerConfigurationMismatch
        }
        let descriptor = ModelDescriptor(
            modelType: descriptorModelType,
            modelId: configuration.name,
            configData: descriptorConfigData,
            tokenizer: snapshot.tokenizer)
        self.configuration = configuration
        self.capabilities = LanguageModelCapabilities(capabilities)
        self.configurationResolver = configurationResolver
        self.source = .stored(
            container: container,
            descriptor: descriptor,
            derivedCache: DerivedArtifactCache())
    }

    /// Creates a stored adapter and its container from one already-correlated context.
    ///
    /// This synchronous form is the activation-boundary initializer. It lets a trusted loader
    /// finish model construction while verified bytes are still borrowed, without publishing an
    /// intermediate container or suspending across the one-shot verification callback.
    package init(
        configuration: ModelConfiguration,
        capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration],
        configurationResolver: any ModelConfigurationResolver =
            DefaultConfigurationResolver(),
        context: consuming ModelContext,
        descriptorModelType: String,
        descriptorConfigData: Data?
    ) throws {
        guard context.configuration == configuration else {
            throw StoredContainerInitializationError.containerConfigurationMismatch
        }
        let descriptor = ModelDescriptor(
            modelType: descriptorModelType,
            modelId: configuration.name,
            configData: descriptorConfigData,
            tokenizer: context.tokenizer)
        self.configuration = configuration
        self.capabilities = LanguageModelCapabilities(capabilities)
        self.configurationResolver = configurationResolver
        self.source = .stored(
            container: ModelContainer(context: context),
            descriptor: descriptor,
            derivedCache: DerivedArtifactCache())
    }

    /// Downloads the model and loads its weights into memory.
    ///
    /// This is a weights-only load: it runs no forward pass, compiles no Metal
    /// shaders, and performs no GPU work, so the first generation request after
    /// `preload()` still pays the one-time Metal shader JIT cost. The call is
    /// awaitable and fully caller-owned — you decide when it runs and handle
    /// any error it throws.
    ///
    /// Call it early, for example when a view appears, to move the
    /// download-and-load portion of cold-start latency off the first
    /// generation request.
    ///
    /// Safe to call multiple times; once the model is loaded, subsequent calls
    /// return immediately from cache.
    public func preload() async throws {
        _ = try await loadContainer()
    }

    /// Loads the model weights and compiles Metal shaders, so the first
    /// `respond()` afterward pays no (or materially reduced) cold-start
    /// shader-JIT cost.
    ///
    /// Metal kernels JIT-compile lazily on the first *synchronous* readback
    /// (`.item()` inside the generate loop) — scheduling work with `asyncEval`
    /// alone does not compile them — so this runs a minimal throwaway forward
    /// pass to force compilation ahead of a real request.
    ///
    /// The forward pass and its single `Stream.gpu.synchronize()` run inside
    /// `container.perform { }`, the same `SerialAccessContainer` lock the
    /// `respond` path holds for its entire generation, so a warmup cannot race
    /// a concurrent `respond` on the process-global `Stream.gpu`. The 1-token
    /// generate ends naturally and is consumed to completion — never cancelled
    /// mid-flight — so a Metal command buffer is never cancelled after commit and
    /// the stream is drained before teardown.
    ///
    /// This public method is explicitly awaitable and caller-controlled. For a
    /// stored container it is the only prewarm path: FoundationModels'
    /// synchronous ``Executor/prewarm(model:transcript:)`` and
    /// `session.prewarm()` deliberately do no work for stored models. Safe to
    /// call multiple times and concurrently; deferred calls reuse their cached
    /// container and stored calls retain the caller-supplied container.
    public func warmUp() async throws {
        // Distinguish a warmup of an already-present model (suppress the
        // spurious `.available → .downloading → .available` flip) from a
        // genuine first fetch (which still reports `.downloading`). Conditioning
        // on disk-presence — not "is a warmup" alone — is what makes the
        // loadingTasks-dedup collision benign (see `DeferredModelCache.load`)
        // and keeps
        // the partial-download guard intact: we suppress the in-flight
        // `.downloading` signal rather than reorder the availability checks
        // (reordering would let a partial download with only `config.json`
        // present falsely report `.available`).
        let container: ModelContainer
        if hasStoredContainer {
            // A stored container never uses the global `DeferredModelCache`. This
            // explicit, awaitable call is the only supported prewarm path for
            // it; FoundationModels' synchronous prewarm witness is a no-op.
            container = try await loadContainer()
        } else {
            let alreadyOnDisk = modelExistsOnDisk()
            container = try await loadContainer(suppressDownloadingState: alreadyOnDisk)
        }

        // Pre-create the model-keyed GrammarTokenizer so a guided / tool-calling
        // consumer skips the expensive vocab-extraction step on first
        // respond(). It's keyed on modelID alone — the same cache entry
        // respond()'s guided path reads — so this is a genuine cache hit.
        //
        // CPU-only (xgrammar is C++; no Stream.gpu, no Metal), so it adds no
        // GPU-teardown-race exposure: the safe half of warmup. It runs *after*
        // loadContainer because it needs the live Tokenizer from the container,
        // and *before* the forward pass below so the GPU-touching work stays a
        // single contiguous, serialized block.
        //
        // We deliberately do NOT pre-build a constraint template here:
        // makeConstraint is keyed on modelID:kind:source, where `source` is the
        // per-request schema/tool grammar that prewarm doesn't possess — a
        // pre-built constraint would land under a key no real respond() reads.
        if !hasStoredContainer {
            let tokenizer = await container.tokenizer
            _ = try await Self.makeXGTokenizer(
                cache: derivedCache,
                modelID: modelID, tokenizer: tokenizer)
        }

        // Force Metal shader JIT with a minimal 1-token generate, run inside
        // `perform` so the forward pass + synchronize serialize against any
        // concurrent `respond`. `maxTokens: 1` makes the stream end on
        // its own; we consume it fully (no early break) so generation runs to
        // completion and leaves no dangling GPU work to race the teardown sync.
        try await container.perform { context in
            // Exactly one synchronize on every exit path (success or throw),
            // per the Metal teardown invariant. `prepare` is CPU-only, so on a
            // pre-forward-pass throw this just synchronizes an idle stream.
            defer { Stream.gpu.synchronize() }
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.user("warmup")]))
            let params = GenerateParameters(maxTokens: 1)
            for await _ in try MLXLMCommon.generate(
                input: input, parameters: params, context: context
            ) {
                // Drain to completion.
            }
        }
    }

    /// Builds the resolver descriptor for a generation request.
    ///
    /// Stored containers carry a verified immutable descriptor, so this branch
    /// intentionally performs no directory or `config.json` access.
    static func descriptor(
        for context: ModelContext,
        modelID: String,
        storedDescriptor: ModelDescriptor?,
        weightsLocation: (@Sendable (String) -> URL)?
    ) -> ModelDescriptor {
        if let storedDescriptor {
            return storedDescriptor
        }

        let configData = weightsLocation.flatMap { weightsLocation in
            try? Data(
                contentsOf: weightsLocation(modelID)
                    .appendingPathComponent("config.json"))
        }
        let modelType =
            configData.flatMap {
                try? JSONDecoder.json5().decode(
                    BaseConfiguration.self, from: $0
                ).modelType
            } ?? ""
        return ModelDescriptor(
            modelType: modelType,
            modelId: modelID,
            configData: configData,
            tokenizer: context.tokenizer)
    }

    static func generationRoute(
        hasEnabledTools: Bool,
        usesAllowedToolBehavior: Bool,
        hasSchema: Bool,
        usesReasoning: Bool
    ) -> GenerationRoute {
        if hasEnabledTools {
            return usesAllowedToolBehavior ? .allowedTools : .requiredTools
        }
        if hasSchema { return .schema }
        if usesReasoning { return .reasoning }
        return .plain
    }

    static func rejectUnsupportedFramedProtocol(
        _ format: ToolCallFormat?,
        for route: GenerationRoute
    ) throws {
        switch route {
        case .allowedTools, .requiredTools, .reasoning:
            break
        case .schema, .plain:
            return
        }
        guard let format else { return }
        switch format {
        case .gptOSS, .atem:
            throw UnsupportedProtocolError.framedToolProtocol(format)
        default:
            return
        }
    }

    // MARK: - Executor

    /// Executes inference requests for the model.
    public struct Executor: LanguageModelExecutor, Sendable {

        // MARK: - Test observation hook
        //
        // The macOS 27 FoundationModels SDK made the generation-channel event
        // and action types opaque: a consumer can no longer read back what was
        // streamed. Tests need to read it, and the only place the content is
        // available is here, right before it enters the channel. These emit
        // helpers are the sole send sites for each event kind; each notifies an
        // optional observer with a readable mirror. The observer is nil in
        // shipping builds (only tests attach one via the task-local), so the
        // arguments handed to `channel.send` are identical to before and
        // behavior is unchanged.

        /// Readable, internal-only mirror of the events this executor streams
        /// into the opaque FoundationModels channel.
        enum GenerationEvent: Sendable {
            enum Destination: Sendable { case response, reasoning }
            case appendText(String, entryID: String?, destination: Destination)
            case toolCall(id: String, name: String, arguments: String)
            case updateMetadata(
                [String: any ConvertibleToGeneratedContent & Sendable], entryID: String?)
            case updateUsage(
                input: LanguageModelExecutorGenerationChannel.Usage.Input,
                output: LanguageModelExecutorGenerationChannel.Usage.Output,
                entryID: String?)
        }

        /// Attached only by tests (via `$generationObserver.withValue`); nil in
        /// shipping. Task-local so it reaches child tasks that also emit (e.g.
        /// the guided-generation text forwarder).
        @TaskLocal static var generationObserver: (@Sendable (GenerationEvent) -> Void)?

        static func emit(
            text: String, entryID: String?, destination: GenerationEvent.Destination,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            generationObserver?(.appendText(text, entryID: entryID, destination: destination))
            switch destination {
            case .response:
                await channel.send(
                    .response(entryID: entryID, action: .appendText(text, tokenCount: 1)))
            case .reasoning:
                await channel.send(
                    .reasoning(entryID: entryID, action: .appendText(text, tokenCount: 1)))
            }
        }

        static func emitMetadata(
            _ values: [String: any ConvertibleToGeneratedContent & Sendable], entryID: String?,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            generationObserver?(.updateMetadata(values, entryID: entryID))
            await channel.send(.response(entryID: entryID, action: .updateMetadata(values)))
        }

        static func emitUsage(
            input: LanguageModelExecutorGenerationChannel.Usage.Input,
            output: LanguageModelExecutorGenerationChannel.Usage.Output,
            entryID: String?,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            generationObserver?(.updateUsage(input: input, output: output, entryID: entryID))

            // TODO: papering over an FM-27 SDK symbol drift -- restore
            // the channel usage send (the commented-out call at the end of this
            // block) once the shipping dylib matches its own interface.
            //
            // Usage is intentionally NOT forwarded to the FoundationModels
            // channel on this SDK. The FM-27 beta `.swiftinterface` declares
            //   Response.Action.updateUsage(input:output:metadata: = [:])
            // (three parameters), but the shipping FoundationModels dylib only
            // exports the older two-parameter
            //   Response.Action.updateUsage(input:output:)
            // Because our call relies on the `metadata:` default, the compiler
            // resolves it to the three-parameter symbol, which does not exist
            // at runtime. dyld cannot bind it: under chained-fixups linking
            // (the arm64 default) the reference aborts the process the moment
            // the image loads, and under lazy binding it faults through null
            // (SIGSEGV at 0x0) the instant this send executes -- crashing every
            // `respond()` path right after generation completes.
            //
            // A runtime `dlsym` guard cannot save this: the compiled reference
            // to the missing symbol is enough to abort at launch regardless of
            // any surrounding check. The only safe option is to not reference
            // the symbol at all, so no `channel.send(.updateUsage(...))` here.
            //
            // Effect: the framework does not receive our per-response usage
            // event, so consumer-visible usage for these responses may be
            // absent or zero. Tests still observe usage through
            // `generationObserver` above. When a later SDK ships a dylib that
            // matches its interface, restore the send:
            //   await channel.send(
            //       .response(
            //           entryID: entryID,
            //           action: .updateUsage(input: input, output: output)))
        }

        static func emitToolCall(
            id: String, name: String, arguments: String, entryID: String,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            generationObserver?(.toolCall(id: id, name: name, arguments: arguments))
            await channel.send(
                .toolCalls(
                    entryID: entryID,
                    action: .toolCall(
                        id: id, name: name,
                        action: .appendArguments(arguments, tokenCount: 1))))
        }

        /// Default `maxTokens` when the caller doesn't set
        /// `GenerationOptions.maximumResponseTokens`. Applied uniformly
        /// across guided-JSON, tool-calling, and unconstrained generation
        /// paths so all three share a single definition.
        ///
        /// The guided paths *require* a budget to activate the zone-based
        /// closing bias in `GuidedGenerationLoop` -- without it, open-source
        /// models tend to wander in JSON whitespace before reaching
        /// structural close. 4096 is generous for typical tool calls and
        /// structured outputs. Consumers can override via
        /// `GenerationOptions(maximumResponseTokens:)`.
        private static let defaultMaxTokens = 4096

        /// Map FoundationModels' optional `Double` `GenerationOptions.temperature`
        /// to MLXLMCommon's `Float` `GenerateParameters.temperature`, clamping
        /// negatives to 0.
        ///
        /// - Returns: `nil` when the caller did not request a specific
        ///   temperature, leaving `GenerateParameters`' built-in default in
        ///   place. Otherwise the clamped `Float`.
        ///
        /// Negative sampling temperatures land in `CategoricalSampler` and
        /// produce inverted distributions; we clamp at 0 so the worst the
        /// caller can get is greedy. `0` itself is honored unchanged because
        /// MLXLMCommon's `GenerateParameters.sampler()` routes
        /// `temperature == 0` to `ArgMaxSampler` (greedy) -- no division-by-
        /// zero hazard.
        static func clampedTemperature(_ value: Double?) -> Float? {
            guard let value else { return nil }
            return Float(max(0, value))
        }

        /// Translate Foundation Models' `GenerationOptions.SamplingMode` into one
        /// backend-local value that preserves both the sampling strategy and optional
        /// `UInt64` seed. No mode set (`nil`) and any future/unknown `Kind` both map to
        /// `nil`, selecting provider-default behavior without trapping or guessing.
        static func samplingConfiguration(
            from samplingMode: GenerationOptions.SamplingMode?
        ) -> MLXSamplingConfiguration? {
            guard let kind = samplingMode?.kind else { return nil }
            switch kind {
            case .greedy:
                return MLXSamplingConfiguration(mode: .greedy, seed: nil)
            case .randomTopK(let k, let seed):
                return MLXSamplingConfiguration(mode: .topK(k), seed: seed)
            case .randomProbabilityThreshold(let threshold, let seed):
                return MLXSamplingConfiguration(mode: .nucleus(threshold), seed: seed)
            @unknown default:
                return nil
            }
        }

        /// Build `GenerateParameters` for a sampler-backed generation pass. The shared
        /// resolver owns temperature and mode precedence; this helper preserves the
        /// optional seed directly on the backend request.
        static func makeParameters(
            maxTokens: Int,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?
        ) -> GenerateParameters {
            var parameters = GenerateParameters(maxTokens: maxTokens)
            resolveSamplingParameters(
                mode: samplingConfiguration?.mode,
                clampedTemperature: clampedTemperature(requestedTemperature)
            ).apply(to: &parameters)
            parameters.seed = samplingConfiguration?.seed
            return parameters
        }

        /// Map xgrammar errors to typed `LanguageModelError` cases where the
        /// cause is provably the user's input; pass everything else through
        /// unchanged.
        ///
        /// Only `GrammarError.invalidJSONSchema` is mapped: that case fires when
        /// xgrammar's JSON-Schema validator outright rejects the schema text
        /// we synthesized from `GenerationSchema`, which is a problem the
        /// developer can fix (simplify the schema, drop an unsupported
        /// construct). `LanguageModelError.unsupportedGenerationGuide` is the
        /// framework's idiomatic surface for that.
        ///
        /// `constraintCompilationFailed` is deliberately NOT mapped to
        /// `unsupportedGenerationGuide`: its origin is ambiguous (could be
        /// schema-level, could be an internal shim failure), and claiming
        /// user-fault when the cause is actually our infrastructure
        /// misleads developers who pattern-match on typed errors.
        ///
        /// `tokenizerCreationFailed` and `bitmaskRetrievalFailed` are
        /// internal shim failures with no recovery path on the developer's
        /// side -- surfacing them untyped is honest.
        static func mapGrammarError(_ grammarError: GrammarError) -> Error {
            switch grammarError {
            case .invalidJSONSchema(let message):
                return LanguageModelError.unsupportedGenerationGuide(
                    .init(schemaName: nil, debugDescription: message)
                )
            default:
                return grammarError
            }
        }

        /// Configuration for creating and caching executors.
        public struct Configuration: Hashable, Sendable {
            /// The model identifier this executor uses for loading and metadata.
            public let modelID: String
        }

        /// The model identifier this executor uses for loading and metadata.
        let modelID: String

        /// Creates an executor from a configuration.
        public init(configuration: Configuration) throws {
            self.modelID = configuration.modelID
        }

        /// Logs warmup failures from the fire-and-forget `prewarm` path. A
        /// failed warmup is otherwise invisible (no throw reaches the caller),
        /// so this is the only diagnostic surface for a persistently-failing
        /// prewarm (bad id, network gone, OOM). Note it cannot intercept a
        /// Metal command-buffer assertion abort — that is a process crash, not
        /// a catchable Swift error.
        private static let logger = Logger(
            subsystem: "com.apple.FoundationModels-MLX", category: "Prewarm")
        private static let protocolLogger = Logger(
            subsystem: "com.apple.FoundationModels-MLX", category: "TokenStreamProtocol")

        /// Prewarms the model: loads weights and pre-compiles Metal shaders so
        /// the first `respond()` pays no cold-start shader-JIT cost.
        ///
        /// This is the protocol witness for `LanguageModelExecutor`'s
        /// `prewarm(model:transcript:)`. The signature must match the
        /// requirement *exactly* — concrete `Transcript`, not a generic
        /// `some Collection<Transcript.Entry>` — otherwise it fails to bind as
        /// the witness and the framework's no-op default silently wins instead.
        /// The session hands us the live model instance, so we route through
        /// its downloader/loader pair.
        ///
        /// Fire-and-forget, mirroring Apple's SLM/PCCLM executors and the
        /// framework's own `session.prewarm()`: the method is synchronous and
        /// non-throwing, so it spawns a detached warmup `Task` and returns
        /// immediately. The `Task` is best-effort — a failure is logged, never
        /// surfaced to or crashed on the caller.
        /// For stored containers this method returns without scheduling work;
        /// their owner explicitly awaits ``MLXLanguageModel/warmUp()``.
        ///
        /// - Parameters:
        ///   - model: The live model instance to warm.
        ///   - transcript: Accepted per protocol; the shader warmup uses a
        ///     fixed dummy prompt and does not depend on it.
        public func prewarm(model: MLXLanguageModel, transcript: Transcript) {
            // A stored model must never acquire work indirectly from the
            // framework. Its owner chooses whether to await `warmUp()`.
            guard model.shouldScheduleFrameworkPrewarm else { return }
            Task {
                do {
                    try await model.warmUp()
                } catch {
                    Self.logger.error(
                        "MLX prewarm failed for \(model.modelID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        /// Generates a response for the given request, streaming events into the channel.
        ///
        /// - Parameters:
        ///   - request: The generation request containing transcript, tools, and options
        ///   - model: The model instance for this request
        ///   - channel: The channel to send response events into
        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: MLXLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            var collected = TranscriptConverter.mlxMessages(for: request.transcript)
            // MLX tokenizer crashes on empty chat input; provide a fallback.
            if collected.isEmpty {
                collected = [Chat.Message.user("")]
            }
            let messages = collected

            // Vision capability gate (adapter-side). Labeled image
            // attachments arrive as public `.attachment` segments that
            // the SDK's own vision guard never inspects, so the adapter
            // is the only place that can enforce `.vision` for this path.
            // Throw the same typed error the SDK would, before loading
            // any weights, so a model declared without `.vision` fails
            // fast and identically across the tool / schema / plain paths.
            if !model.capabilities.contains(.vision),
                messages.contains(where: { !$0.images.isEmpty })
            {
                throw LanguageModelError.unsupportedCapability(
                    LanguageModelError.UnsupportedCapability(
                        capability: .vision,
                        debugDescription:
                            "This request includes an image, but .vision was not declared at MLXLanguageModel init. Declare .vision to accept image inputs."
                    ))
            }

            let toolCallingMode = ToolCallingModeResolution.resolve(
                request.generationOptions.toolCallingMode)
            let enabledToolDefinitions = try ToolCallingModeResolution.enabledToolDefinitions(
                for: toolCallingMode,
                from: request.enabledToolDefinitions)

            let container = try await model.loadContainer()

            // Encode schema to JSON if present
            let schemaJSON: String?
            if let schema = request.schema {
                schemaJSON = try SchemaConverter.encodeToJSON(schema)
            } else {
                schemaJSON = nil
            }

            let modelID = self.modelID
            let requestedMaxTokens = request.generationOptions.maximumResponseTokens
            // Translate the SDK sampling mode once, here where generationOptions
            // is in scope; thread the bridge-local value down to every
            // real-sampler path so they honor it identically.
            let requestedSamplingConfiguration = Self.samplingConfiguration(
                from: request.generationOptions.samplingMode)
            // Per SKILL.md: response and tool-calls entries each need a fresh
            // UUID — they live in separate transcript entries. We preserve the
            // framework-supplied `request.id` for tracing by stamping it into
            // the response metadata below, rather than reusing it as an entry id.
            let entryID = UUID().uuidString
            let toolCallsEntryID = UUID().uuidString
            let reasoningEntryID = UUID().uuidString
            // Captured before the actor hop so the perform closure doesn't
            // capture `model`. Reasoning is gated strictly on the declared
            // capability; the resolver-patched configuration supplies the
            // reasoning config we route on.
            let declaresReasoning = model.capabilities.contains(.reasoning)
            let configurationResolver = model.configurationResolver
            let storedDescriptor = model.storedDescriptor
            let weightsLocation = model.weightsLocation
            let derivedCache = model.derivedCache

            do {
                // Send metadata first
                await Self.emitMetadata(
                    ["modelID": modelID, "requestID": request.id.uuidString],
                    entryID: entryID, into: channel)

                // Generate tokens inside actor isolation. `messages` carries
                // non-Sendable `Chat.Message` instances (UserInput.Image and
                // .Video are not Sendable), so route the array through
                // perform(nonSendable:_:) which boxes it across the actor hop.
                try await container.perform(nonSendable: messages) { context, messages in
                    // Render the prompt through the model's UserInputProcessor.
                    let userInput = UserInput(chat: messages)
                    let input = try await context.processor.prepare(input: userInput)

                    // Resolve the per-instance configuration. Held strictly as
                    // a local; it never lands in context.configuration or
                    // Executor.Configuration, so two instances with the same id
                    // but different resolvers don't cross-contaminate through
                    // the shared caches. Identity is read from
                    // context.configuration (above, at load time) and never
                    // from `resolved`.
                    let descriptor = MLXLanguageModel.descriptor(
                        for: context,
                        modelID: modelID,
                        storedDescriptor: storedDescriptor,
                        weightsLocation: weightsLocation)
                    let resolved = configurationResolver.resolve(
                        context.configuration, for: descriptor)

                    // Capability gate. When the caller omits `.reasoning`
                    // but the resolved configuration carries a reasoning
                    // config, the model must not be allowed to think:
                    //
                    // - Toggleable strategies (`.templateFlag`) re-render the
                    //   prompt with thinking off (handled below per path).
                    // - Non-suppressible strategies (`.alwaysOn`) raise
                    //   `unsupportedCapability` BEFORE generation, regardless
                    //   of which path (tools / schema / unconstrained) the
                    //   request would otherwise take. The throw is
                    //   path-independent so a tool-calling or schema-guided
                    //   request on a model that always reasons surfaces the
                    //   same typed error the unconstrained path does, never a
                    //   silent leak through the grammar's malformed-output
                    //   fallback.
                    if !declaresReasoning, let suppressionConfig = resolved.reasoningConfig {
                        do {
                            _ = try suppressionConfig.promptStrategy
                                .additionalContext(forThinkingEnabled: false)
                        } catch ReasoningError.cannotDisableReasoning {
                            throw LanguageModelError.unsupportedCapability(
                                LanguageModelError.UnsupportedCapability(
                                    capability: .reasoning,
                                    debugDescription:
                                        "This model always reasons; .reasoning must be declared at MLXLanguageModel init to receive its output."
                                ))
                        }
                    }

                    // Reasoning is only consumed by the unconstrained path
                    // (no tools, no schema). On the guided/tool paths the
                    // grammar already constrains output, so suppression-prep
                    // would be wasted work here. Continuation rounds run the
                    // tool path (below) like fresh turns: that path renders its
                    // own thinking state into the tool-aware prompt
                    // (`toolAwareContext`) -- thinking on with the think-then-call
                    // phase when reasoning is declared, forced off otherwise.
                    let mayRunReasoningPath =
                        enabledToolDefinitions.isEmpty
                        && request.schema == nil

                    // When .reasoning is OMITTED on the unconstrained path,
                    // re-render the prompt with thinking off so the model
                    // doesn't emit `<think>`. Toggleable-only;
                    // .alwaysOn was already rejected above.
                    let suppressedInput: LMInput?
                    if mayRunReasoningPath, !declaresReasoning,
                        let suppressionConfig = resolved.reasoningConfig
                    {
                        suppressedInput = try await Self.preparedInput(
                            messages: messages, config: suppressionConfig,
                            thinkingEnabled: false, processor: context.processor,
                            cannotDisableMessage:
                                "This model always reasons; .reasoning must be declared at MLXLanguageModel init to receive its output."
                        )
                    } else {
                        suppressedInput = nil
                    }

                    let reasoningSetup:
                        (input: LMInput, config: ReasoningConfig, primedInside: Bool)?
                    if mayRunReasoningPath, declaresReasoning,
                        let reasoningConfig = resolved.reasoningConfig
                    {
                        let thinkingEnabled = Self.thinkingEnabled(
                            for: request.contextOptions.reasoningLevel)
                        let reasoningInput = try await Self.preparedInput(
                            messages: messages, config: reasoningConfig,
                            thinkingEnabled: thinkingEnabled, processor: context.processor,
                            cannotDisableMessage:
                                "This model always reasons; reasoning cannot be disabled via reasoningLevel."
                        )
                        reasoningSetup = (
                            reasoningInput, reasoningConfig,
                            Self.reasoningPrimedInside(
                                input: reasoningInput, config: reasoningConfig,
                                tokenizer: context.tokenizer)
                        )
                    } else {
                        reasoningSetup = nil
                    }

                    let generationRoute = MLXLanguageModel.generationRoute(
                        hasEnabledTools: !enabledToolDefinitions.isEmpty,
                        usesAllowedToolBehavior:
                            ToolCallingModeResolution.usesAllowedBehavior(toolCallingMode),
                        hasSchema: schemaJSON != nil,
                        usesReasoning: reasoningSetup != nil)
                    #if STENO_VENDORED_ADAPTER
                    try MLXLanguageModel.rejectUnsupportedFramedProtocol(
                        context.configuration.toolCallFormat,
                        for: generationRoute)
                    #endif

                    // The prompt actually fed into generation: the suppressed
                    // prompt when we're forcing thinking off, otherwise the
                    // baseline `input` rendered above.
                    let effectiveInput = suppressedInput ?? input

                    // Tool path, entered on every round while tools are enabled
                    // -- fresh turns and continuations alike. Allowed mode uses
                    // native generation so the model can answer or call a tool;
                    // required mode constrains generation to a real tool call.
                    if !enabledToolDefinitions.isEmpty {
                        // Re-render using the model's native tool-aware chat
                        // template (Qwen/Llama/Phi/Gemma all ship one in their
                        // tokenizer_config.json). This is what teaches the model
                        // *what* tools exist and how to decide between them; the
                        // grammar constraint below only enforces the *shape* of
                        // whatever tool call it emits.
                        // Think-then-call is gated to the enable_thinking
                        // family (Qwen3/QwQ): their template both renders the tool
                        // block AND honors `enable_thinking`. R1-style `.alwaysOn`
                        // models are tool-blind (template ignores `tools:`), so
                        // they fall through to the single-phase path unchanged;
                        // thinking-disabled requests stay single-phase too.
                        let thinkThenCallConfig: ReasoningConfig? = {
                            guard declaresReasoning,
                                let cfg = resolved.reasoningConfig,
                                case .templateFlag = cfg.promptStrategy,
                                Self.thinkingEnabled(
                                    for: request.contextOptions.reasoningLevel) != false
                            else { return nil }
                            return cfg
                        }()
                        // Thread `enable_thinking` through the tool-aware template
                        // so the prompt's thinking state matches how we drive
                        // generation. For a toggleable model (`.templateFlag`, e.g.
                        // Qwen3 whose `enable_thinking` defaults ON) the effective
                        // value is:
                        //   - reasoning declared: honor the requested level
                        //     (default ON), and the think-then-call phase below
                        //     lets the model reason before the grammar constrains it;
                        //   - reasoning NOT declared: force thinking OFF, mirroring
                        //     the unconstrained path's suppression (see
                        //     `suppressedInput` above).
                        // Forcing OFF here is load-bearing for both modes. Native
                        // `.allowed` generation would otherwise surface undeclared
                        // reasoning through response/tool parsing. In `.required`,
                        // the grammar forces tool-call JSON from the first token, so
                        // a thinking-primed model cannot emit its `<think>` block and
                        // greedy decoding of unconstrained developer tool string
                        // arguments can degenerate (Qwen: "1234567890...").
                        // `.alwaysOn` models with reasoning undeclared were already
                        // rejected by the capability gate above; `.none`/no-config
                        // models take no context.
                        let toolAwareContext: [String: any Sendable]?
                        if case .templateFlag(let key, let defaultOn)? =
                            resolved.reasoningConfig?.promptStrategy
                        {
                            let enabled =
                                declaresReasoning
                                ? (Self.thinkingEnabled(
                                    for: request.contextOptions.reasoningLevel) ?? defaultOn)
                                : false
                            toolAwareContext = [key: enabled]
                        } else {
                            toolAwareContext = nil
                        }
                        // Prepare through the model's UserInputProcessor (like the
                        // unconstrained and guided paths) instead of hand-building
                        // an LMInput from raw applyChatTemplate output: processors
                        // produce the token rank their model family requires (LLM
                        // processors emit [N]; VLM processors emit [1, N], and VLM
                        // `prepare` fatally aborts on 1-D input), and they carry
                        // image/video content through to the model.
                        if ToolCallingModeResolution.usesAllowedBehavior(toolCallingMode) {
                            let toolSpecs = try ToolCallingConversions.makeToolSpecs(
                                from: enabledToolDefinitions)
                            let toolAwareInput = try await context.processor.prepare(
                                input: UserInput(
                                    chat: messages,
                                    tools: toolSpecs,
                                    additionalContext: toolAwareContext))
                            let reasoning = thinkThenCallConfig.map {
                                (
                                    config: $0,
                                    primedInside: Self.reasoningPrimedInside(
                                        input: toolAwareInput,
                                        config: $0,
                                        tokenizer: context.tokenizer)
                                )
                            }
                            let result = try await runAllowedToolGeneration(
                                input: toolAwareInput,
                                toolSpecs: toolSpecs,
                                reasoning: reasoning,
                                requestedMaxTokens: requestedMaxTokens,
                                requestedTemperature: request.generationOptions.temperature,
                                samplingConfiguration: requestedSamplingConfiguration,
                                reasoningEntryID: reasoningEntryID,
                                context: context,
                                channel: channel)

                            if result.endedInsideReasoning {
                                await Self.emitMetadata(
                                    ["incompleteOutput": true], entryID: entryID, into: channel)
                            } else if !result.toolCalls.isEmpty {
                                for call in result.toolCalls {
                                    let argumentsData = try JSONEncoder().encode(
                                        call.function.arguments)
                                    let arguments = String(
                                        decoding: argumentsData, as: UTF8.self)
                                    await Self.emitToolCall(
                                        id: call.id ?? UUID().uuidString,
                                        name: call.function.name,
                                        arguments: arguments,
                                        entryID: toolCallsEntryID,
                                        into: channel)
                                }
                            } else if let schemaJSON {
                                try await runSchemaGeneration(
                                    schemaJSON: schemaJSON,
                                    input: input,
                                    modelID: modelID,
                                    derivedCache: derivedCache,
                                    requestedMaxTokens: requestedMaxTokens,
                                    entryID: entryID,
                                    context: context,
                                    channel: channel)
                            } else {
                                await Self.emit(
                                    text: result.responseText,
                                    entryID: entryID,
                                    destination: .response,
                                    into: channel)
                            }
                            if schemaJSON == nil || !result.toolCalls.isEmpty
                                || result.endedInsideReasoning
                            {
                                await emitAllowedUsage(
                                    result, entryID: entryID, channel: channel)
                            }
                            Stream.gpu.synchronize()
                            return
                        }

                        // Required mode is the only mode that reaches guided
                        // tool generation, and it uses developer definitions only.
                        let requiredToolDefinitions = enabledToolDefinitions
                        let toolSpecs = try ToolCallingConversions.makeToolSpecs(
                            from: requiredToolDefinitions)
                        let toolAwareInput = try await context.processor.prepare(
                            input: UserInput(
                                chat: messages,
                                tools: toolSpecs,
                                additionalContext: toolAwareContext))

                        let toolCallingGrammar =
                            try SchemaConverter.encodeToolCallingGrammar(
                                tools: requiredToolDefinitions
                            )
                        // The inner JSON envelope is still needed separately to
                        // seed `CompletionReserve` -- the wrapper tokens
                        // (`<tool_call>`, two `\n`s, `</tool_call>`) are small
                        // and fixed, so padding the reserve with their
                        // tokenized size adds noise rather than accuracy.
                        let toolCallingEnvelopeJSON =
                            try SchemaConverter.encodeToolCallingEnvelopeJSON(
                                tools: requiredToolDefinitions
                            )

                        let xgTokenizer = try await MLXLanguageModel.makeXGTokenizer(
                            cache: derivedCache,
                            modelID: modelID,
                            tokenizer: context.tokenizer
                        )
                        let constraint = try await MLXLanguageModel.makeConstraint(
                            cache: derivedCache,
                            modelID: modelID,
                            kind: .structuralTag,
                            source: toolCallingGrammar,
                            tokenizer: xgTokenizer,
                            hostTokenizer: context.tokenizer,
                            fastForward: true
                        )

                        // Always partition into zones -- the grammar has
                        // wiggle room (JSON whitespace before the outer
                        // `}`, whitespace before `\n</tool_call>`) that
                        // open-source models tend to exploit into infinite
                        // loops when not pushed toward structural close.
                        // Use the caller's budget when set, otherwise the
                        // Executor's default.
                        let maxTokens = requestedMaxTokens ?? Self.defaultMaxTokens
                        let bias = await MLXLanguageModel.makeTokenizerBias(
                            cache: derivedCache,
                            modelID: modelID,
                            tokenizer: context.tokenizer
                        )
                        let closingBias = bias.closing
                        let structuralReserve = CompletionReserve.estimate(
                            schemaJSON: toolCallingEnvelopeJSON,
                            tokenizer: context.tokenizer
                        )
                        let completionReserve = Swift.max(
                            structuralReserve * 3, maxTokens / 4)
                        let hardReserve = structuralReserve * 8

                        let whitespaceBias = bias.whitespace
                        let whitespaceTokenIDs = bias.whitespaceTokenIDs

                        // PHASE 1 (think-then-call): reason unconstrained until
                        // `</think>`, retaining the token IDs to prefill into the
                        // constrained phase below. Empty on the single-phase path.
                        var reasoningTokenIDs: [Int] = []
                        if let cfg = thinkThenCallConfig {
                            let primedInside = Self.reasoningPrimedInside(
                                input: toolAwareInput, config: cfg,
                                tokenizer: context.tokenizer)
                            let phase1 = try await runToolCallReasoningPhase(
                                input: toolAwareInput, config: cfg,
                                primedInside: primedInside, maxTokens: maxTokens,
                                requestedTemperature: request.generationOptions
                                    .temperature,
                                samplingConfiguration: requestedSamplingConfiguration,
                                reasoningEntryID: reasoningEntryID,
                                responseEntryID: entryID,
                                context: context, channel: channel)
                            reasoningTokenIDs = phase1.tokenIDs
                            if !phase1.closed {
                                // Cut off mid-thought (budget exhausted before
                                // `</think>`). Don't prefill a truncated thought
                                // into the grammar — signal and finish. Phase 1
                                // already synchronized the GPU on its way out.
                                await Self.emitMetadata(
                                    ["incompleteOutput": true], entryID: entryID, into: channel)
                                return
                            }
                        }

                        // Phase 2 continues from the model's completed reasoning;
                        // carry the raw IDs (no decode/re-encode) so the grammar
                        // starts from the exact post-`</think>` state.
                        let phase2Input =
                            reasoningTokenIDs.isEmpty
                            ? toolAwareInput
                            : Self.continuationInput(
                                from: toolAwareInput, appending: reasoningTokenIDs)
                        // Shared budget (match the unconstrained path): the
                        // envelope continues under the remaining budget, floored
                        // at the completion reserve so it always has room to close
                        // the tool call.
                        let phase2MaxTokens =
                            reasoningTokenIDs.isEmpty
                            ? maxTokens
                            : Swift.max(
                                maxTokens - reasoningTokenIDs.count, completionReserve)

                        var outputBuffer = ""
                        var incomplete = false
                        var generatedTokenCount: Int?
                        do {
                            generatedTokenCount = try GuidedGenerationLoop.run(
                                input: phase2Input,
                                context: context,
                                constraint: constraint,
                                maxTokens: phase2MaxTokens,
                                vocabSize: Int(xgTokenizer.vocabSize),
                                completionReserve: completionReserve,
                                hardReserve: hardReserve,
                                closingBias: closingBias,
                                whitespaceBias: whitespaceBias,
                                whitespaceTokenIDs: whitespaceTokenIDs
                            ) { text in
                                outputBuffer += text
                                GuidedGenerationDiagnosticSink.current?.recordEmit()
                                return !Task.isCancelled
                            }
                        } catch GuidedGenerationError.incompleteOutput {
                            incomplete = true
                        }
                        try Task.checkCancellation()

                        GuidedGenerationDiagnosticSink.current?.recordBuffer(
                            outputBuffer, incompleteOutput: incomplete)

                        await emitRequiredToolCallEvent(
                            outputBuffer: outputBuffer,
                            toolCallsEntryID: toolCallsEntryID,
                            channel: channel
                        )

                        if let generatedTokenCount {
                            // Output total spans both phases (reasoning + envelope);
                            // the reasoning subset is the Phase-1 token count,
                            // clamped ≤ total.
                            let reasoningCount = reasoningTokenIDs.count
                            let totalOutput = generatedTokenCount + reasoningCount
                            await Self.emitUsage(
                                input: .init(
                                    totalTokenCount: toolAwareInput.text.tokens.size,
                                    cachedTokenCount: 0),
                                output: .init(
                                    totalTokenCount: totalOutput,
                                    reasoningTokenCount: Swift.min(reasoningCount, totalOutput)),
                                entryID: entryID, into: channel)
                        }

                        if incomplete {
                            await Self.emitMetadata(
                                ["incompleteOutput": true], entryID: entryID, into: channel)
                        }
                    } else if let schemaJSON {
                        try await runSchemaGeneration(
                            schemaJSON: schemaJSON,
                            input: input,
                            modelID: modelID,
                            derivedCache: derivedCache,
                            requestedMaxTokens: requestedMaxTokens,
                            entryID: entryID,
                            context: context,
                            channel: channel)
                    } else {
                        try await runTextGeneration(
                            reasoningSetup: reasoningSetup,
                            fallbackInput: effectiveInput,
                            requestedMaxTokens: requestedMaxTokens,
                            requestedTemperature: request.generationOptions.temperature,
                            samplingConfiguration: requestedSamplingConfiguration,
                            responseEntryID: entryID,
                            reasoningEntryID: reasoningEntryID,
                            context: context,
                            channel: channel
                        )
                    }

                    Stream.gpu.synchronize()
                }
            } catch is CancellationError {
                // Synchronize GPU before rethrowing to ensure in-flight operations complete.
                // Without this, process teardown can crash with Metal assertions.
                Stream.gpu.synchronize()
                throw CancellationError()
            } catch {
                // Synchronize GPU before rethrowing to ensure in-flight operations complete
                Stream.gpu.synchronize()
                // Re-map xgrammar errors to typed `LanguageModelError` cases
                // where the cause is provably user input (see `mapGrammarError`).
                // Internal-shim failures pass through unchanged.
                if let grammarError = error as? GrammarError {
                    throw Self.mapGrammarError(grammarError)
                }
                throw error
            }
        }

        private struct AllowedToolGenerationResult {
            var responseText = ""
            var toolCalls: [MLXLMCommon.ToolCall] = []
            var rejectedToolCalls: [RejectedToolCall] = []
            var completionInfo: GenerateCompletionInfo?
            var reasoningTokenCount = 0
            var endedInsideReasoning = false
        }

        #if !STENO_VENDORED_ADAPTER
        private func runAllowedToolGeneration(
            input: LMInput,
            toolSpecs: [[String: any Sendable]],
            reasoning: (config: ReasoningConfig, primedInside: Bool)?,
            requestedMaxTokens: Int?,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?,
            reasoningEntryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws -> AllowedToolGenerationResult {
            let params = Self.makeParameters(
                maxTokens: requestedMaxTokens ?? Self.defaultMaxTokens,
                requestedTemperature: requestedTemperature,
                samplingConfiguration: samplingConfiguration)
            let format = context.configuration.toolCallFormat ?? .json
            var router = AllowedToolOutputRouter(
                format: format,
                tools: toolSpecs,
                reasoning: reasoning)
            var protocolDecoder = format.makeProtocolTokenStreamDecoder(
                tokenizer: context.tokenizer,
                tools: toolSpecs,
                stopStrings: context.configuration.effectiveStopStrings)
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var result = AllowedToolGenerationResult()
            let (stream, task) = try generateProtocolTokensTask(
                input: input,
                parameters: params,
                context: context,
                decoder: protocolDecoder)

            do {
                generationLoop: for await generation in stream {
                    try Task.checkCancellation()
                    switch generation {
                    case .token(let token):
                        if var decoder = protocolDecoder {
                            if decoder.isInsideReasoning {
                                result.reasoningTokenCount += 1
                            }
                            var reasoningText = ""
                            var shouldContinue = true
                            let decoderContinues = decoder.push(token) { event in
                                shouldContinue = consumeProtocolEvent(
                                    event, result: &result, reasoningText: &reasoningText)
                                return shouldContinue
                            }
                            protocolDecoder = decoder
                            if !reasoningText.isEmpty {
                                await Self.emit(
                                    text: reasoningText,
                                    entryID: reasoningEntryID,
                                    destination: .reasoning,
                                    into: channel)
                                try Task.checkCancellation()
                            }
                            if !decoderContinues || !shouldContinue {
                                task.cancel()
                                break generationLoop
                            }
                        } else {
                            if router.isInsideReasoning {
                                result.reasoningTokenCount += 1
                            }
                            detokenizer.append(token: token)
                            if let chunk = detokenizer.next() {
                                let reasoningChunks = consumeAllowedEvents(
                                    router.process(chunk), result: &result)
                                for text in reasoningChunks {
                                    await Self.emit(
                                        text: text,
                                        entryID: reasoningEntryID,
                                        destination: .reasoning,
                                        into: channel)
                                    try Task.checkCancellation()
                                }
                            }
                        }
                    case .info(let info):
                        result.completionInfo = info
                    }
                }
            } catch {
                task.cancel()
                await task.value
                throw error
            }

            await task.value
            let finalReasoningText: String
            if var decoder = protocolDecoder {
                result.endedInsideReasoning = decoder.isInsideReasoning
                var reasoningText = ""
                _ = decoder.finish { event in
                    consumeProtocolEvent(
                        event, result: &result, reasoningText: &reasoningText)
                }
                protocolDecoder = decoder
                finalReasoningText = reasoningText
            } else {
                let chunks = consumeAllowedEvents(router.finish(), result: &result)
                finalReasoningText = chunks.joined()
                result.endedInsideReasoning = router.isInsideReasoning
            }
            if !finalReasoningText.isEmpty {
                await Self.emit(
                    text: finalReasoningText,
                    entryID: reasoningEntryID,
                    destination: .reasoning,
                    into: channel)
            }
            if let rejection = result.rejectedToolCalls.first {
                throw RejectedToolCallError(rejection)
            }
            return result
        }

        private func consumeProtocolEvent(
            _ event: TokenStreamEvent,
            result: inout AllowedToolGenerationResult,
            reasoningText: inout String
        ) -> Bool {
            switch event {
            case .reasoning(let text): reasoningText += text
            case .response(let text): result.responseText += text
            case .toolCall(let call): result.toolCalls.append(call)
            case .rejectedToolCall(let rejection): result.rejectedToolCalls.append(rejection)
            case .protocolError(let message): Self.protocolLogger.error("\(message)")
            case .stop: return false
            }
            return true
        }
        #endif

        /// Local SwiftPM targets cannot name MLXLMCommon's package-only framed
        /// token protocol. Use its public generation stream here instead. The
        /// normal detokenized tool router remains unchanged.
        #if STENO_VENDORED_ADAPTER
        private func runAllowedToolGeneration(
            input: LMInput,
            toolSpecs: [[String: any Sendable]],
            reasoning: (config: ReasoningConfig, primedInside: Bool)?,
            requestedMaxTokens: Int?,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?,
            reasoningEntryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws -> AllowedToolGenerationResult {
            let params = Self.makeParameters(
                maxTokens: requestedMaxTokens ?? Self.defaultMaxTokens,
                requestedTemperature: requestedTemperature,
                samplingConfiguration: samplingConfiguration)
            var router = AllowedToolOutputRouter(
                format: context.configuration.toolCallFormat ?? .json,
                tools: toolSpecs,
                reasoning: reasoning)
            var result = AllowedToolGenerationResult()

            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            let (stream, task) = try generateTokensTask(
                input: input,
                parameters: params,
                context: context,
                includeStopToken: false)
            do {
                for await generation in stream {
                    try Task.checkCancellation()
                    switch generation {
                    case .token(let token):
                        if router.isInsideReasoning {
                            result.reasoningTokenCount += 1
                        }
                        detokenizer.append(token: token)
                        if let text = detokenizer.next() {
                            let reasoningChunks = consumeAllowedEvents(
                                router.process(text), result: &result)
                            for chunk in reasoningChunks {
                                await Self.emit(
                                    text: chunk,
                                    entryID: reasoningEntryID,
                                    destination: .reasoning,
                                    into: channel)
                            }
                        }
                    case .info(let info):
                        result.completionInfo = info
                    }
                }
            } catch {
                task.cancel()
                await task.value
                throw error
            }
            await task.value

            let reasoningChunks = consumeAllowedEvents(router.finish(), result: &result)
            for chunk in reasoningChunks {
                await Self.emit(
                    text: chunk,
                    entryID: reasoningEntryID,
                    destination: .reasoning,
                    into: channel)
            }
            result.endedInsideReasoning = router.isInsideReasoning
            if let rejection = result.rejectedToolCalls.first {
                throw RejectedToolCallError(rejection)
            }
            return result
        }
        #endif

        /// Reports a rejected tool call seen on the plain/reasoning streaming path.
        ///
        /// That path builds its decoder with `tools: nil`, so a rejection there is a
        /// protocol anomaly rather than a call the caller could have executed. The
        /// allowed-tool path treats a rejection as significant and throws
        /// ``RejectedToolCallError``, but the decoder closures on this path are
        /// non-throwing, so route the event to the same log channel as
        /// `.protocolError` instead of dropping it silently. `rawTextPreview` is
        /// deliberately never logged: it can carry raw model output and argument
        /// values.
        private static func logRejectedToolCall(_ rejection: RejectedToolCall) {
            let toolName = rejection.toolName ?? "<unknown>"
            protocolLogger.error(
                "rejected tool call: reason=\(rejection.reason.rawValue) tool=\(toolName)")
        }

        private func consumeAllowedEvents(
            _ events: [AllowedToolOutputRouter.Event],
            result: inout AllowedToolGenerationResult
        ) -> [String] {
            var reasoningChunks: [String] = []
            for event in events {
                switch event {
                case .reasoning(let text):
                    reasoningChunks.append(text)
                case .response(let text):
                    result.responseText += text
                case .toolCall(let call):
                    result.toolCalls.append(call)
                case .rejectedToolCall(let rejection):
                    result.rejectedToolCalls.append(rejection)
                }
            }
            return reasoningChunks
        }

        private func emitAllowedUsage(
            _ result: AllowedToolGenerationResult,
            entryID: String,
            channel: LanguageModelExecutorGenerationChannel
        ) async {
            guard let info = result.completionInfo else { return }
            await Self.emitUsage(
                input: .init(
                    totalTokenCount: info.totalPromptTokenCount,
                    cachedTokenCount: info.cachedPromptTokenCount),
                output: .init(
                    totalTokenCount: info.generationTokenCount,
                    reasoningTokenCount: min(
                        result.reasoningTokenCount,
                        info.generationTokenCount)),
                entryID: entryID,
                into: channel)
        }

        private func runSchemaGeneration(
            schemaJSON: String,
            input: LMInput,
            modelID: String,
            derivedCache: DerivedArtifactCache,
            requestedMaxTokens: Int?,
            entryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let xgTokenizer = try await MLXLanguageModel.makeXGTokenizer(
                cache: derivedCache,
                modelID: modelID,
                tokenizer: context.tokenizer)
            let constraint = try await MLXLanguageModel.makeConstraint(
                cache: derivedCache,
                modelID: modelID,
                kind: .json,
                source: schemaJSON,
                tokenizer: xgTokenizer,
                hostTokenizer: context.tokenizer,
                fastForward: true)
            let maxTokens = requestedMaxTokens ?? Self.defaultMaxTokens
            let bias = await MLXLanguageModel.makeTokenizerBias(
                cache: derivedCache,
                modelID: modelID,
                tokenizer: context.tokenizer)
            let structuralReserve = CompletionReserve.estimate(
                schemaJSON: schemaJSON,
                tokenizer: context.tokenizer)
            let completionReserve = Swift.max(structuralReserve * 3, maxTokens / 4)
            let hardReserve = structuralReserve * 8

            let (textStream, textContinuation) = AsyncStream<String>.makeStream()
            async let forwarder: Void = {
                for await text in textStream {
                    await Self.emit(
                        text: text,
                        entryID: entryID,
                        destination: .response,
                        into: channel)
                }
            }()

            var incomplete = false
            var generatedTokenCount: Int?
            do {
                generatedTokenCount = try GuidedGenerationLoop.run(
                    input: input,
                    context: context,
                    constraint: constraint,
                    maxTokens: maxTokens,
                    vocabSize: Int(xgTokenizer.vocabSize),
                    completionReserve: completionReserve,
                    hardReserve: hardReserve,
                    closingBias: bias.closing,
                    whitespaceBias: bias.whitespace,
                    whitespaceTokenIDs: bias.whitespaceTokenIDs
                ) { text in
                    textContinuation.yield(text)
                    GuidedGenerationDiagnosticSink.current?.recordEmit()
                    return !Task.isCancelled
                }
            } catch GuidedGenerationError.incompleteOutput {
                incomplete = true
            }

            let cancellationError: Error?
            do {
                try Task.checkCancellation()
                cancellationError = nil
            } catch {
                cancellationError = error
            }
            textContinuation.finish()
            await forwarder
            if let cancellationError {
                throw cancellationError
            }

            if let generatedTokenCount {
                await Self.emitUsage(
                    input: .init(
                        totalTokenCount: input.text.tokens.size,
                        cachedTokenCount: 0),
                    output: .init(
                        totalTokenCount: generatedTokenCount,
                        reasoningTokenCount: 0),
                    entryID: entryID,
                    into: channel)
            }
            if incomplete {
                await Self.emitMetadata(
                    ["incompleteOutput": true], entryID: entryID, into: channel)
            }
        }

        /// Unconstrained text generation. Used on the no-tools/no-schema
        /// path when the model has no reasoning config to route through.
        private func runUnconstrained(
            input: LMInput,
            requestedMaxTokens: Int?,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?,
            entryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            // Use a finite default when the framework doesn't specify a
            // token limit; there's no grammar to stop the model naturally.
            let params = Self.makeParameters(
                maxTokens: requestedMaxTokens ?? Self.defaultMaxTokens,
                requestedTemperature: requestedTemperature,
                samplingConfiguration: samplingConfiguration
            )

            for await generation in try generate(
                input: input,
                parameters: params,
                context: context
            ) {
                try Task.checkCancellation()
                switch generation {
                case .chunk(let text):
                    await Self.emit(
                        text: text, entryID: entryID, destination: .response, into: channel)
                case .info(let info):
                    // MLX-LM emits one .info event at end-of-generation with
                    // authoritative scalar token counts (`totalPromptTokenCount`
                    // is the rendered prompt, of which `cachedPromptTokenCount`
                    // came from a reused KV-cache prefix; `generationTokenCount`
                    // is the model-generated completion -- see Evaluate.swift's
                    // `GenerateCompletionInfo` definition).
                    await Self.emitUsage(
                        input: .init(
                            totalTokenCount: info.totalPromptTokenCount,
                            cachedTokenCount: info.cachedPromptTokenCount),
                        output: .init(
                            totalTokenCount: info.generationTokenCount, reasoningTokenCount: 0),
                        entryID: entryID, into: channel)
                case .toolCall(_):
                    break
                case .rejectedToolCall(let rejection):
                    throw RejectedToolCallError(rejection)
                }
            }
        }

        /// Dispatches the no-tools/no-schema path: reasoning routing when a
        /// config resolved, otherwise plain unconstrained text.
        private func runTextGeneration(
            reasoningSetup: (input: LMInput, config: ReasoningConfig, primedInside: Bool)?,
            fallbackInput: LMInput,
            requestedMaxTokens: Int?,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?,
            responseEntryID: String,
            reasoningEntryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            if let reasoning = reasoningSetup {
                try await runReasoning(
                    input: reasoning.input,
                    reasoningConfig: reasoning.config,
                    primedInside: reasoning.primedInside,
                    requestedMaxTokens: requestedMaxTokens,
                    requestedTemperature: requestedTemperature,
                    samplingConfiguration: samplingConfiguration,
                    responseEntryID: responseEntryID,
                    reasoningEntryID: reasoningEntryID,
                    context: context,
                    channel: channel)
            } else {
                try await runUnconstrained(
                    input: fallbackInput,
                    requestedMaxTokens: requestedMaxTokens,
                    requestedTemperature: requestedTemperature,
                    samplingConfiguration: samplingConfiguration,
                    entryID: responseEntryID,
                    context: context,
                    channel: channel)
            }
        }

        /// Reasoning-aware unconstrained generation.
        ///
        /// Routes thinking delimited by the model's reasoning markers to
        /// `.reasoning` events and the rest to `.response`, using a raw
        /// protocol-neutral token decoder when the format owns framing, or a
        /// self-owned `NaiveStreamingDetokenizer` for ordinary formats. The loop
        /// sees real token IDs for an accurate reasoning token count.
        #if !STENO_VENDORED_ADAPTER
        private func runReasoning(
            input: LMInput,
            reasoningConfig: ReasoningConfig,
            primedInside: Bool,
            requestedMaxTokens: Int?,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?,
            responseEntryID: String,
            reasoningEntryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let params = Self.makeParameters(
                maxTokens: requestedMaxTokens ?? Self.defaultMaxTokens,
                requestedTemperature: requestedTemperature,
                samplingConfiguration: samplingConfiguration
            )

            var emitter = ReasoningEventEmitter(
                config: reasoningConfig, primedInside: primedInside)
            let format = context.configuration.toolCallFormat ?? .json
            var protocolDecoder = format.makeProtocolTokenStreamDecoder(
                tokenizer: context.tokenizer,
                tools: nil,
                stopStrings: context.configuration.effectiveStopStrings)
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var reasoningTokenCount = 0
            var completionInfo: GenerateCompletionInfo?
            let (stream, task) = try generateProtocolTokensTask(
                input: input,
                parameters: params,
                context: context,
                decoder: protocolDecoder)

            do {
                generationLoop: for await generation in stream {
                    try Task.checkCancellation()
                    switch generation {
                    case .token(let token):
                        if var decoder = protocolDecoder {
                            if decoder.isInsideReasoning {
                                reasoningTokenCount += 1
                            }
                            var segments: [ReasoningEventEmitter.Segment] = []
                            var shouldContinue = true
                            let decoderContinues = decoder.push(token) { event in
                                switch event {
                                case .reasoning(let text): segments.append(.reasoning(text))
                                case .response(let text): segments.append(.response(text))
                                case .toolCall: break
                                case .rejectedToolCall(let rejection):
                                    Self.logRejectedToolCall(rejection)
                                case .protocolError(let message):
                                    Self.protocolLogger.error("\(message)")
                                case .stop: shouldContinue = false
                                }
                                return shouldContinue
                            }
                            protocolDecoder = decoder
                            for segment in segments {
                                await Self.send(
                                    segment, responseEntryID: responseEntryID,
                                    reasoningEntryID: reasoningEntryID, channel: channel)
                            }
                            if !decoderContinues || !shouldContinue {
                                task.cancel()
                                break generationLoop
                            }
                        } else {
                            // One `.token` == one real token, so this is a true
                            // token count. Closing delimiters are deliberately
                            // attributed to reasoning until the emitter consumes
                            // them, then the final usage count is clamped.
                            if emitter.isInsideReasoning {
                                reasoningTokenCount += 1
                            }
                            detokenizer.append(token: token)
                            if let chunk = detokenizer.next() {
                                for segment in emitter.process(chunk) {
                                    await Self.send(
                                        segment, responseEntryID: responseEntryID,
                                        reasoningEntryID: reasoningEntryID, channel: channel)
                                }
                            }
                        }
                    case .info(let info):
                        completionInfo = info
                    }
                }
            } catch {
                task.cancel()
                await task.value
                throw error
            }
            await task.value

            let endedInsideReasoning: Bool
            if var decoder = protocolDecoder {
                endedInsideReasoning = decoder.isInsideReasoning
                var segments: [ReasoningEventEmitter.Segment] = []
                _ = decoder.finish { event in
                    switch event {
                    case .reasoning(let text): segments.append(.reasoning(text))
                    case .response(let text): segments.append(.response(text))
                    case .toolCall, .stop: break
                    case .rejectedToolCall(let rejection):
                        Self.logRejectedToolCall(rejection)
                    case .protocolError(let message):
                        Self.protocolLogger.error("\(message)")
                    }
                    return true
                }
                for segment in segments {
                    await Self.send(
                        segment, responseEntryID: responseEntryID,
                        reasoningEntryID: reasoningEntryID, channel: channel)
                }
                protocolDecoder = decoder
            } else {
                for segment in emitter.finalize() {
                    await Self.send(
                        segment, responseEntryID: responseEntryID,
                        reasoningEntryID: reasoningEntryID, channel: channel)
                }
                endedInsideReasoning = emitter.isInsideReasoning
            }

            // If generation ended while still inside a thinking block, the model
            // was cut off mid-thought (e.g. it exhausted the token budget before
            // emitting `</think>`). Signal it so a consumer doesn't mistake an
            // empty or partial answer for the model's chosen response — mirrors
            // the guided path's `incompleteOutput` convention.
            if endedInsideReasoning {
                await Self.emitMetadata(
                    ["incompleteOutput": true], entryID: responseEntryID, into: channel)
            }

            if let info = completionInfo {
                // Single source of truth for usage: one authoritative
                // `.updateUsage` (the framework's aggregator replaces wholesale,
                // so we must not also rely on per-delta auto-summing). The
                // reasoning count is clamped to never exceed the total.
                await Self.emitUsage(
                    input: .init(
                        totalTokenCount: info.totalPromptTokenCount,
                        cachedTokenCount: info.cachedPromptTokenCount),
                    output: .init(
                        totalTokenCount: info.generationTokenCount,
                        reasoningTokenCount: min(reasoningTokenCount, info.generationTokenCount)),
                    entryID: responseEntryID, into: channel)
            }
        }

        #endif

        #if STENO_VENDORED_ADAPTER
        private func runReasoning(
            input: LMInput,
            reasoningConfig: ReasoningConfig,
            primedInside: Bool,
            requestedMaxTokens: Int?,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?,
            responseEntryID: String,
            reasoningEntryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let params = Self.makeParameters(
                maxTokens: requestedMaxTokens ?? Self.defaultMaxTokens,
                requestedTemperature: requestedTemperature,
                samplingConfiguration: samplingConfiguration)
            var emitter = ReasoningEventEmitter(
                config: reasoningConfig, primedInside: primedInside)
            var completionInfo: GenerateCompletionInfo?

            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var reasoningTokenCount = 0
            let (stream, task) = try generateTokensTask(
                input: input,
                parameters: params,
                context: context,
                includeStopToken: false)
            do {
                for await generation in stream {
                    try Task.checkCancellation()
                    switch generation {
                    case .token(let token):
                        if emitter.isInsideReasoning {
                            reasoningTokenCount += 1
                        }
                        detokenizer.append(token: token)
                        if let text = detokenizer.next() {
                            for segment in emitter.process(text) {
                                await Self.send(
                                    segment,
                                    responseEntryID: responseEntryID,
                                    reasoningEntryID: reasoningEntryID,
                                    channel: channel)
                            }
                        }
                    case .info(let info):
                        completionInfo = info
                    }
                }
            } catch {
                task.cancel()
                await task.value
                throw error
            }
            await task.value
            for segment in emitter.finalize() {
                await Self.send(
                    segment,
                    responseEntryID: responseEntryID,
                    reasoningEntryID: reasoningEntryID,
                    channel: channel)
            }
            if emitter.isInsideReasoning {
                await Self.emitMetadata(
                    ["incompleteOutput": true], entryID: responseEntryID, into: channel)
            }
            if let completionInfo {
                await Self.emitUsage(
                    input: .init(
                        totalTokenCount: completionInfo.totalPromptTokenCount,
                        cachedTokenCount: completionInfo.cachedPromptTokenCount),
                    output: .init(
                        totalTokenCount: completionInfo.generationTokenCount,
                        reasoningTokenCount: min(
                            reasoningTokenCount,
                            completionInfo.generationTokenCount)),
                    entryID: responseEntryID,
                    into: channel)
            }
        }
        #endif

        /// Routes one scanned segment to the appropriate channel entry.
        private static func send(
            _ segment: ReasoningEventEmitter.Segment,
            responseEntryID: String,
            reasoningEntryID: String,
            channel: LanguageModelExecutorGenerationChannel
        ) async {
            switch segment {
            case .reasoning(let text):
                await Self.emit(
                    text: text, entryID: reasoningEntryID, destination: .reasoning, into: channel)
            case .response(let text):
                await Self.emit(
                    text: text, entryID: responseEntryID, destination: .response, into: channel)
            }
        }

        /// Prepares an `LMInput` for the unconstrained reasoning path with
        /// thinking explicitly on, off, or unspecified. Maps the package-
        /// internal `cannotDisableReasoning` to the framework's
        /// `unsupportedCapability` so always-on models surface a typed error
        /// before generation rather than leaking `<think>` into `.response`.
        private static func preparedInput(
            messages: [Chat.Message],
            config: ReasoningConfig,
            thinkingEnabled: Bool?,
            processor: any UserInputProcessor,
            cannotDisableMessage: String
        ) async throws -> LMInput {
            let additionalContext: [String: any Sendable]?
            do {
                additionalContext = try config.promptStrategy
                    .additionalContext(forThinkingEnabled: thinkingEnabled)
            } catch ReasoningError.cannotDisableReasoning {
                throw LanguageModelError.unsupportedCapability(
                    LanguageModelError.UnsupportedCapability(
                        capability: .reasoning,
                        debugDescription: cannotDisableMessage))
            }
            return try await processor.prepare(
                input: UserInput(chat: messages, additionalContext: additionalContext))
        }

        /// Maps a requested reasoning level to a thinking on/off/unspecified
        /// flag. `nil` (no opinion) defers to the strategy's default; any
        /// concrete level means "think" (v1 does not modulate depth); only the
        /// package convention `.custom("no_think")` means "off".
        static func thinkingEnabled(for level: ContextOptions.ReasoningLevel?) -> Bool? {
            guard let level else { return nil }
            switch level {
            case .light, .moderate, .deep:
                return true
            case .custom(let value):
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return normalized == "no_think" ? false : true
            @unknown default:
                // A future level we don't recognize → default to thinking on.
                return true
            }
        }

        /// Decodes the rendered prompt's tail and asks whether it ends inside an
        /// open reasoning block (some model families prefill the opening
        /// delimiter).
        /// Build the Phase-2 continuation input: the tool-aware prompt with the
        /// completed reasoning token IDs appended along the sequence axis.
        ///
        /// The prompt tokens keep whatever rank the model's processor produced
        /// ([N] from LLM processors, [1, N] from VLM processors — VLM `prepare`
        /// requires the batched form), and processed image/video content is
        /// carried through so a VLM's Phase-2 prefill still sees its pixels.
        static func continuationInput(
            from input: LMInput, appending tokenIDs: [Int]
        ) -> LMInput {
            let promptTokens = input.text.tokens
            var appended = MLXArray(tokenIDs.map { Int32($0) })
                .asType(promptTokens.dtype)
            if promptTokens.ndim == 2 {
                appended = appended[.newAxis, 0...]
            }
            return LMInput(
                text: .init(tokens: concatenated([promptTokens, appended], axis: -1)),
                image: input.image,
                video: input.video)
        }

        private static func reasoningPrimedInside(
            input: LMInput, config: ReasoningConfig, tokenizer: any Tokenizer
        ) -> Bool {
            let tokens = input.text.tokens.asArray(Int.self)
            let renderedTail = tokenizer.decode(tokenIds: Array(tokens.suffix(64)))
            return ReasoningEventEmitter.promptEndsInsideReasoning(
                renderedPromptTail: renderedTail, config: config)
        }

        /// Think-then-call Phase 1: generate reasoning unconstrained until
        /// the model closes its thinking block, routing reasoning text to
        /// `.reasoning` events and retaining the raw token IDs to prefill into the
        /// constrained Phase 2.
        ///
        /// Uses the `Task`-returning `generateTokensTask` so the GPU loop is
        /// cancelled and drained at the phase boundary — without that, Phase 2's
        /// prefill could overlap Phase 1's in-flight forward pass on the shared
        /// `Stream` and trip a Metal command-buffer assertion.
        ///
        /// Returns the accumulated token IDs and whether `</think>` actually
        /// closed. If it did not (budget exhausted mid-thought), the caller must
        /// skip Phase 2 rather than prefill a truncated thought into the grammar.
        private func runToolCallReasoningPhase(
            input: LMInput,
            config: ReasoningConfig,
            primedInside: Bool,
            maxTokens: Int,
            requestedTemperature: Double?,
            samplingConfiguration: MLXSamplingConfiguration?,
            reasoningEntryID: String,
            responseEntryID: String,
            context: ModelContext,
            channel: LanguageModelExecutorGenerationChannel
        ) async throws -> (tokenIDs: [Int], closed: Bool) {
            let params = Self.makeParameters(
                maxTokens: maxTokens,
                requestedTemperature: requestedTemperature,
                samplingConfiguration: samplingConfiguration
            )
            var collector = ReasoningTokenCollector(
                config: config, primedInside: primedInside, tokenizer: context.tokenizer
            )

            let (stream, task) = try generateTokensTask(
                input: input, parameters: params, context: context)
            var closed = false
            do {
                for await generation in stream {
                    try Task.checkCancellation()
                    guard case .token(let token) = generation else { continue }
                    for segment in collector.ingest(token) {
                        await Self.send(
                            segment, responseEntryID: responseEntryID,
                            reasoningEntryID: reasoningEntryID, channel: channel)
                    }
                    if collector.shouldStopAfterReasoning {
                        GuidedGenerationDiagnosticSink.current?.recordToolReasoningClose()
                        closed = true
                        break
                    }
                }
            } catch {
                // Drain the generation task before propagating, but do NOT sync
                // here: respond's outer `catch` is the single GPU-sync point for
                // this exit path. Keep one clean GPU sync per exit path —
                // cascading syncs across nested catches can race the Metal
                // command-buffer state during teardown.
                task.cancel()
                _ = await task.value
                throw error
            }
            // Drain the generation task before Phase 2 reuses the Stream.
            task.cancel()
            _ = await task.value
            Stream.gpu.synchronize()

            for segment in collector.finalize() {
                await Self.send(
                    segment, responseEntryID: responseEntryID,
                    reasoningEntryID: reasoningEntryID, channel: channel)
            }
            return (collector.reasoningTokenIDs, closed)
        }

        /// Parses a required-mode tool-calling envelope JSON object and emits
        /// its developer tool call.
        ///
        /// The output buffer is expected to be a JSON object matching the
        /// shape `{"name": <tool-name>, "arguments": <args>}`. Grammars from
        /// `SchemaConverter.encodeToolCallingGrammar` guarantee either that
        /// shape directly (bare JSON) or that shape wrapped in Qwen's
        /// `<tool_call>\n...\n</tool_call>` special-token delimiters --
        /// `unwrapToolCallMarkers` below strips the wrapper if present. The
        /// guided path emits a single `.toolCallDelta` with the arguments JSON
        /// and a freshly minted toolCallID.
        ///
        /// Required mode never degrades malformed or partial output into a
        /// response event.
        private func emitRequiredToolCallEvent(
            outputBuffer: String,
            toolCallsEntryID: String,
            channel: LanguageModelExecutorGenerationChannel
        ) async {
            let unwrapped = Self.unwrapToolCallMarkers(outputBuffer)
            let data = Data(unwrapped.utf8)
            guard
                let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let name = obj["name"] as? String
            else {
                GuidedGenerationDiagnosticSink.current?.recordParse(
                    parsedAsToolCall: false, parsedName: nil)
                return
            }

            GuidedGenerationDiagnosticSink.current?.recordParse(
                parsedAsToolCall: true, parsedName: name)

            guard
                let arguments = obj["arguments"],
                let argumentsData = try? JSONSerialization.data(withJSONObject: arguments),
                let argumentsJSON = String(data: argumentsData, encoding: .utf8)
            else {
                return
            }
            await Self.emitToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: argumentsJSON,
                entryID: toolCallsEntryID,
                into: channel)
        }

        /// Strips Qwen-style `<tool_call>\n...\n</tool_call>` wrapper markers
        /// if present, returning the inner JSON text. Untouched if the buffer
        /// doesn't start with a wrapper -- the `bare_call` grammar alternative
        /// is valid output and parses directly.
        ///
        /// The inner newlines around the JSON come from the Qwen training
        /// format; we're tolerant of whitespace on either side of the markers
        /// so that tokenizer decoding quirks (extra spaces, missing newlines)
        /// don't cause the JSON parse to fail.
        private static func unwrapToolCallMarkers(_ buffer: String) -> String {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let openMarker = "<tool_call>"
            let closeMarker = "</tool_call>"
            guard trimmed.hasPrefix(openMarker) else { return buffer }
            let afterOpen = trimmed.dropFirst(openMarker.count)
            let inner: Substring
            if let closeRange = afterOpen.range(of: closeMarker, options: .backwards) {
                inner = afterOpen[afterOpen.startIndex ..< closeRange.lowerBound]
            } else {
                inner = afterOpen
            }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

#endif  // canImport(FoundationModels)
#endif  // FoundationModelsIntegration
