import XCTest
@testable import StemCore

/// In-memory KeyValuePersistence double (the injectable persistence abstraction).
private final class InMemoryKeyValuePersistence: KeyValuePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let data {
            values[key] = data
        } else {
            values.removeValue(forKey: key)
        }
    }
}

/// T6 verification bar (ETACalibrator, plan R3-1 remedy / eng E4 / eng E8):
/// two-phase — first run returns a flagged initial estimate, measured rate takes
/// over after the first chunks and persists keyed by model ID (model swap
/// invalidates); persisted-store corruption resets to initial; Low Power Mode
/// (injectable flag) adjusts the estimate and is disclosed.
final class ETACalibratorTests: XCTestCase {

    private var persistence: InMemoryKeyValuePersistence!

    override func setUpWithError() throws {
        try super.setUpWithError()
        persistence = InMemoryKeyValuePersistence()
    }

    private func makeCalibrator(
        lowPower: Bool = false,
        initial: Double = ETACalibrator.gateClassSecondsPerAudioSecond
    ) -> ETACalibrator {
        ETACalibrator(
            persistence: persistence,
            isLowPowerModeEnabled: { lowPower },
            initialSecondsPerAudioSecond: initial)
    }

    // MARK: - Phase 1: flagged initial estimate

    func testFirstRunReturnsFlaggedInitialGateEstimate() {
        // Gate figure: ~30s per minute of audio → 3-minute video ≈ 90s.
        let calibrator = makeCalibrator()
        XCTAssertEqual(
            calibrator.preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 90, isInitial: true))
    }

    func testPreStartEstimateUsesPersistedCalibrationWhenPresent() {
        let first = makeCalibrator()
        first.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 60) // 2.0 s/s

        let second = makeCalibrator() // fresh instance, same persisted store
        XCTAssertEqual(
            second.preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 360, isInitial: true)) // still flagged initial (pre-start)
    }

    // MARK: - Phase 2: measured takeover after first chunks

    func testMeasuredEstimateNilBeforeAnyChunkMeasured() {
        XCTAssertNil(makeCalibrator().measuredEstimate(modelID: "mdx-v1", remainingAudioSeconds: 150))
    }

    func testFirstChunkMeasuredRateTakesOver() {
        let calibrator = makeCalibrator()
        calibrator.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 60)

        let takeover = calibrator.measuredEstimate(modelID: "mdx-v1", remainingAudioSeconds: 150)
        XCTAssertEqual(takeover, ETAEstimate(seconds: 300, isInitial: false))
    }

    func testLaterChunksRefineCumulativeRate() {
        let calibrator = makeCalibrator()
        calibrator.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 60)
        calibrator.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 30)
        // Totals: 60 audio / 90 wall → 1.5 wall-seconds per audio-second.
        XCTAssertEqual(
            calibrator.measuredEstimate(modelID: "mdx-v1", remainingAudioSeconds: 100),
            ETAEstimate(seconds: 150, isInitial: false))
    }

    func testNonPositiveChunkMeasurementsAreIgnored() {
        let calibrator = makeCalibrator()
        calibrator.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 0, wallClockSeconds: 60)
        calibrator.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: -1)
        XCTAssertNil(calibrator.measuredEstimate(modelID: "mdx-v1", remainingAudioSeconds: 150))
    }

    // MARK: - Persistence keyed by model ID (eng E8)

    func testCalibrationPersistsAcrossSessions() {
        makeCalibrator().recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 60)

        // Fresh calibrator over the same persisted store simulates the next launch.
        XCTAssertEqual(
            makeCalibrator().preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 360, isInitial: true))
    }

    func testModelSwapInvalidatesCalibration() {
        let calibrator = makeCalibrator()
        calibrator.recordMeasuredChunk(modelID: "mdx-a", audioSeconds: 30, wallClockSeconds: 60)

        XCTAssertEqual(
            calibrator.preStartEstimate(modelID: "mdx-b", audioDuration: 180),
            ETAEstimate(seconds: 90, isInitial: true), // gate figure, NOT mdx-a's rate
            "eng E8: calibration keyed by model ID — a model swap must not inherit the old rate")
        XCTAssertNil(calibrator.measuredEstimate(modelID: "mdx-b", remainingAudioSeconds: 100))
    }

    // MARK: - Corruption resets to initial

    func testCorruptedPersistedEntryResetsToInitialSilently() {
        let key = ETACalibrator.storageKey(forModelID: "mdx-v1")
        persistence.set(Data("garbage-not-json".utf8), forKey: key)

        let calibrator = makeCalibrator()
        XCTAssertEqual(
            calibrator.preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 90, isInitial: true),
            "corrupt calibration must reset to the initial estimate, never crash")

        XCTAssertNil(persistence.data(forKey: key), "corrupt entry is cleared on read")
        // Next measurement rebuilds clean persisted state.
        calibrator.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 60)
        XCTAssertEqual(
            makeCalibrator().preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 360, isInitial: true))
    }

    func testCorruptionOfOneModelDoesNotTouchOtherModelsCalibration() {
        let healthy = makeCalibrator()
        healthy.recordMeasuredChunk(modelID: "mdx-a", audioSeconds: 30, wallClockSeconds: 60)

        persistence.set(Data([0x00, 0xFF, 0x10]),
                        forKey: ETACalibrator.storageKey(forModelID: "mdx-b"))

        XCTAssertEqual(
            makeCalibrator().preStartEstimate(modelID: "mdx-a", audioDuration: 180),
            ETAEstimate(seconds: 360, isInitial: true))
    }

    // MARK: - Low Power Mode (eng E4, injectable flag)

    func testLowPowerModeInflatesInitialEstimateAndDiscloses() {
        let on = makeCalibrator(lowPower: true)
        XCTAssertTrue(on.isLowPowerAdjustmentActive)
        XCTAssertEqual(
            on.preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 135, isInitial: true)) // 90 × 1.5

        let off = makeCalibrator(lowPower: false)
        XCTAssertFalse(off.isLowPowerAdjustmentActive)
        XCTAssertEqual(
            off.preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 90, isInitial: true))
    }

    func testLowPowerModeAlsoInflatesPersistedCalibration() {
        makeCalibrator().recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 60)
        // Persisted rate 2.0 × 1.5 LPM factor × 180 audio-seconds = 540.
        XCTAssertEqual(
            makeCalibrator(lowPower: true).preStartEstimate(modelID: "mdx-v1", audioDuration: 180),
            ETAEstimate(seconds: 540, isInitial: true))
    }

    func testLowPowerModeDoesNotAlterMeasuredTakeover() {
        let calibrator = makeCalibrator(lowPower: true)
        calibrator.recordMeasuredChunk(modelID: "mdx-v1", audioSeconds: 30, wallClockSeconds: 60)
        // Measured throughput is real; the LPM factor applies to phase 1 only.
        XCTAssertEqual(
            calibrator.measuredEstimate(modelID: "mdx-v1", remainingAudioSeconds: 150),
            ETAEstimate(seconds: 300, isInitial: false))
    }

    func testProcessInfoDefaultReadsRealFlag() {
        // The default closure must be the real ProcessInfo probe (production path);
        // only assert it executes and returns a stable Bool.
        let calibrator = ETACalibrator(persistence: InMemoryKeyValuePersistence())
        let first = calibrator.isLowPowerAdjustmentActive
        XCTAssertEqual(calibrator.isLowPowerAdjustmentActive, first)
        XCTAssertEqual(first, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// FileKeyValuePersistence: production backing for cross-session calibration.
final class FileKeyValuePersistenceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvstore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testPersistsAcrossInstances() throws {
        let url = directory.appendingPathComponent("store.json")
        FileKeyValuePersistence(fileURL: url).set(Data("v1".utf8), forKey: "k1")

        let reloaded = FileKeyValuePersistence(fileURL: url)
        XCTAssertEqual(reloaded.data(forKey: "k1"), Data("v1".utf8))
        XCTAssertNil(reloaded.data(forKey: "missing"))
    }

    func testDeleteRemovesKeyAndMissingFileReadsNil() {
        let url = directory.appendingPathComponent("store.json")
        let store = FileKeyValuePersistence(fileURL: url)
        XCTAssertNil(store.data(forKey: "k1")) // file not yet created
        store.set(Data([1]), forKey: "k1")
        store.set(nil, forKey: "k1")
        XCTAssertNil(store.data(forKey: "k1"))
    }

    func testCorruptFileReadsAsEmptyAndNextWriteRebuilds() throws {
        let url = directory.appendingPathComponent("store.json")
        try Data("### not json ###".utf8).write(to: url)

        let store = FileKeyValuePersistence(fileURL: url)
        XCTAssertNil(store.data(forKey: "k1"), "corrupt file reads as no values")
        store.set(Data("ok".utf8), forKey: "k1")
        XCTAssertEqual(FileKeyValuePersistence(fileURL: url).data(forKey: "k1"), Data("ok".utf8))
    }
}
