import Foundation
import CoreML
import os

/// Load state of the app's separation model (plan T8 + S2 row 12/15).
///
/// The store preloads the model once at launch (CEO row 15: async preload cuts
/// first-split latency; ANE warm-up leaves the critical path) and exposes the
/// state so the UI can raise the plan's `ModelLoadError` alert
/// ("StemSplitter couldn't start — reinstall", the copy on `StemError`).
public enum ModelLoadState: Equatable, Sendable {

    /// No preload attempted yet (before the launch call).
    case idle

    /// Preload in flight (model compile/load on first launch after install).
    case loading

    /// Model ready; carries `modelID` (eng E8 calibration keying).
    case loaded(modelID: String)

    /// Preload failed. The carried `StemError` is `.modelMissing` or
    /// `.modelLoad` by construction — the alert drives the reinstall rescue.
    case failed(StemError)
}

/// Owns the app's single loaded `StemModel` (plan S1 "ModelStore (bundled
/// .mlmodelc)").
///
/// - Preload is strictly once per launch: concurrent or repeated `preload()`
///   calls share one load (single-flight); a finished `.loaded`/`.failed`
///   state is never re-attempted (the `.modelLoad` rescue is "reinstall" —
///   an in-process retry cannot heal a corrupt bundle).
/// - `model()` is the engine's acquisition point: it awaits (or triggers) the
///   preload and either returns the loaded model or rethrows the stored
///   `StemError`, so no caller can race the load.
/// - `stateStream()` gives the UI a subscription seeded with the current
///   state; `.failed` carries the error whose `userMessage` is the alert copy.
///
/// Launch wiring (app layer): `await ModelStore.shared.preload()` in an early
/// `.task` — preload duration is measured and logged (T8 verify).
public actor ModelStore {

    /// App-wide store over the bundled StemV2 (CoreMLSeparator's default
    /// bundle lookup). The factory is injectable for tests.
    public static let shared = ModelStore()

    private static let log = Logger(subsystem: "com.stemsplitter.app", category: "model")

    /// Builds the model under a compute-units preference. Default: the real
    /// bundled StemV2 via `CoreMLSeparator`.
    public typealias ModelFactory = @Sendable (MLComputeUnits) async throws -> any StemModel

    private let factory: ModelFactory
    private let broadcast = StateBroadcast()

    private var state: ModelLoadState = .idle
    private var loadedModel: (any StemModel)?
    private var loadTask: Task<Void, Never>?

    public init(factory: @escaping ModelFactory = { try await CoreMLSeparator(computeUnits: $0) }) {
        self.factory = factory
    }

    /// Current state snapshot.
    public var loadState: ModelLoadState { state }

    /// Preload the model once at launch. Idempotent and single-flight:
    /// concurrent callers await the same load; after a terminal state
    /// (`.loaded`/`.failed`) this returns without re-attempting.
    public func preload(computeUnits: MLComputeUnits = .all) async {
        if let task = loadTask {
            await task.value
            return
        }
        switch state {
        case .loaded, .failed:
            return  // once per launch — never re-attempt a terminal state
        case .idle, .loading:
            break
        }
        let task = Task { await self.performLoad(computeUnits) }
        loadTask = task
        await task.value
    }

    /// The loaded model, awaiting/triggering the preload if needed.
    /// Throws the stored `StemError` (`.modelMissing`/`.modelLoad`) on failure.
    public func model() async throws -> any StemModel {
        if let loadedModel { return loadedModel }
        if case .failed(let error) = state { throw error }
        await preload()
        if let loadedModel { return loadedModel }
        if case .failed(let error) = state { throw error }
        throw StemError.modelLoad("ModelStore: preload finished without a model")
    }

    /// Subscribe to state changes; the stream yields the current state first
    /// (so a late subscriber never misses the terminal state), then every
    /// transition until cancelled.
    public func stateStream() -> AsyncStream<ModelLoadState> {
        broadcast.subscribe(current: state)
    }

    private func performLoad(_ computeUnits: MLComputeUnits) async {
        setState(.loading)
        let start = ContinuousClock.now
        Self.log.info("model preload started (compute units: \(String(describing: computeUnits), privacy: .public))")
        do {
            let model = try await factory(computeUnits)
            loadedModel = model
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            Self.log.info("model preload finished in \(String(format: "%.1f", ms)) ms → \(type(of: model).modelID, privacy: .public)")
            setState(.loaded(modelID: type(of: model).modelID))
        } catch {
            let stemError = (error as? StemError) ?? StemError.modelLoad(String(describing: error))
            Self.log.error("model preload failed: \(String(describing: stemError), privacy: .public)")
            setState(.failed(stemError))
        }
        loadTask = nil
    }

    private func setState(_ newState: ModelLoadState) {
        state = newState
        broadcast.broadcast(newState)
    }
}

/// Lock-guarded continuation registry so stream bookkeeping never depends on
/// actor reentrancy timing (registration happens synchronously at subscribe).
private final class StateBroadcast: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ModelLoadState>.Continuation] = [:]

    func subscribe(current: ModelLoadState) -> AsyncStream<ModelLoadState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(current)
            self.lock.lock()
            self.continuations[id] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    func broadcast(_ state: ModelLoadState) {
        lock.lock()
        let sinks = Array(continuations.values)
        lock.unlock()
        for sink in sinks { sink.yield(state) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
