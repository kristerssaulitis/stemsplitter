import XCTest
@testable import StemCore

/// History verification bar: completed sessions list newest first (in-progress
/// hidden), metadata titles the rows, delete removes dir + entry, and
/// `makeResult` rebuilds a playable mixer model from the stored stems.
@MainActor
final class HistoryModelTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-model-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        base = nil
        try super.tearDownWithError()
    }

    private func makeModel() -> HistoryModel {
        HistoryModel(store: SplitStore(baseDirectory: base))
    }

    /// Container-valid WAV (RIFF....WAVE + padding): passes listing validation;
    /// decode-dependent paths (mixer, peaks) degrade gracefully on this fixture.
    private func writeWAV(_ url: URL) throws {
        var data = Data("RIFF".utf8)
        data.append(Data(repeating: 0, count: 4))
        data.append(Data("WAVE".utf8))
        data.append(Data(repeating: 0xAB, count: 8))
        try data.write(to: url)
    }

    private func makeCompletedSession(title: String, date: Date, splitSeconds: TimeInterval = 0) throws -> SplitSession {
        let store = SplitStore(baseDirectory: base)
        let session = try store.createSession()
        try writeWAV(session.vocalsURL)
        try writeWAV(session.instrumentalURL)
        try store.markCompleted(session)
        store.writeMetadata(SplitMetadata(title: title, date: date, splitSeconds: splitSeconds), for: session.id)
        return session
    }

    // MARK: - Reload

    func testReloadListsCompletedSessionsNewestFirstAndHidesInProgress() throws {
        let model = makeModel()
        _ = try makeCompletedSession(title: "Older", date: Date(timeIntervalSinceNow: -100))
        _ = try makeCompletedSession(title: "Newer", date: Date())
        _ = try SplitStore(baseDirectory: base).createSession() // in-progress: hidden

        model.reload()

        XCTAssertEqual(model.entries.map(\.title), ["Newer", "Older"])
    }

    func testReloadFallsBackToGenericTitleAndDirCreationDate() throws {
        let store = SplitStore(baseDirectory: base)
        let session = try store.createSession()
        try writeWAV(session.vocalsURL)
        try writeWAV(session.instrumentalURL)
        try store.markCompleted(session)
        let model = makeModel()

        model.reload()

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries[0].title, "Split", "metadata-less sessions fall back")
        XCTAssertEqual(
            model.entries[0].id, session.id,
            "fallback date orders by dir creation, session itself still listed")
    }

    // MARK: - Delete

    func testDeleteRemovesSessionDirAndEntry() throws {
        let keep = try makeCompletedSession(title: "Keep", date: Date())
        let gone = try makeCompletedSession(title: "Gone", date: Date(timeIntervalSinceNow: -50))
        let model = makeModel()
        model.reload()

        model.delete(model.entries.first { $0.id == gone.id }!)

        XCTAssertEqual(model.entries.map(\.id), [keep.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.directory.path), "stems are gone for good")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.directory.path))
    }

    func testDeleteIsIdempotentForUnknownEntry() throws {
        let keep = try makeCompletedSession(title: "Keep", date: Date())
        let model = makeModel()
        model.reload()

        model.delete(HistoryModel.Entry(id: UUID(), title: "Ghost", date: Date(), splitSeconds: 0))

        XCTAssertEqual(model.entries.map(\.id), [keep.id], "deleting a phantom entry changes nothing")
    }

    // MARK: - Open (makeResult)

    func testMakeResultRebuildsMixerModelFromStoredStems() async throws {
        let session = try makeCompletedSession(title: "Neon Skyline", date: Date(), splitSeconds: 12)
        let model = makeModel()
        model.reload()

        let result = await model.makeResult(for: model.entries[0])

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Neon Skyline")
        XCTAssertEqual(result?.resultDate, model.entries[0].date)
        // Instrumental is export-only (ResultModel contract), so a
        // vocals+instrumental session shows exactly one lane.
        XCTAssertEqual((result?.tracks ?? []).map(\.name), ["vocals"])
        XCTAssertEqual(result?.outputs.instrumentalURL.lastPathComponent, "instrumental.wav",
                       "instrumental stays available for export")
    }

    func testMakeResultReturnsNilWhenSessionDirVanished() async throws {
        _ = try makeCompletedSession(title: "Gone", date: Date())
        let model = makeModel()
        model.reload()
        let store = SplitStore(baseDirectory: base)
        try FileManager.default.removeItem(at: base.appendingPathComponent(model.entries[0].id.uuidString))

        let result = await model.makeResult(for: model.entries[0])

        XCTAssertNil(result, "vanished session: caller reloads the list")
    }

    // MARK: - Record (completion)

    func testRecordCompletionWritesMetadataAndRefreshesList() throws {
        let store = SplitStore(baseDirectory: base)
        let session = try store.createSession()
        try writeWAV(session.vocalsURL)
        try writeWAV(session.instrumentalURL)
        try store.markCompleted(session)
        let model = makeModel()

        model.recordCompletion(id: session.id, title: "Concert", splitSeconds: 42)

        XCTAssertEqual(model.entries.map(\.title), ["Concert"])
        XCTAssertEqual(model.entries.first?.splitSeconds, 42)
        XCTAssertEqual(store.readMetadata(for: session.id)?.title, "Concert")
    }
}
