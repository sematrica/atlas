import XCTest
import CryptoKit
@testable import AtlasCore

final class Stage2Tests: XCTestCase {
    var root: URL!
    var access: LibraryAccess!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let metadata=try LibraryLayout().establish(at:root)
        access=try LibraryAccess(root:root,libraryID:metadata.id)
    }
    override func tearDownWithError() throws { access=nil; try? FileManager.default.removeItem(at:root) }
    func package(checksum:PackageChecksum?=nil) -> WikipediaPackage {
        WikipediaPackage(id:"test-package",name:"Test",languageCode:"eng",kind:.standard,summary:"Fixture",version:"2026-01",
                         downloadURL:URL(string:"https://example.test/test.zim")!,downloadBytes:3,checksum:checksum,format:.zim,source:"Test",family:"test")
    }
    func testMetalinkUsesExactSizeAndFullFileHash() throws {
        let xml="""
        <metalink><file name="test.zim"><size>12345</size><hash type="sha-256">\(String(repeating:"a",count:64))</hash>
        <pieces><hash>incorrect-piece-hash</hash></pieces><url priority="2">https://two.test/test.zim</url><url priority="1">https://one.test/test.zim</url></file></metalink>
        """
        let result=try PackageCatalog.parseMetalink(Data(xml.utf8),package:package())
        XCTAssertEqual(result.downloadBytes,12345); XCTAssertEqual(result.checksum?.value,String(repeating:"a",count:64))
        XCTAssertEqual(result.downloadURL.host,"one.test")
    }
    func testOPDSHandlesNamespacesAndCategories() throws {
        let xml="""
        <feed xmlns:dc="http://purl.org/dc/terms/"><totalResults>2</totalResults><entry><id>abc</id><title>Wikipedia</title><language>eng</language><name>wikipedia_en</name><flavour>mini</flavour><tags>_pictures:no</tags><dc:issued>2026-01-01T00:00:00Z</dc:issued><link type="application/x-zim" href="https://example.test/book.meta4" length="2048"/></entry></feed>
        """
        let page=try PackageCatalog.parseOPDS(Data(xml.utf8),baseURL:URL(string:"https://example.test/")!)
        XCTAssertEqual(page.total,2); XCTAssertEqual(page.count,1)
        XCTAssertEqual(page.packages.first?.kind,.textOnly); XCTAssertEqual(page.packages.first?.version,"2026-01-01")
        XCTAssertTrue(page.packages.first!.name.contains("abridged"))
    }
    func testWikimediaOnlyListsCompletedFilesAndMarksHistoryArchiveOnly() throws {
        let json="""
        {"jobs":{"done":{"status":"done","files":{"x-history.xml.bz2":{"size":20,"url":"/enwiki/20260101/x-history.xml.bz2","sha1":"abc"}}},"pending":{"status":"in-progress","files":{"unfinished":{"size":5,"url":"/unfinished"}}}}}
        """
        let rows=try PackageCatalog.parseWikimedia(Data(json.utf8),project:"enwiki",date:"20260101")
        XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].format,.archive); XCTAssertEqual(rows[0].kind,.historicalArchive)
    }
    func testRangeResponseValidationRejectsIgnoredAndMisalignedRanges() throws {
        let url=URL(string:"https://example.test/test")!
        let valid=HTTPURLResponse(url:url,statusCode:206,httpVersion:nil,headerFields:["Content-Range":"bytes 100-199/200","Content-Length":"100"])!
        XCTAssertNoThrow(try StreamTransfer.validate(response:valid,offset:100,expectedSize:200))
        let ignored=HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Length":"200"])!
        XCTAssertThrowsError(try StreamTransfer.validate(response:ignored,offset:100,expectedSize:200))
        let wrong=HTTPURLResponse(url:url,statusCode:206,httpVersion:nil,headerFields:["Content-Range":"bytes 99-199/200"])!
        XCTAssertThrowsError(try StreamTransfer.validate(response:wrong,offset:100,expectedSize:200))
    }
    func testStreamingVerifierRejectsCorruptionAndTruncation() throws {
        let url=root.appendingPathComponent("fixture")
        let data=Data(repeating:42,count:2*1024*1024+7); try data.write(to:url)
        let checksum=PackageChecksum(algorithm:.sha256,value:SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined())
        XCTAssertNoThrow(try FileVerifier.verify(url:url,size:Int64(data.count),checksum:checksum))
        XCTAssertThrowsError(try FileVerifier.verify(url:url,size:Int64(data.count)+1,checksum:checksum))
        try Data(repeating:43,count:data.count).write(to:url)
        XCTAssertThrowsError(try FileVerifier.verify(url:url,size:Int64(data.count),checksum:checksum))
    }
    func testManifestRelativePathsSurviveFolderMove() throws {
        let record=PackageRecord(package:package()); try PackageManifest(access:access).save(record)
        let moved=root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at:root,to:moved); root=moved
        let newAccess=try LibraryAccess(root:moved,libraryID:access.libraryID)
        XCTAssertEqual(try PackageManifest(access:newAccess).load().first?.relativePath,record.relativePath)
    }
    func testManifestCannotDeleteArbitraryLibraryFile() throws {
        var record=PackageRecord(package:package()); record.relativePath="metadata/library.json"
        try PackageManifest(access:access).save(record)
        XCTAssertThrowsError(try PackageManifest(access:access).load())
    }
    func testLibraryAccessRejectsTraversalAndSymlink() throws {
        XCTAssertThrowsError(try access.file("packages/../../other"))
        XCTAssertThrowsError(try access.file("/tmp/other"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("packages/escape"),withDestinationURL:root)
        XCTAssertThrowsError(try access.file("packages/escape/metadata/library.json"))
    }
    func testLocalURLsPreserveUnicodeAndReservedCharacters() throws {
        let path="A/Les étoiles #1?%"
        let url=try XCTUnwrap(OfflineURL.make(host:"abc",path:path))
        XCTAssertEqual(String(url.path.dropFirst()),path); XCTAssertNil(url.query); XCTAssertNil(url.fragment)
        XCTAssertNil(OfflineURL.localWikipediaPath(URL(string:"https://wikipedia.org.evil.test/wiki/Example")!))
        XCTAssertEqual(OfflineURL.localWikipediaPath(URL(string:"https://en.wikipedia.org/wiki/Ray_Charles")!),"Ray_Charles")
    }
    func testOfflinePolicyPrecedesArticleResources() {
        let html=OfflineURL.protectHTML("<!doctype html><html><head><script src='https://example.test/x.js'></script></head></html>")
        XCTAssertTrue(html.contains("connect-src 'none'")); XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertLessThan(html.range(of:"Content-Security-Policy")!.lowerBound,html.range(of:"<script")!.lowerBound)
    }
    func testInvalidZIMIsRejected() throws {
        let record=PackageRecord(package:package())
        try Data("bad".utf8).write(to:access.file(record.relativePath))
        XCTAssertThrowsError(try ZIMArticleProvider(access:access,record:record))
    }
}

final class LiveWikipediaTests: XCTestCase {
    /// Opt-in: downloads a small official English Wikipedia selection and preserves it for offline tests.
    func testLiveDownloadInstallAndRestart() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in official network integration test") }
        let root=URL(fileURLWithPath:"/tmp/AtlasStage2LiveLibrary")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        _ = try LibraryLayout().establish(at:root)
        let storage=StorageManager(store:FileBookmarkStore(file:URL(fileURLWithPath:"/tmp/AtlasStage2LiveBookmark.json")))
        _ = try await storage.select(root)
        let catalog=PackageCatalog()
        let packages=try await catalog.wikipedia(language:"eng")
        let sample=try XCTUnwrap(packages.filter {$0.kind == .full && $0.downloadBytes < 10_000_000}.min {$0.downloadBytes < $1.downloadBytes})
        let resolved=try await catalog.resolve(sample)
        print("LIVE PACKAGE: \(resolved.name), \(resolved.version), \(resolved.downloadBytes) bytes, \(resolved.downloadURL)")
        let manager=DownloadManager(storage:storage)
        try await manager.connect()
        if await manager.snapshot().records.contains(where:{$0.id == resolved.id}) { try await manager.delete(resolved.id) }
        try await manager.start(resolved)
        var installed: PackageRecord?
        for _ in 0..<600 {
            try await Task.sleep(for:.milliseconds(200))
            let record=await manager.snapshot().records.first {$0.id == resolved.id}
            if record?.state == .installed { installed=record; break }
            if [.failed,.corrupted].contains(record?.state ?? .paused) { XCTFail(record?.message ?? "Download failed"); return }
        }
        let record=try XCTUnwrap(installed,"Download timed out")
        XCTAssertEqual(record.verification,.verified)
        let fresh=DownloadManager(storage:storage); try await fresh.connect()
        let restored=await fresh.snapshot().records
        XCTAssertTrue(restored.contains {$0.id == record.id && $0.state == .installed})
        try await exerciseOffline(storage:storage,record:record)
        print("LIVE DOWNLOAD / CHECKSUM / RESTART / ARTICLE / IMAGE / LINK TEST PASSED")
    }
    func testLiveWikimediaArchiveDownload() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in Wikimedia archive test") }
        let root=URL(fileURLWithPath:"/tmp/AtlasStage2RawLiveLibrary")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let storage=StorageManager(store:FileBookmarkStore(file:URL(fileURLWithPath:"/tmp/AtlasStage2RawBookmark.json")))
        _ = try await storage.select(root)
        let source=PackageCatalog()
        let packages=try await source.wikimedia(project:"simplewiki")
        let sample=try XCTUnwrap(packages.filter {$0.downloadBytes < 100_000 && $0.checksum != nil}.min {$0.downloadBytes < $1.downloadBytes})
        let manager=DownloadManager(storage:storage); try await manager.connect()
        if await manager.snapshot().records.contains(where:{$0.id == sample.id}) { try await manager.delete(sample.id) }
        try await manager.start(sample)
        for _ in 0..<300 {
            let snapshot=await manager.snapshot()
            if let record=snapshot.records.first(where:{$0.id == sample.id}),record.state == .installed {
                XCTAssertEqual(record.package.format,.archive); XCTAssertEqual(record.verification,.verified)
                print("RAW ARCHIVE: \(record.package.name), \(record.package.downloadBytes) bytes, verified and stored")
                return
            }
            if let failed=snapshot.records.first(where:{$0.state == .failed || $0.state == .corrupted}) { XCTFail(failed.message ?? "Archive download failed"); return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("Raw archive download timed out")
    }
    func testOfflineSearchResourcesAndLinks() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_OFFLINE_TESTS"] == "1" else { throw XCTSkip("Requires downloaded live fixture; run with networking denied") }
        let storage=StorageManager(store:FileBookmarkStore(file:URL(fileURLWithPath:"/tmp/AtlasStage2LiveBookmark.json")))
        let manager=DownloadManager(storage:storage); try await manager.connect()
        let snapshot=await manager.snapshot()
        let record=try XCTUnwrap(snapshot.records.first {$0.state == .installed})
        try await exerciseOffline(storage:storage,record:record)
    }
    private func exerciseOffline(storage:StorageManager,record:PackageRecord) async throws {
        let access=try await storage.acquire()
        let provider=try ZIMArticleProvider(access:access,record:record)
        let results=try await provider.search("Ray",limit:20)
        XCTAssertFalse(results.isEmpty)
        let result=try XCTUnwrap(results.first {$0.title.contains("Ray Charles")})
        let article=try await provider.article(for:result.articleID)
        XCTAssertTrue(article.html.contains("Ray Charles"))
        let regex=try NSRegularExpression(pattern:"(?:href|src)=\"([^\"]+)\"")
        let references=regex.matches(in:article.html,range:NSRange(article.html.startIndex...,in:article.html)).compactMap { Range($0.range(at:1),in:article.html).map {String(article.html[$0])} }
        let base=try XCTUnwrap(OfflineURL.make(host:record.package.storageKey,path:result.articleID.path))
        var image=false,css=false,link=false
        for reference in references {
            guard let url=URL(string:reference.replacingOccurrences(of:"&amp;",with:"&"),relativeTo:base)?.absoluteURL,
                  url.scheme == "atlas",let resource=try? await provider.info(path:String(url.path.dropFirst())) else { continue }
            if resource.mimeType.hasPrefix("image/") { let data=try await provider.read(path:resource.path,offset:0); image = image || !data.isEmpty }
            if resource.mimeType.contains("css") { let data=try await provider.read(path:resource.path,offset:0); css = css || !data.isEmpty }
            if resource.mimeType.contains("html"),resource.path != result.articleID.path { let data=try await provider.read(path:resource.path,offset:0); link = link || !data.isEmpty }
            if image && css && link { break }
        }
        XCTAssertTrue(image,"Must contain a local image"); XCTAssertTrue(css,"Must contain local styles"); XCTAssertTrue(link,"Must follow a local article link")
        print("OFFLINE: \(results.count) title results, article \(article.title), local image/CSS/link available")
    }
}
