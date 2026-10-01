import Foundation

/// Key-value persistence abstraction for the ETA calibration store (plan R3-1
/// "small persisted store"). Injectable for tests — production uses
/// `FileKeyValuePersistence`; tests use an in-memory double.
///
/// Values are opaque `Data` blobs; the calibrator owns their encoding. A
/// missing key returns `nil`; readers must treat undecodable data as corruption
/// (the calibrator resets to the initial estimate, plan test edge case
/// "Calibration store corrupted → resets to initial estimate silently").
public protocol KeyValuePersistence: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// Production `KeyValuePersistence`: one JSON file mapping keys to `Data`
/// values, written atomically. The file location is injected (pass a URL under
/// Application Support — never under `Caches/Splits`, which `SplitStore`
/// purges). A corrupt or unreadable file reads as "no values"; the next write
/// rebuilds it. All state is `let` and every read/write is lock-guarded, so the
/// class is safely `Sendable`.
public final class FileKeyValuePersistence: Sendable, KeyValuePersistence {

    private let fileURL: URL
    private let lock = NSLock()

    /// - Parameter fileURL: path of the backing JSON file (created on demand).
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return dictionary()[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var values = dictionary()
        if let data {
            values[key] = data
        } else {
            values.removeValue(forKey: key)
        }
        guard let encoded = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: fileURL, options: .atomic)
    }

    /// A file that fails to decode (corruption, truncation) reads as empty and
    /// is rebuilt by the next `set`.
    private func dictionary() -> [String: Data] {
        guard let raw = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: Data].self, from: raw) else {
            return [:]
        }
        return values
    }
}

/// Two-phase ETA calibration (plan R3-1 remedy; eng E4, E8; T6).
///
/// Phase 1 — pre-start: the estimate shown before any chunk is processed is the
/// last-known persisted per-device calibration for the model if one exists,
/// else the ~30s-per-minute gate-class (iPhone 17) figure — flagged
/// `isInitial == true` either way (frozen `PipelineEvent.eta` contract: the
/// label is the UI's "initial estimate" disclosure).
///
/// Phase 2 — in-flight: the first chunk's measured throughput takes over
/// (`measuredEstimate` returns non-nil with `isInitial == false`); later chunks
/// refine the rate as a running cumulative average, and every measurement is
/// persisted keyed by model ID so calibration survives across app sessions.
///
/// eng E4 (Low Power Mode): when the injectable `isLowPowerModeEnabled` flag is
/// true, phase-1 rates are multiplied by a conservative `lowPowerMultiplier`
/// (LPM throttles the device, so persisted calibration measured at full power
/// would understate). `isLowPowerAdjustmentActive` tells the UI to disclose the
/// adjustment. The measured phase-2 figure is never adjusted — it is real
/// throughput.
///
/// eng E8: calibration is keyed by model ID/version — a model swap invalidates
/// the stored rate (per-model keys).
///
/// Corruption: a persisted entry that fails to decode is cleared and phase 1
/// silently falls back to the initial gate figure (test plan edge case).
public final class ETACalibrator: @unchecked Sendable {

    /// Wall-clock seconds per audio second. The plan gate figure — ~30s per
    /// minute of audio — is 0.5 wall-seconds per audio-second.
    public static let gateClassSecondsPerAudioSecond = 30.0 / 60.0

    /// Conservative phase-1 inflation applied in Low Power Mode (eng E4).
    public static let lowPowerMultiplier = 1.5

    /// Injectable Low Power Mode probe (plan: "ProcessInfo.isLowPowerModeEnabled
    /// read behind an injectable closure so tests pass true/false").
    private let isLowPowerModeEnabled: @Sendable () -> Bool

    private let persistence: KeyValuePersistence
    private let lock = NSLock()

    private struct StoredCalibration: Codable, Equatable {
        var secondsPerAudioSecond: Double
        var measuredAudioSeconds: Double
        var measuredWallSeconds: Double
    }

    /// - Parameters:
    ///   - persistence: the key-value store backing calibration across sessions.
    ///   - isLowPowerModeEnabled: defaults to `ProcessInfo` (eng E4); tests pass
    ///     `true`/`false` closures.
    ///   - initialSecondsPerAudioSecond: phase-1 fallback rate when no
    ///     calibration is persisted for the model (gate figure by default).
    public init(
        persistence: KeyValuePersistence,
        isLowPowerModeEnabled: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        initialSecondsPerAudioSecond: Double = ETACalibrator.gateClassSecondsPerAudioSecond
    ) {
        self.persistence = persistence
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.initialSecondsPerAudioSecond = initialSecondsPerAudioSecond
    }

    private let initialSecondsPerAudioSecond: Double

    /// Storage key for one model's calibration. Exposed so tests (and rescue
    /// tooling) can target the exact entry, e.g. to inject corruption.
    public static func storageKey(forModelID modelID: String) -> String {
        "eta.calibration.\(modelID)"
    }

    /// `true` when the eng E4 Low Power Mode adjustment is in effect right now —
    /// the UI discloses the adjusted estimate when this is true at preflight.
    public var isLowPowerAdjustmentActive: Bool {
        isLowPowerModeEnabled()
    }

    // MARK: - Phase 1: pre-start estimate (isInitial == true)

    /// The pre-start figure for `audioDuration` seconds of source audio:
    /// persisted calibration for `modelID` if present (LPM-inflated when the
    /// flag is on), else the gate-class figure labeled "initial estimate".
    /// Always `isInitial == true` — takeover to the measured figure happens via
    /// `measuredEstimate` once the first chunk completes.
    public func preStartEstimate(modelID: String, audioDuration: Double) -> ETAEstimate {
        let rate = persistedRate(modelID: modelID) ?? initialSecondsPerAudioSecond
        let effective = isLowPowerModeEnabled() ? rate * Self.lowPowerMultiplier : rate
        return ETAEstimate(seconds: max(0, audioDuration) * effective, isInitial: true)
    }

    // MARK: - Phase 2: measured takeover (isInitial == false)

    /// Record one processed chunk's throughput. The first record makes
    /// `measuredEstimate` non-nil (R3-1: "the first chunk's measured throughput
    /// takes over"); every record refines the cumulative rate and persists it
    /// keyed by model ID (R3-1: calibration persists across app sessions).
    /// Non-positive inputs are ignored.
    public func recordMeasuredChunk(modelID: String, audioSeconds: Double, wallClockSeconds: Double) {
        guard audioSeconds > 0, wallClockSeconds > 0, wallClockSeconds.isFinite, audioSeconds.isFinite else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        var stored = storedCalibration(modelID: modelID) ?? StoredCalibration(
            secondsPerAudioSecond: 0, measuredAudioSeconds: 0, measuredWallSeconds: 0)
        stored.measuredAudioSeconds += audioSeconds
        stored.measuredWallSeconds += wallClockSeconds
        stored.secondsPerAudioSecond = stored.measuredWallSeconds / stored.measuredAudioSeconds
        if let encoded = try? JSONEncoder().encode(stored) {
            persistence.set(encoded, forKey: Self.storageKey(forModelID: modelID))
        }
    }

    /// The measured takeover estimate for `remainingAudioSeconds` of unprocessed
    /// audio — `nil` until at least one chunk has been measured for the model.
    /// `isInitial == false`. The measured rate is real throughput and is
    /// deliberately NOT adjusted for Low Power Mode.
    public func measuredEstimate(modelID: String, remainingAudioSeconds: Double) -> ETAEstimate? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = storedCalibration(modelID: modelID),
              stored.measuredAudioSeconds > 0 else {
            return nil
        }
        return ETAEstimate(
            seconds: max(0, remainingAudioSeconds) * stored.secondsPerAudioSecond,
            isInitial: false)
    }

    // MARK: - Private

    /// Read + decode one model's persisted calibration. Corrupt data is treated
    /// as corruption: the entry is CLEARED (reset) and `nil` returned, so phase
    /// 1 silently falls back to the initial figure and the next
    /// `recordMeasuredChunk` rebuilds clean state.
    private func storedCalibration(modelID: String) -> StoredCalibration? {
        let key = Self.storageKey(forModelID: modelID)
        guard let raw = persistence.data(forKey: key) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredCalibration.self, from: raw),
              stored.secondsPerAudioSecond.isFinite, stored.secondsPerAudioSecond > 0 else {
            persistence.set(nil, forKey: key)
            return nil
        }
        return stored
    }

    private func persistedRate(modelID: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return storedCalibration(modelID: modelID)?.secondsPerAudioSecond
    }
}
