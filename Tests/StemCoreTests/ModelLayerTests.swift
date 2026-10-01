import XCTest
import CoreML
@testable import StemCore

/// Model-layer tests (plan T4 + T8; verification bar):
///   - StemModel protocol is chunk-based + async, loadable with a compute-units
///     preference;
///   - MockSeparator is deterministic and actually separates (mid/side +
///     spectral median), so sum-to-source tests mean something;
///   - CoreMLSeparator maps load failure → .modelLoad and a missing bundled
///     StemV2 → .modelMissing (real model intentionally NOT bundled yet —
///     injected bundles/paths exercise both arms);
///   - ModelStore preloads exactly once and exposes load state.
final class ModelLayerTests: XCTestCase {

    // MARK: - Fixtures

    /// Deterministic pseudo-magnitude filler (no RNG: stable across runs).
    private static func pseudoMagnitude(_ i: Int) -> Float {
        let x: Double = Double(i) * 0.137 + 0.9
        let unit: Double = abs(sin(x))
        return Float(0.25 + 0.5 * unit)
    }

    private func makeChunk(frames: Int, bins: Int,
                           fill: (Int, Int) -> (Float, Float)) -> StereoMagnitudeChunk {
        var left = [Float](repeating: 0, count: frames * bins)
        var right = [Float](repeating: 0, count: frames * bins)
        for f in 0..<frames {
            for b in 0..<bins {
                let (l, r) = fill(f, b)
                left[f * bins + b] = l
                right[f * bins + b] = r
            }
        }
        return StereoMagnitudeChunk(frameCount: frames, binCount: bins, left: left, right: right)
    }

    // MARK: - StemModel protocol shape (chunk-based, async, compute-units preference)

    func testComputeUnitsPreferenceLoads() async throws {
        // The protocol boundary is "loadable with a compute-units preference"
        // (plan E3: .all/ANE preference; tests pin .cpuOnly for determinism).
        for units in [MLComputeUnits.all, .cpuAndGPU, .cpuOnly] {
            let model = MockSeparator(computeUnits: units)
            let chunk = makeChunk(frames: 2, bins: 8) { _, _ in (0.5, 0.5) }
            let mask = try await model.separate(chunk)
            XCTAssertEqual(mask.frameCount, 2)
            XCTAssertEqual(mask.binCount, 8)
        }
    }

    // MARK: - MockSeparator: deterministic + actually separates

    func testMockSeparatorIsDeterministicAcrossRunsAndInstances() async throws {
        let chunk = makeChunk(frames: 4, bins: 32) { f, b in
            (Self.pseudoMagnitude(f * 32 + b), Self.pseudoMagnitude(f * 32 + b + 101))
        }
        let a = MockSeparator(computeUnits: .cpuOnly)
        let b = MockSeparator(computeUnits: .cpuOnly)

        let first = try await a.separate(chunk)
        let second = try await a.separate(chunk)      // same instance
        let third = try await b.separate(chunk)       // fresh instance
        XCTAssertEqual(first, second, "same input must yield identical masks")
        XCTAssertEqual(first, third, "determinism must not depend on instance state")
    }

    func testMockSeparatesCenterPannedFromSidePannedContent() async throws {
        // bins 8...12: center-panned plateau (L == R == 1) — vocal-like.
        // bins 24...28: hard-panned plateau (L == 1, R == 0) — instrument-like.
        let chunk = makeChunk(frames: 8, bins: 64) { _, b in
            switch b {
            case 8...12: return (1, 1)   // center (mid only)
            case 24...28: return (1, 0)  // side only
            default: return (0, 0)
            }
        }
        let mask = try await MockSeparator(computeUnits: .cpuOnly).separate(chunk)

        // Interior bins survive the 3-bin median with exact values:
        // center plateau → mid 1, side 0 → mask 1;
        // panned plateau  → mid 0.5, side |L−R| = 1 → mask 0.5/1.5 = 1/3.
        let centerMask = mask.left(frame: 4, bin: 10)
        let sideMask = mask.left(frame: 4, bin: 26)
        XCTAssertEqual(centerMask, 1.0, accuracy: 1e-4, "center-panned content must stay vocal")
        XCTAssertEqual(sideMask, 1.0 / 3.0, accuracy: 1e-4, "hard-panned content must attenuate")
        XCTAssertGreaterThan(centerMask, sideMask, "center content must mask higher than side content")

        // Separation direction, not just mask shape: on the center plateau the
        // masked vocals carry (almost) everything; on the side plateau they
        // carry exactly a third — both stems are non-trivial functions of input.
        let vocals = chunk.applying(mask)
        XCTAssertEqual(vocals.left(frame: 4, bin: 10), 1.0, accuracy: 1e-4)
        XCTAssertEqual(vocals.left(frame: 4, bin: 26), 0.5 / 1.5, accuracy: 1e-4)
    }

    func testMaskGeometryMatchesInputChunk() async throws {
        let chunk = makeChunk(frames: 3, bins: 17) { f, b in
            (Self.pseudoMagnitude(f * 17 + b), Self.pseudoMagnitude(f * 17 + b + 7))
        }
        let mask = try await MockSeparator(computeUnits: .cpuOnly).separate(chunk)
        XCTAssertEqual(mask.frameCount, chunk.frameCount)
        XCTAssertEqual(mask.binCount, chunk.binCount)
        XCTAssertEqual(mask.left.count, chunk.left.count)
        XCTAssertEqual(mask.right.count, chunk.right.count)
        for v in mask.left where v < 0 || v > 1 {
            XCTFail("mask values must be clamped to [0, 1], got \(v)")
        }
    }

    // MARK: - Sum-to-source (complement subtraction regression, plan Section 6)

    func testComplementSubtractionSumsToSource() async throws {
        let chunk = makeChunk(frames: 4, bins: 32) { f, b in
            (Self.pseudoMagnitude(f * 32 + b), Self.pseudoMagnitude(f * 32 + b + 53))
        }
        let mask = try await MockSeparator(computeUnits: .cpuOnly).separate(chunk)
        let vocals = chunk.applying(mask)
        let instrumental = chunk.subtracting(vocals)

        for f in 0..<chunk.frameCount {
            for b in 0..<chunk.binCount {
                let i = f * chunk.binCount + b
                XCTAssertEqual(vocals.left[i] + instrumental.left[i], chunk.left[i],
                               accuracy: 1e-6, "vocals + instrumental must sum to source (L)")
                XCTAssertEqual(vocals.right[i] + instrumental.right[i], chunk.right[i],
                               accuracy: 1e-6, "vocals + instrumental must sum to source (R)")
                XCTAssertEqual(vocals.left[i], chunk.left[i] * mask.left[i],
                               accuracy: 1e-6, "vocals must be mask ⊙ source (L)")
            }
        }
    }

    // MARK: - CoreMLSeparator error mapping (real model intentionally absent)

    func testMissingModelPathThrowsModelMissing() async {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-absent-\(UUID().uuidString).mlmodelc")
        do {
            _ = try await CoreMLSeparator(computeUnits: .cpuOnly, modelURL: bogus)
            XCTFail("absent model must throw")
        } catch {
            XCTAssertEqual(error as? StemError, .modelMissing("StemV2"),
                           "absent resource maps to .modelMissing, got \(error)")
        }
    }

    func testCorruptModelPathThrowsModelLoad() async throws {
        // Present but invalid: a garbage directory posing as StemV2.mlmodelc.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString)", isDirectory: true)
        let fakeModel = dir.appendingPathComponent("StemV2.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeModel, withIntermediateDirectories: true)
        try Data("not a coreml model".utf8).write(to: fakeModel.appendingPathComponent("model.mil"))
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await CoreMLSeparator(computeUnits: .cpuOnly, modelURL: fakeModel)
            XCTFail("corrupt model must throw")
        } catch {
            guard case .modelLoad(let detail) = error as? StemError else {
                return XCTFail("corrupt resource maps to .modelLoad, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty)
        }
    }

    func testInjectedBundleWithoutModelThrowsModelMissing() async throws {
        // Injected bundle (not path): a real bundle directory that lacks the
        // StemV2 resource entirely.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyProbe-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>test.empty-probe</string>
        <key>CFBundleName</key><string>EmptyProbe</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: dir.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try XCTUnwrap(Bundle(url: dir), "probe bundle must load")
        do {
            _ = try await CoreMLSeparator(computeUnits: .cpuOnly, bundle: bundle)
            XCTFail("bundle without StemV2 must throw")
        } catch {
            XCTAssertEqual(error as? StemError, .modelMissing("StemV2"),
                           "got \(error)")
        }
    }

    func testDefaultBundleDegradesGracefully() async {
        // The real model is intentionally NOT bundled yet (verification bar):
        // the shipping-default load path must degrade to .modelMissing — the
        // state whose userMessage is the plan's reinstall alert — never crash.
        do {
            _ = try await CoreMLSeparator(computeUnits: .cpuOnly)
            XCTFail("StemV2 is not bundled yet; default load must throw .modelMissing")
        } catch {
            XCTAssertEqual(error as? StemError, .modelMissing("StemV2"))
            XCTAssertEqual((error as? StemError)?.userMessage,
                           "StemSplitter couldn't start — reinstall")
        }
    }

    // MARK: - ModelStore: preload once at launch + load state (T8)

    private func makeStore(
        factory: @escaping ModelStore.ModelFactory
    ) -> ModelStore {
        ModelStore(factory: factory)
    }

    func testModelStorePreloadsExactlyOnceUnderConcurrency() async {
        let counter = LoadCounter()
        let store = makeStore { units in
            await counter.record()
            return MockSeparator(computeUnits: units)
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await store.preload(computeUnits: .cpuOnly) }
            }
        }
        // A late extra preload after the terminal state must not re-attempt.
        await store.preload(computeUnits: .cpuOnly)

        let calls = await counter.calls
        XCTAssertEqual(calls, 1, "preload is single-flight and once-per-launch")
        let state = await store.loadState
        XCTAssertEqual(state, .loaded(modelID: MockSeparator.modelID))
    }

    func testModelStoreExposesLoadedStateAndModel() async throws {
        let store = makeStore { units in MockSeparator(computeUnits: units) }
        await store.preload(computeUnits: .cpuOnly)

        let state = await store.loadState
        guard case .loaded(let modelID) = state else {
            return XCTFail("expected .loaded, got \(state)")
        }
        XCTAssertEqual(modelID, MockSeparator.modelID)

        let model = try await store.model()
        let mask = try await model.separate(makeChunk(frames: 1, bins: 4) { _, _ in (0.5, 0.5) })
        XCTAssertEqual(mask.frameCount, 1)
    }

    func testModelStoreFailureStateSurfacesStemErrorOnce() async {
        let counter = LoadCounter()
        let store = makeStore { _ in
            await counter.record()
            throw StemError.modelMissing("StemV2")
        }

        await store.preload(computeUnits: .cpuOnly)
        await store.preload(computeUnits: .cpuOnly)  // must NOT retry a failed load

        let calls = await counter.calls
        XCTAssertEqual(calls, 1, "a failed preload is terminal — rescue is reinstall")

        let state = await store.loadState
        guard case .failed(let error) = state else {
            return XCTFail("expected .failed, got \(state)")
        }
        XCTAssertEqual(error, .modelMissing("StemV2"))
        XCTAssertEqual(error.userMessage, "StemSplitter couldn't start — reinstall",
                       "the alert copy rides on StemError (plan S2 row 12)")

        do {
            _ = try await store.model()
            XCTFail("model() must rethrow the stored failure")
        } catch {
            XCTAssertEqual(error as? StemError, .modelMissing("StemV2"))
        }
    }

    func testModelStoreStateStreamSeedsCurrentState() async throws {
        let store = makeStore { _ in throw StemError.modelLoad("corrupt resource") }
        await store.preload(computeUnits: .cpuOnly)

        var first: ModelLoadState?
        for await state in await store.stateStream() {
            first = state
            break  // seeded element arrives first
        }
        XCTAssertEqual(first, .failed(.modelLoad("corrupt resource")),
                       "late subscribers (UI alerts) must see the terminal state")
    }

    func testModelStoreStateStreamEmitsTransitions() async throws {
        // The factory parks mid-load so the subscriber deterministically sees
        // .loading before .loaded lands.
        let store = makeStore { units in
            try await Task.sleep(nanoseconds: 200_000_000)
            return MockSeparator(computeUnits: units)
        }

        let collector = Task { () -> [ModelLoadState] in
            var seen: [ModelLoadState] = []
            for await state in await store.stateStream() {
                seen.append(state)
                if case .loaded = state { break }
            }
            return seen
        }
        // Give the subscriber a beat to register before preloading, so the
        // idle/loading/loaded transitions all land in the buffer.
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.preload(computeUnits: .cpuOnly)

        let seen = await collector.value
        guard case .loaded = seen.last else {
            return XCTFail("stream must end at .loaded, got \(seen)")
        }
        XCTAssertTrue(seen.contains(.idle), "seeded current state must arrive first")
        XCTAssertTrue(seen.contains(.loading), "loading transition must be emitted")
    }
}

/// Actor-guarded call counter for single-flight assertions.
private actor LoadCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}
