import XCTest
@testable import AtlasCore

final class DownloadRecoveryTests: XCTestCase {
    var root: URL!
    var storage: StorageManager!
    var sample: WikipediaPackage!
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_RECOVERY_TESTS"] == "1" else { throw XCTSkip("Requires local throttled range fixture server") }
        root=FileManager.default.temporaryDirectory.appendingPathComponent("AtlasRecovery-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        storage=StorageManager(store:FileBookmarkStore(file:root.appendingPathComponent("selection.json")))
        let live=URL(fileURLWithPath:"/tmp/AtlasStage2LiveLibrary")
        let id=try LibraryLayout().establish(at:live).id
        sample=try XCTUnwrap(PackageManifest(access:LibraryAccess(root:live,libraryID:id)).load().first?.package)
        sample.downloadURL=URL(string:"http://127.0.0.1:8917/range")!
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at:root) } }
    private func waitFor(_ manager:DownloadManager,_ predicate:(PackageRecord)->Bool) async throws -> PackageRecord {
        for _ in 0..<200 {
            if let record=await manager.snapshot().records.first, predicate(record) { return record }
            try await Task.sleep(for:.milliseconds(50))
        }
        throw AtlasError.incompleteDownload
    }
    func testPauseRestartResumeVerifyAndDelete() async throws {
        _ = try await storage.select(root)
        let manager=DownloadManager(storage:storage); try await manager.start(sample)
        _ = try await waitFor(manager) {$0.receivedBytes > 0 && $0.state == .downloading}
        await manager.pause(sample.id)
        let partial=try await waitFor(manager) {$0.state == .paused}
        let partialURL=root.appendingPathComponent(partial.partialPath)
        let saved=(try partialURL.resourceValues(forKeys:[.fileSizeKey])).fileSize!
        XCTAssertGreaterThan(saved,0); XCTAssertLessThan(Int64(saved),sample.downloadBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(partial.relativePath).path))
        // Simulate the durable state left by a killed process rather than a graceful pause.
        let access=try await storage.acquire(); var interrupted=partial; interrupted.state = .downloading
        try PackageManifest(access:access).save(interrupted)
        let restarted=DownloadManager(storage:storage); try await restarted.connect()
        let recovered=await restarted.snapshot().records.first
        XCTAssertEqual(recovered?.state,.paused)
        try await restarted.resume(sample.id)
        let completed=try await waitFor(restarted) {$0.state == .installed || $0.state == .failed || $0.state == .corrupted}
        XCTAssertEqual(completed.state,.installed,completed.message ?? ""); XCTAssertEqual(completed.verification,.verified)
        XCTAssertFalse(FileManager.default.fileExists(atPath:partialURL.path))
        try await restarted.verify(sample.id)
        let verified=try await waitFor(restarted) {$0.state == .installed}
        XCTAssertEqual(verified.verification,.verified)
        let installedFile=try FileHandle(forWritingTo:root.appendingPathComponent(completed.relativePath))
        try installedFile.write(contentsOf:Data([0,0,0,0])); try installedFile.close()
        try await restarted.verify(sample.id)
        let corrupted=try await waitFor(restarted) {$0.state == .corrupted}
        XCTAssertEqual(corrupted.verification,.failed)
        try await restarted.delete(sample.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(completed.relativePath).path))
    }
    func testUnavailableLibraryNeverFallsBackAndRecovers() async throws {
        _ = try await storage.select(root)
        let manager=DownloadManager(storage:storage); try await manager.start(sample)
        _ = try await waitFor(manager) {$0.receivedBytes > 0 && $0.state == .downloading}
        let disconnected=root.appendingPathExtension("disconnected")
        try FileManager.default.moveItem(at:root,to:disconnected)
        do {
            _ = try await waitFor(manager) {$0.state == .failed || $0.state == .paused}
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.path),"Must not recreate an unavailable library root")
            try FileManager.default.moveItem(at:disconnected,to:root)
        } catch {
            try? FileManager.default.moveItem(at:disconnected,to:root)
            throw error
        }
        try await manager.connect(); try await manager.resume(sample.id)
        let recovered=try await waitFor(manager) {$0.state == .installed || $0.state == .failed || $0.state == .corrupted}
        XCTAssertEqual(recovered.state,.installed,recovered.message ?? "")
        try await manager.delete(sample.id)
    }
    func testIgnoredResumeRangeDoesNotAppendOrInstall() async throws {
        _ = try await storage.select(root)
        sample.downloadURL=URL(string:"http://127.0.0.1:8917/ignore-range")!
        let manager=DownloadManager(storage:storage); try await manager.start(sample)
        _ = try await waitFor(manager) {$0.receivedBytes > 0 && $0.state == .downloading}
        await manager.pause(sample.id)
        let partial=try await waitFor(manager) {$0.state == .paused}
        let file=root.appendingPathComponent(partial.partialPath)
        let before=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize
        try await manager.resume(sample.id)
        let failed=try await waitFor(manager) {$0.state == .failed}
        XCTAssertEqual(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(failed.relativePath).path))
        try await manager.delete(sample.id)
    }
}
