import XCTest
@testable import StemCore

// View-model logic tests (approved test plan, macOS run):
//   - selector switch preserves transport position
//   - cancel confirmation gates only after 30 s elapsed
//   - long-video confirm sheet triggers when estimate > 3 min
//   - every non-enumerated pipeline failure routes to "Split failed — try again"
//   - corrupt vs no-audio show distinct copy
// All driven deterministically: scripted MockEngine event streams, a mock
// transport, and an injected clock — no timing, randomness, or services.
@MainActor
final class ViewModelTests: XCTestCase {

    // MARK: - Test doubles

    /// Scripted engine: replays `events` in order then finishes (the contract
    /// guarantees the consumer sees them in order). Records split/cancel calls;
    /// `waitForCancel` resumes immediately if cancel already happened.
    private actor MockEngine: StemEngineProtocol {
        let events: [PipelineEvent]
        private(set) var splitCount = 0
        private(set) var cancelCount = 0
        private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
        private var splitWaiters: [CheckedContinuation<Void, Never>] = []

        init(events: [PipelineEvent] = []) {
            self.events = events
        }

        func split(_ sourceURL: URL) async -> AsyncStream<PipelineEvent> {
            splitCount += 1
            let waiters = splitWaiters
            splitWaiters.removeAll()
            waiters.forEach { $0.resume() }
            let events = self.events
            return AsyncStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func cancel() {
            cancelCount += 1
            let waiters = cancelWaiters
            cancelWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        /// Resumes immediately if a split already started.
        func waitForSplit() async {
            if splitCount > 0 { return }
            await withCheckedContinuation { splitWaiters.append($0) }
        }

        func waitForCancel() async {
            if cancelCount > 0 { return }
            await withCheckedContinuation { cancelWaiters.append($0) }
        }
    }

    private final class MockAudioController: AudioControlling {
        private(set) var loadedURL: URL?
        private(set) var loadedPosition: TimeInterval = -1
        private(set) var loadedPlay = false
        var position: TimeInterval = 0
        var duration: TimeInterval = 180
        var isPlaying = false

        func load(_ url: URL, at position: TimeInterval, play: Bool) {
            loadedURL = url
            loadedPosition = position
            loadedPlay = play
            self.position = position
            isPlaying = play
        }

        func play() { isPlaying = true }
        func pause() { isPlaying = false }
        func seek(to time: TimeInterval) { position = time }
    }

    private final class MockClock {
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    }

    // MARK: - Fixtures

    private let sourceURL = URL(fileURLWithPath: "/tmp/concert.mov")
    private let vocalsURL = URL(fileURLWithPath: "/tmp/vocals.wav")
    private let instrumentalURL = URL(fileURLWithPath: "/tmp/instrumental.wav")

    private func makeVideo(duration: TimeInterval = 120) -> PickedVideo {
        PickedVideo(id: "v1", title: "Concert", duration: duration, localURL: sourceURL)
    }

    private func makeProcessingModel(
        engine: MockEngine,
        clock: MockClock = MockClock()
    ) -> ProcessingModel {
        ProcessingModel(
            engine: engine,
            video: makeVideo(),
            sourceURL: sourceURL,
            now: { clock.date }
        )
    }

    private func makeAppFlow(
        engine: MockEngine,
        probeError: StemError? = nil
    ) -> AppFlowModel {
        AppFlowModel(
            engine: engine,
            makeAudio: { MockAudioController() },
            makePreflight: { video in
                PreflightModel(video: video, probeCheck: { _ in probeError })
            }
        )
    }

    /// Drives the main actor until `predicate` holds (bounded cooperative loop;
    /// no wall-clock sleeps, so this stays deterministic).
    private func settleUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
    }

    private func driveToProcessing(_ app: AppFlowModel, video: PickedVideo) async {
        app.pick(video)
        await app.preflight?.check() // the view awaits this in .task before proceeding
        app.proceedFromPreflight()
    }

    // MARK: - Selector (F10)

    func testSelectorSwitchPreservesTransportPositionAndPlayback() {
        let audio = MockAudioController()
        let model = ResultModel(
            sourceAudioURL: sourceURL,
            outputs: SplitOutputs(vocalsURL: vocalsURL, instrumentalURL: instrumentalURL),
            peaks: [],
            splitSeconds: 42,
            audio: audio
        )
        XCTAssertEqual(model.selected, .original)
        audio.seek(to: 73.5)
        audio.play()

        model.select(.vocals)

        XCTAssertEqual(model.selected, .vocals)
        XCTAssertEqual(audio.loadedURL, vocalsURL)
        XCTAssertEqual(audio.loadedPosition, 73.5, accuracy: 0.001, "position must survive the switch")
        XCTAssertTrue(audio.loadedPlay, "play state must survive the switch")
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.position, 73.5, accuracy: 0.001)

        model.select(.instrumental)
        XCTAssertEqual(audio.loadedURL, instrumentalURL)
        XCTAssertEqual(audio.loadedPosition, 73.5, accuracy: 0.001)
    }

    // MARK: - Cancel confirmation gate (F11)

    func testCancelBefore30sCancelsImmediatelyWithoutConfirmation() async {
        let engine = MockEngine()
        let clock = MockClock()
        let model = makeProcessingModel(engine: engine, clock: clock)
        model.start()

        clock.date = clock.date.addingTimeInterval(10)
        model.requestCancel()

        XCTAssertFalse(model.showsCancelConfirmation, "no confirm under 30 s")
        await engine.waitForCancel()
        let cancelCount = await engine.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancelAtExactly30sIsImmediate() async {
        let engine = MockEngine()
        let clock = MockClock()
        let model = makeProcessingModel(engine: engine, clock: clock)
        model.start()

        clock.date = clock.date.addingTimeInterval(30)
        model.requestCancel()

        XCTAssertFalse(model.showsCancelConfirmation, "gate is strictly elapsed > 30 s")
        await engine.waitForCancel()
        let cancelCount = await engine.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancelAfter30sGatesBehindConfirmation() async {
        let engine = MockEngine()
        let clock = MockClock()
        let model = makeProcessingModel(engine: engine, clock: clock)
        model.start()

        clock.date = clock.date.addingTimeInterval(45)
        model.requestCancel()

        XCTAssertTrue(model.showsCancelConfirmation, "confirmation must gate the cancel")
        var cancelCount = await engine.cancelCount
        XCTAssertEqual(cancelCount, 0, "engine must not be cancelled while asking")

        model.keepGoing()
        XCTAssertFalse(model.showsCancelConfirmation)
        cancelCount = await engine.cancelCount
        XCTAssertEqual(cancelCount, 0, "Keep Going must not cancel")

        model.requestCancel()
        XCTAssertTrue(model.showsCancelConfirmation)
        model.confirmCancel()
        await engine.waitForCancel()
        cancelCount = await engine.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancelledTerminalReturnsToPickerWithoutFailureUI() async {
        let engine = MockEngine(events: [.failure(.cancelled)])
        let app = makeAppFlow(engine: engine)
        await driveToProcessing(app, video: makeVideo())

        await settleUntil { app.route == .picker }

        XCTAssertEqual(app.route, .picker, "cancel returns to the empty picker state")
        XCTAssertNil(app.processing)
        XCTAssertNil(app.processing?.failure)
    }

    // MARK: - Terminal exactly-once (S1)

    func testOnlyFirstTerminalEventWins() {
        let model = makeProcessingModel(engine: MockEngine())
        var terminals: [ProcessingModel.Terminal] = []
        model.onTerminal = { terminals.append($0) }

        model.handle(.failure(.generic("first failure")))
        model.handle(.failure(.generic("second failure")))
        model.handle(.completed(SplitOutputs(vocalsURL: vocalsURL, instrumentalURL: instrumentalURL)))

        XCTAssertEqual(terminals.count, 1, "exactly one terminal per run")
        XCTAssertEqual(terminals.first, .failed(.generic("first failure")))
        XCTAssertEqual(model.failure, .generic("first failure"))
    }

    // MARK: - Failure routing (F3 / F5 / S2)

    func testNonEnumeratedFailureRoutesToGenericSplitFailedState() {
        // Every non-enumerated pipeline error arrives as `.generic` (the one
        // sanctioned sink, StemError contract) and must route to the generic
        // "Split failed — try again" state.
        let generics: [StemError] = [
            .generic("PredictionError: ANE raised exception"),
            .generic("ExportError: share copy failed"),
            .generic("CalibrationCorrupt: store unreadable"),
        ]
        for error in generics {
            let model = makeProcessingModel(engine: MockEngine())
            var terminals: [ProcessingModel.Terminal] = []
            model.onTerminal = { terminals.append($0) }

            model.handle(.failure(error))

            XCTAssertEqual(model.failure?.userMessage, "Split failed — try again")
            XCTAssertEqual(terminals, [.failed(error)])
        }
    }

    func testCorruptAssetAndNoAudioShowDistinctCopy() {
        let corrupt = makeProcessingModel(engine: MockEngine())
        corrupt.handle(.failure(.corruptAsset))

        let noAudio = makeProcessingModel(engine: MockEngine())
        noAudio.handle(.failure(.noAudio))

        // Exact plan copy (frozen StemError.userMessage), and distinct (F5 vs S2).
        XCTAssertEqual(corrupt.failure?.userMessage, "This video can't be processed")
        XCTAssertEqual(noAudio.failure?.userMessage, "No audible audio track found in this video")
        XCTAssertNotEqual(corrupt.failure?.userMessage, noAudio.failure?.userMessage)
    }

    // MARK: - Event projection (F7 / R3-1)

    func testInitialEstimateLabelFlipsOnMeasuredTakeover() {
        let model = makeProcessingModel(engine: MockEngine())

        model.handle(.eta(ETAEstimate(seconds: 90, isInitial: true)))
        XCTAssertEqual(model.eta?.seconds, 90)
        XCTAssertEqual(model.eta?.isInitial, true, "pre-start figure is the 'initial estimate'")

        model.handle(.eta(ETAEstimate(seconds: 71, isInitial: false)))
        XCTAssertEqual(model.eta?.seconds, 71)
        XCTAssertEqual(model.eta?.isInitial, false, "first-chunk takeover replaces it")
    }

    func testPeaksAndProgressAccumulateFromEvents() {
        let model = makeProcessingModel(engine: MockEngine())

        model.handle(.phase(.splitting))
        model.handle(.peaks(StereoPeaks(left: 0.8, right: 0.2)))
        model.handle(.peaks(StereoPeaks(left: 0.3, right: 0.6)))
        model.handle(.progress(fraction: 0.5))
        model.handle(.progress(fraction: 1.5))

        XCTAssertEqual(model.phase, .splitting)
        XCTAssertEqual(model.peaks, [0.8, 0.6], "one combined peak per chunk, in order")
        XCTAssertEqual(model.progress, 1.0, accuracy: 0.0001, "progress clamps to 0...1")
    }

    // MARK: - Long-video confirm (F4)

    func testLongVideoConfirmFiresOnlyWhenEstimateOverThreeMinutes() {
        // Gate-class 30 s/min: a 10-min video estimates 300 s > 3 min → sheet.
        // The Low Power Mode probe is pinned OFF: this test pins the F4 threshold
        // logic, and the live ProcessInfo flag would otherwise ×1.5 the estimate
        // on any host running macOS Low Power Mode (environment-dependent — this
        // suite promises "no timing, randomness, or services").
        let long = PreflightModel(video: makeVideo(duration: 600), isLowPowerMode: { false })
        XCTAssertTrue(long.estimate.isInitial, "pre-start figure is always the initial estimate")
        XCTAssertEqual(long.estimate.seconds, 300, accuracy: 0.001)
        XCTAssertTrue(long.needsLongVideoConfirm)
        long.requestLongVideoConfirm()
        XCTAssertTrue(long.showsLongVideoConfirm)

        // A 4-min video estimates 120 s ≤ 3 min → no sheet.
        let short = PreflightModel(video: makeVideo(duration: 240), isLowPowerMode: { false })
        XCTAssertEqual(short.estimate.seconds, 120, accuracy: 0.001)
        XCTAssertFalse(short.needsLongVideoConfirm)
    }

    func testLongVideoBlocksBeginSplitUntilConfirmed() async {
        let engine = MockEngine()
        let app = makeAppFlow(engine: engine)

        await driveToProcessing(app, video: makeVideo(duration: 600)) // estimate 300 s > 3 min

        XCTAssertEqual(app.route, .preflight, "long video must not start without the confirm")
        XCTAssertEqual(app.preflight?.showsLongVideoConfirm, true)
        let splitCount = await engine.splitCount
        XCTAssertEqual(splitCount, 0)

        app.preflight?.confirmLongVideo()
        app.proceedFromPreflight()

        XCTAssertEqual(app.route, .processing)
        await engine.waitForSplit()
        let confirmedSplitCount = await engine.splitCount
        XCTAssertEqual(confirmedSplitCount, 1, "split starts only after Continue")
    }

    func testShortVideoProceedsStraightToProcessing() async {
        let engine = MockEngine()
        let app = makeAppFlow(engine: engine)

        await driveToProcessing(app, video: makeVideo(duration: 240)) // estimate 120 s <= 3 min

        XCTAssertEqual(app.route, .processing, "no confirm sheet under 3 min")
        await engine.waitForSplit()
        let splitCount = await engine.splitCount
        XCTAssertEqual(splitCount, 1)
    }

    func testPreflightProbeBlockedSurfacesNamedCopy() async {
        let model = PreflightModel(video: makeVideo(), probeCheck: { _ in .noAudio })
        await model.check()
        XCTAssertEqual(model.probe, .blocked(.noAudio))
        XCTAssertEqual(StemError.noAudio.userMessage, "No audible audio track found in this video")
    }

    // MARK: - Low Power Mode (eng E4)

    func testLowPowerModeAdjustsAndDisclosesInitialEstimate() {
        let model = PreflightModel(video: makeVideo(duration: 600), isLowPowerMode: { true })
        XCTAssertEqual(model.estimate.seconds, 450, accuracy: 0.001, "300 s × 1.5 LPM factor")
        XCTAssertTrue(model.lowPowerAdjusted, "disclosed in UI")
        XCTAssertTrue(model.estimate.isInitial)
    }

    // MARK: - Disk preflight formula (plan obligation)

    func testDiskPreflightFormulaHasHeadroomAndScalesWithDuration() {
        XCTAssertEqual(
            PreflightModel.requiredBytes(forDuration: 0),
            1_073_741_824,
            "the 1 GB headroom is the floor")
        XCTAssertGreaterThan(
            PreflightModel.requiredBytes(forDuration: 600),
            PreflightModel.requiredBytes(forDuration: 60),
            "scales with duration (~32 MB per output minute)")
        XCTAssertGreaterThan(
            PreflightModel.requiredBytes(forDuration: 60, extraBytes: 1_000_000),
            PreflightModel.requiredBytes(forDuration: 60),
            "tmp source-copy projection is included")
    }

    // MARK: - Completed terminal → result (F10 payloads)

    func testCompletedTerminalRoutesToResultWithSharePayloads() async {
        let engine = MockEngine(events: [
            .phase(.decoding),
            .phase(.splitting),
            .peaks(StereoPeaks(left: 0.5, right: 0.25)),
            .progress(fraction: 0.5),
            .eta(ETAEstimate(seconds: 70, isInitial: false)),
            .completed(SplitOutputs(vocalsURL: vocalsURL, instrumentalURL: instrumentalURL)),
        ])
        let app = makeAppFlow(engine: engine)
        await driveToProcessing(app, video: makeVideo())

        await settleUntil { app.route == .result }

        guard let result = app.result else {
            return XCTFail("completed split must produce a result model")
        }
        XCTAssertEqual(result.outputs.vocalsURL, vocalsURL)
        XCTAssertEqual(result.outputs.instrumentalURL, instrumentalURL)
        XCTAssertEqual(result.peaks, [0.5], "streamed peaks feed the mini waveforms")

        // Share payloads: primary = both stems; long-press = that stem only;
        // Original shares nothing (stems only per plan).
        XCTAssertEqual(result.shareStemsPayload, [vocalsURL, instrumentalURL])
        XCTAssertEqual(result.sharePayload(for: .vocals), [vocalsURL])
        XCTAssertEqual(result.sharePayload(for: .instrumental), [instrumentalURL])
        XCTAssertEqual(result.sharePayload(for: .original), [])
    }

    // MARK: - Single-flight (CEO row 13 / S4)

    func testPickDuringProcessingIsIgnored() async {
        let engine = MockEngine()
        let app = makeAppFlow(engine: engine)
        await driveToProcessing(app, video: makeVideo())
        await settleUntil { app.processing?.isRunning == true }

        app.pick(PickedVideo(id: "v2", title: "Other", duration: 60, localURL: sourceURL))

        XCTAssertEqual(app.route, .processing, "picker is single-flight during processing")
        XCTAssertEqual(app.video?.id, "v1")
    }

    // MARK: - Session navigation (F9a)

    func testNewSplitShowsExportFirstNoticeAndNextPickClearsIt() async {
        let engine = MockEngine(events: [
            .completed(SplitOutputs(vocalsURL: vocalsURL, instrumentalURL: instrumentalURL)),
        ])
        let app = makeAppFlow(engine: engine)
        await driveToProcessing(app, video: makeVideo())
        await settleUntil { app.route == .result }

        app.newSplit()

        XCTAssertEqual(app.route, .picker)
        XCTAssertTrue(app.showsExportFirstNotice, "inline 'Export first — splits don't persist.' notice")
        XCTAssertNil(app.result)

        app.pick(makeVideo())
        XCTAssertFalse(app.showsExportFirstNotice, "next pick clears the notice")
        XCTAssertEqual(app.route, .preflight)
    }

    // MARK: - Interruption (F12)

    func testInterruptedSplitOffersStartAgainNamingVideoThenDiscardParks() async {
        let engine = MockEngine() // no terminal events: simulates an interrupted run
        let app = makeAppFlow(engine: engine)
        await driveToProcessing(app, video: makeVideo())
        await settleUntil { app.processing?.isRunning == true }

        app.interruptSplit()

        XCTAssertEqual(app.startAgain?.videoTitle, "Concert", "modal names the video")

        app.startAgainConfirmed()
        XCTAssertNil(app.startAgain)
        XCTAssertEqual(app.route, .processing)
        XCTAssertTrue(app.processing?.isRunning == true, "Start again restarts the split")

        app.interruptSplit()
        app.startAgainDiscarded()
        XCTAssertNil(app.startAgain)
        XCTAssertEqual(app.route, .picker, "Discard parks on the empty picker state")
    }

    // MARK: - Export feedback (F6)

    func testExportFinishedShowsAndDismissesToast() {
        let audio = MockAudioController()
        let model = ResultModel(
            sourceAudioURL: sourceURL,
            outputs: SplitOutputs(vocalsURL: vocalsURL, instrumentalURL: instrumentalURL),
            peaks: [],
            splitSeconds: 84,
            audio: audio
        )
        XCTAssertFalse(model.exportToastVisible)
        model.exportFinished()
        XCTAssertTrue(model.exportToastVisible, "success toast after share/Save completes")
        model.dismissExportToast()
        XCTAssertFalse(model.exportToastVisible)
    }

    // MARK: - Scrub

    func testScrubFractionSeeksWithinDuration() {
        let audio = MockAudioController()
        audio.duration = 180
        let model = ResultModel(
            sourceAudioURL: sourceURL,
            outputs: SplitOutputs(vocalsURL: vocalsURL, instrumentalURL: instrumentalURL),
            peaks: [],
            splitSeconds: 10,
            audio: audio
        )
        model.scrub(toFraction: 0.5)
        XCTAssertEqual(audio.position, 90, accuracy: 0.001)
        model.scrub(toFraction: 2)
        XCTAssertEqual(audio.position, 180, accuracy: 0.001, "clamps past the end")
        model.scrub(toFraction: -1)
        XCTAssertEqual(audio.position, 0, accuracy: 0.001, "clamps before the start")
    }
}
