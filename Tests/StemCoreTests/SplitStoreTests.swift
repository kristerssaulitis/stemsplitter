import XCTest
@testable import StemCore

/// T6 verification bar: session dir create/list under Caches/Splits/<uuid> with
/// .inprogress marker; purge-on-launch; orphan purge (inprogress markers from
/// dead sessions); garbage-header split dirs validated and deleted.
final class SplitStoreTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitstore-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        base = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> SplitStore {
        SplitStore(baseDirectory: base)
    }

    /// Writes a minimal valid WAV container header (RIFF....WAVE + padding).
    private func writeWAV(_ url: URL, magic: String = "RIFF", form: String = "WAVE", size: Int = 12) throws {
        var data = Data(magic.utf8)
        data.append(Data(repeating: 0, count: 4)) // size field
        data.append(Data(form.utf8))
        if size > data.count {
            data.append(Data(repeating: 0xAB, count: size - data.count))
        }
        try data.write(to: url)
    }

    // MARK: - Create / list with .inprogress marker

    func testCreateSessionCreatesUUIDDirWithInProgressMarker() throws {
        let store = makeStore()
        let session = try store.createSession()

        XCTAssertTrue(session.directory.path.hasPrefix(base.path))
        XCTAssertEqual(session.id.uuidString, session.directory.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.directory.appendingPathComponent(SplitStore.markerFileName).path))
        XCTAssertTrue(session.isInProgress)
        XCTAssertEqual(
            session.vocalsURL,
            session.directory.appendingPathComponent(SplitStore.vocalsFileName))
        XCTAssertEqual(
            session.instrumentalURL,
            session.directory.appendingPathComponent(SplitStore.instrumentalFileName))
    }

    func testListSessionsReturnsCreatedSessionInProgress() throws {
        let store = makeStore()
        let session = try store.createSession()
        XCTAssertEqual(store.listSessions(), [session])
    }

    // MARK: - Mark completed

    func testMarkCompletedRemovesMarkerAndListsCompleted() throws {
        let store = makeStore()
        let session = try store.createSession()
        try writeWAV(session.vocalsURL)
        try writeWAV(session.instrumentalURL)

        try store.markCompleted(session)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: session.directory.appendingPathComponent(SplitStore.markerFileName).path))

        let listed = store.listSessions()
        XCTAssertEqual(listed.count, 1)
        XCTAssertFalse(listed[0].isInProgress)
        XCTAssertEqual(listed[0].id, session.id)
    }

    func testMarkCompletedThrowsForUnknownSession() {
        let store = makeStore()
        let phantom = SplitSession(
            id: UUID(),
            directory: base.appendingPathComponent(UUID().uuidString, isDirectory: true),
            vocalsURL: URL(fileURLWithPath: "/nonexistent/vocals.wav"),
            instrumentalURL: URL(fileURLWithPath: "/nonexistent/instrumental.wav"),
            isInProgress: true)
        XCTAssertThrowsError(try store.markCompleted(phantom))
    }

    // MARK: - Purge on launch

    func testPurgeOnLaunchRemovesAllSessionDirs() throws {
        let store = makeStore()
        let completed = try store.createSession()
        try writeWAV(completed.vocalsURL)
        try writeWAV(completed.instrumentalURL)
        try store.markCompleted(completed)
        _ = try store.createSession() // in-progress orphan

        store.purgeOnLaunch()

        XCTAssertTrue(store.listSessions().isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "expected empty base, found \(leftovers)")
    }

    func testPurgeOnLaunchIsIdempotentWhenBaseMissing() {
        let store = makeStore() // base never created
        store.purgeOnLaunch()
        XCTAssertTrue(store.listSessions().isEmpty)
    }

    // MARK: - Orphan purge (.inprogress markers from dead sessions)

    func testOrphanPurgeRemovesOnlyInProgressSessions() throws {
        let store = makeStore()
        let completed = try store.createSession()
        try writeWAV(completed.vocalsURL)
        try writeWAV(completed.instrumentalURL)
        try store.markCompleted(completed)
        let orphan = try store.createSession()

        store.purgeOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.directory.path))
        let listed = store.listSessions()
        XCTAssertEqual(listed.map(\.id), [completed.id])
        XCTAssertEqual(listed.map(\.isInProgress), [false])
    }

    func testPurgeSessionRemovesOnlyNamedSession() throws {
        let store = makeStore()
        let a = try store.createSession()
        let b = try store.createSession()

        store.purgeSession(id: a.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.directory.path))
    }

    // MARK: - Garbage-header validation (eng E9 dir-level net)

    func testCompletedDirWithGarbageHeaderWAVIsDeletedNotListed() throws {
        let store = makeStore()
        let good = try store.createSession()
        try writeWAV(good.vocalsURL)
        try writeWAV(good.instrumentalURL)
        try store.markCompleted(good)

        let badMagic = try store.createSession()
        try writeWAV(badMagic.vocalsURL, magic: "JUNK", form: "JUNK")
        try writeWAV(badMagic.instrumentalURL)
        try store.markCompleted(badMagic)

        let truncated = try store.createSession()
        try Data("RIFF".utf8).write(to: truncated.vocalsURL) // 4 bytes: no room for header
        try writeWAV(truncated.instrumentalURL)
        try store.markCompleted(truncated)

        let listed = store.listSessions()

        XCTAssertEqual(listed.map(\.id), [good.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: badMagic.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: truncated.directory.path))
    }

    func testRF64HeaderIsAcceptedAsValid() throws {
        let store = makeStore()
        let session = try store.createSession()
        // eng E6 >4GB variant: EBU Tech 3306 RF64 — magic RF64, form stays WAVE.
        try writeWAV(session.vocalsURL, magic: "RF64", form: "WAVE")
        try writeWAV(session.instrumentalURL)
        try store.markCompleted(session)

        XCTAssertEqual(store.listSessions().map(\.id), [session.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
    }

    func testInProgressDirIsListedEvenBeforeAnyOutputExists() throws {
        let store = makeStore()
        let session = try store.createSession() // zero files written yet
        XCTAssertEqual(store.listSessions().map(\.id), [session.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
    }

    // MARK: - Default location

    func testDefaultBaseDirectoryIsCachesSplits() {
        let url = SplitStore.defaultBaseDirectory()
        XCTAssertEqual(url.lastPathComponent, "Splits")
        XCTAssertTrue(url.path.contains("Caches"))
    }
}
