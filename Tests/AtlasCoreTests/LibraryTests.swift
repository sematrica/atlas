import XCTest
@testable import AtlasCore

final class LibraryTests: XCTestCase {
    private var root: URL!
    private let layout = LibraryLayout()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testEstablishmentIsIdempotentAndPreservesContent() throws {
        let first = try layout.establish(at: root)
        let article = root.appendingPathComponent("packages/example.zim")
        try Data("existing data".utf8).write(to: article)
        XCTAssertEqual(try layout.establish(at: root), first)
        XCTAssertEqual(try Data(contentsOf: article), Data("existing data".utf8))
        XCTAssertEqual(try layout.inspect(at: root, expectedID: first.id).library, first)
        for name in LibraryDirectory.allCases {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name.rawValue).path))
        }
    }

    func testMissingRootIsNeverRecreatedByInspection() throws {
        let metadata = try layout.establish(at: root)
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try layout.inspect(at: root, expectedID: metadata.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDifferentLibraryAtSamePathIsRejected() throws {
        _ = try layout.establish(at: root)
        XCTAssertThrowsError(try layout.inspect(at: root, expectedID: UUID())) { error in
            guard case StorageError.identityMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFileCollisionFailsBeforeCreatingAnyDirectories() throws {
        let collision = root.appendingPathComponent("vectors")
        try Data("keep".utf8).write(to: collision)
        XCTAssertThrowsError(try layout.establish(at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("packages").path))
        XCTAssertEqual(try Data(contentsOf: collision), Data("keep".utf8))
    }

    func testSymbolicLinkCannotRedirectLibraryWrites() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("packages"), withDestinationURL: root)
        XCTAssertThrowsError(try layout.establish(at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("metadata").path))
    }

    func testCorruptedMetadataIsPreserved() throws {
        _ = try layout.establish(at: root)
        let marker = root.appendingPathComponent("metadata/library.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: marker)
        XCTAssertThrowsError(try layout.establish(at: root))
        XCTAssertEqual(try Data(contentsOf: marker), corrupt)
    }

    func testFutureSchemaIsRejected() throws {
        _ = try layout.establish(at: root)
        try JSONEncoder().encode(LibraryMetadata(schemaVersion: 2)).write(to: root.appendingPathComponent("metadata/library.json"))
        XCTAssertThrowsError(try layout.establish(at: root))
    }

    func testMissingDirectoryRequiresExplicitRepair() throws {
        let metadata = try layout.establish(at: root)
        let packages = root.appendingPathComponent("packages")
        try FileManager.default.removeItem(at: packages)
        XCTAssertThrowsError(try layout.inspect(at: root, expectedID: metadata.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packages.path))
        XCTAssertEqual(try layout.establish(at: root), metadata)
    }

    func testBookmarkStoreRoundTrip() throws {
        let store = FileBookmarkStore(file: root.appendingPathComponent("settings/selection.json"))
        XCTAssertNil(try store.load())
        let id = UUID()
        try store.save(SavedLibrary(bookmark: Data([1, 2]), lastKnownPath: "/Volumes/Test/Atlas", volumeName: "Test", libraryID: id))
        XCTAssertEqual(try store.load()?.libraryID, id)
        XCTAssertEqual(try store.load()?.bookmark, Data([1, 2]))
    }

    func testInvalidBookmarkIsRetainedForRecovery() async throws {
        let store = FileBookmarkStore(file: root.appendingPathComponent("selection.json"))
        let bookmark = Data([0, 1, 2])
        try store.save(SavedLibrary(bookmark: bookmark, lastKnownPath: "/Volumes/Offline/Atlas", volumeName: "Offline", libraryID: UUID()))
        let manager = StorageManager(store: store)
        guard case .unavailable(let path, _, _) = await manager.refresh() else { return XCTFail("Expected unavailable") }
        XCTAssertEqual(path, "/Volumes/Offline/Atlas")
        XCTAssertEqual(try store.load()?.bookmark, bookmark)
    }

    func testMissingSettingsAreUnconfigured() async {
        let manager = StorageManager(store: FileBookmarkStore(file: root.appendingPathComponent("absent.json")))
        guard case .unconfigured = await manager.refresh() else { return XCTFail("Expected unconfigured") }
    }
}
