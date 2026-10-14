import XCTest
@testable import AtlasCore

/// The wider Kiwix catalog (every collection, not only Wikipedia) and importing a ZIM file.
final class PackageSourcesTests: XCTestCase {
    func testCollectionsFromTheCatalog() throws {
        let feed="""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><title>ted</title><link rel="subsection" href="/catalog/v2/entries?category=ted" type="application/atom+xml"/></entry>
          <entry><title>gutenberg</title><link rel="subsection" href="/catalog/v2/entries?category=gutenberg" type="application/atom+xml"/></entry>
          <entry><title>psiram</title><link rel="subsection" href="/catalog/v2/entries?category=psiram" type="application/atom+xml"/></entry>
          <entry><title>Wikipedia</title><link rel="subsection" href="/catalog/v2/entries?category=wikipedia" type="application/atom+xml"/></entry>
          <entry><title>stack_exchange</title><link rel="subsection" href="/catalog/v2/entries?category=stack_exchange" type="application/atom+xml"/></entry>
          <entry><title>wiktionary</title></entry>
          <entry><title>gutenberg</title></entry>
          <entry><title>../evil?x=1</title></entry>
        </feed>
        """
        let names=try PackageCatalog.parseCategories(Data(feed.utf8))
        XCTAssertEqual(names,["ted","gutenberg","psiram","wikipedia","stack_exchange","wiktionary"],"duplicates and unsafe names are dropped")
        let collections=KiwixCollection.ordered(names)
        XCTAssertEqual(collections.map(\.id),["wikipedia","wiktionary","gutenberg","stack_exchange","psiram"],"Wikipedia first, video collections left out")
        XCTAssertEqual(collections.map(\.title),["Wikipedia","Wiktionary","Project Gutenberg","Stack Exchange","Psiram"])
        XCTAssertFalse(collections[2].summary.isEmpty)
        XCTAssertEqual(KiwixCollection.defaults.first?.id,"wikipedia")
    }

    func testEntriesKeepTheirCollection() throws {
        let feed="""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <totalResults>1</totalResults>
          <entry>
            <id>urn:uuid:1234</id><title>Project Gutenberg Library</title><summary>Public-domain books</summary>
            <language>eng</language><name>gutenberg_en_all</name><flavour></flavour><tags>_category:gutenberg</tags>
            <issued>2024-01-15T00:00:00Z</issued>
            <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://download.kiwix.org/zim/gutenberg/gutenberg_en_all.zim.meta4" length="123456789"/>
          </entry>
        </feed>
        """
        let page=try PackageCatalog.parseOPDS(Data(feed.utf8),baseURL:URL(string:"https://opds.library.kiwix.org/catalog/v2/entries")!,category:"gutenberg")
        let package=try XCTUnwrap(page.packages.first)
        XCTAssertEqual(package.category,"gutenberg")
        XCTAssertEqual(package.name,"Project Gutenberg Library")
        XCTAssertEqual(package.version,"2024-01-15")
        XCTAssertEqual(package.downloadBytes,123456789)
        XCTAssertFalse(package.isImported)
    }

    func testPackagesRecordedBeforeCollectionsStillLoad() throws {
        let package=WikipediaPackage(id:"wikipedia_en_all",name:"Wikipedia",languageCode:"eng",kind:.standard,summary:"",version:"2024-01",
                                     downloadURL:URL(string:"https://example.org/w.zim")!,downloadBytes:10,format:.zim,source:"Kiwix / openZIM",family:"w",category:"wikipedia")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(package)) as? [String:Any])
        json["category"]=nil
        let older=try JSONDecoder().decode(WikipediaPackage.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(older.category)
        XCTAssertEqual(older.id,package.id)
    }

    func testAnImportedFileDescribesItself() {
        let file=URL(fileURLWithPath:"/Users/me/Books/My Books.zim")
        let info=ZIMFileInfo(uuid:"0f1e2d3c",title:"My Books",name:"my_books",language:"eng,fra",description:"",date:"2025-03-01",flavour:"nopic")
        let package=PackageImport.package(for:info,file:file,size:1234)
        XCTAssertEqual(package.id,"imported:0f1e2d3c","the file's own UUID, so importing it twice is noticed")
        XCTAssertEqual(package.languageCode,"eng")
        XCTAssertEqual(package.kind,.textOnly)
        XCTAssertEqual(package.summary,"Imported from My Books.zim.")
        XCTAssertEqual(package.version,"2025-03-01")
        XCTAssertEqual(package.family,"imported:my_books")
        XCTAssertTrue(package.isImported)
        XCTAssertTrue(PackageRecord(package:package).relativePath.hasPrefix("packages/"))
        XCTAssertTrue(PackageRecord(package:package).relativePath.hasSuffix(".zim"))
        let bare=PackageImport.package(for:ZIMFileInfo(),file:file,size:1234)
        XCTAssertEqual(bare.name,"My Books","the file name when the archive has no title")
        XCTAssertEqual(bare.id,"imported:My Books.zim:1234")
        XCTAssertEqual(bare.languageCode,"und")
        XCTAssertEqual(bare.version,"imported")
    }

    func testCopyingInPieces() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let source=folder.appendingPathComponent("source.zim"),destination=folder.appendingPathComponent("copy.partial")
        // Just over one 8 MB piece, in a pattern that shows any piece copied out of place.
        let pattern=Data((0..<251).map {UInt8($0)})
        var bytes=Data();while bytes.count<9*1024*1024+17 {bytes.append(pattern)}
        try bytes.write(to:source)
        let reported=Reported()
        let copied=try PackageImport.copy(from:source,to:destination) {reported.add($0)}
        XCTAssertEqual(copied,Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf:destination),bytes)
        XCTAssertEqual(reported.values.last,Int64(bytes.count),"the last report is the whole file")
    }

    /// A file that isn't a ZIM is refused, nothing is left in the library, and it can't be "resumed".
    func testImportingAFileThatIsNotAZIM() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("import-library-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let storage=StorageManager(store:FileBookmarkStore(file:root.appendingPathComponent("selection.json")))
        let library=root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        _ = try await storage.select(library)
        guard try await storage.acquire().validate().availableBytes != nil else {throw XCTSkip("This file system doesn't report free space")}
        let file=root.appendingPathComponent("notes.zim")
        try Data("not really a zim".utf8).write(to:file)
        let package=PackageImport.package(for:ZIMFileInfo(uuid:"fake"),file:file,size:16)
        let manager=DownloadManager(storage:storage)
        try await manager.importArchive(from:file,package:package)
        var record:PackageRecord?
        for _ in 0..<100 {
            record=await manager.snapshot().records.first
            if record?.state == .failed {break}
            try await Task.sleep(for:.milliseconds(30))
        }
        XCTAssertEqual(record?.state,.failed)
        XCTAssertEqual(record?.message,AtlasError.notZIM.localizedDescription)
        let saved=try XCTUnwrap(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.appendingPathComponent(saved.partialPath).path),"the partial copy is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.appendingPathComponent(saved.relativePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path),"the user's own file is never touched")
        do {try await manager.resume(package.id);XCTFail("an import can't resume")}
        catch {XCTAssertEqual(error as? AtlasError,.importInterrupted)}
        do {try await manager.importArchive(from:file,package:package);XCTFail("already listed")}
        catch {XCTAssertEqual(error as? AtlasError,.alreadyInLibrary)}
        // After a relaunch, an import that was still copying is marked interrupted, not resumed.
        var copying=saved;copying.state = .downloading
        let access=try await storage.acquire()
        try PackageManifest(access:access).save(copying)
        let restarted=DownloadManager(storage:storage)
        try await restarted.connect()
        let recovered=await restarted.snapshot().records.first
        XCTAssertEqual(recovered?.state,.failed)
        XCTAssertEqual(recovered?.message,AtlasError.importInterrupted.localizedDescription)
        try await restarted.delete(package.id)
        let remaining=await restarted.snapshot().records
        XCTAssertTrue(remaining.isEmpty)
    }
}

private final class Reported:@unchecked Sendable {
    private let lock=NSLock()
    private var stored:[Int64]=[]
    func add(_ value:Int64) {lock.lock();stored.append(value);lock.unlock()}
    var values:[Int64] {lock.lock();defer {lock.unlock()};return stored}
}
