import Foundation
import ZIMBridge

/// An actor confines libzim's non-thread-safe suggestion searcher.
public actor ZIMArticleProvider: ResearchArticleProvider, LibraryArticleSource {
    private let access: LibraryAccess
    private let packageID: String
    private let handle: AZArchive
    public init(access: LibraryAccess, record: PackageRecord) throws {
        guard record.package.format == .zim else { throw AtlasError.unsupportedArchive }
        self.access=access; packageID=record.id
        try access.validate()
        var error: UnsafeMutablePointer<CChar>?
        let pointer=az_open(try access.file(record.relativePath).path,&error)
        defer { az_free(error) }
        guard let pointer else { throw AtlasError.articleUnavailable }
        handle=pointer
    }
    deinit { az_close(handle) }
    public func info(path: String = "") throws -> ArchiveResource {
        try access.validate()
        var item=AZItem(); var error: UnsafeMutablePointer<CChar>?
        defer { az_item_free(&item); az_free(error) }
        guard az_info(handle,path,&item,&error) != 0 else { throw AtlasError.articleUnavailable }
        return ArchiveResource(path:String(cString:item.path),title:String(cString:item.title),mimeType:String(cString:item.mime),byteCount:item.size)
    }
    public func read(path: String, offset: UInt64, length: Int = 262144) throws -> Data {
        try access.validate()
        var data: UnsafeMutableRawPointer?; var count=0; var error: UnsafeMutablePointer<CChar>?
        defer { az_free(data); az_free(error) }
        guard az_read(handle,path,offset,min(max(length,0),1024*1024),&data,&count,&error) != 0 else { throw AtlasError.articleUnavailable }
        return data.map {Data(bytes:$0,count:count)} ?? Data()
    }
    public func article(for id: ArticleID) async throws -> Article {
        guard id.packageID == packageID else { throw AtlasError.articleUnavailable }
        let metadata=try info(path:id.path)
        guard metadata.mimeType.contains("html"), metadata.byteCount < 32*1024*1024 else { throw AtlasError.articleUnavailable }
        var data=Data(); var offset: UInt64=0
        while offset < metadata.byteCount {
            try Task.checkCancellation()
            let chunk=try read(path:metadata.path,offset:offset,length:262144)
            guard !chunk.isEmpty else { throw AtlasError.articleUnavailable }
            data.append(chunk); offset += UInt64(chunk.count)
        }
        return Article(id:ArticleID(packageID:packageID,path:metadata.path),title:metadata.title,html:String(decoding:data,as:UTF8.self))
    }
    public func search(_ query: String, limit: Int = 30) async throws -> [SearchResult] {
        try access.validate(); try Task.checkCancellation()
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        var matches: UnsafeMutablePointer<AZMatch>?; var count: Int32=0; var error: UnsafeMutablePointer<CChar>?
        defer { az_matches_free(matches,count); az_free(error) }
        guard az_search(handle,query,Int32(min(max(limit,1),100)),&matches,&count,&error) != 0 else { throw AtlasError.searchUnavailable }
        guard let matches else { return [] }
        return (0..<Int(count)).map {
            SearchResult(articleID:ArticleID(packageID:packageID,path:String(cString:matches[$0].path)),title:String(cString:matches[$0].title),excerpt:"")
        }
    }
    public func hasArchiveFullText() throws -> Bool {try access.validate();return az_has_fulltext(handle) != 0}
    public func fullTextSearch(_ query:String,limit:Int=20) async throws -> [SearchResult] {
        try access.validate();try Task.checkCancellation()
        var rows:UnsafeMutablePointer<AZMatch>?;var count:Int32=0;var error:UnsafeMutablePointer<CChar>?
        defer {az_matches_free(rows,count);az_free(error)}
        guard az_fulltext(handle,query,Int32(min(100,max(1,limit))),&rows,&count,&error) != 0 else {throw AtlasError.searchUnavailable}
        guard let rows else {return []}
        return (0..<Int(count)).map {SearchResult(articleID:.init(packageID:packageID,path:String(cString:rows[$0].path)),title:String(cString:rows[$0].title),excerpt:"")}
    }
    /// One page of the built-in full-text search, with libzim's estimate of all matches.
    public func fullTextPage(_ query:String,offset:Int,limit:Int) async throws -> LibraryFullTextPage {
        try access.validate();try Task.checkCancellation()
        var rows:UnsafeMutablePointer<AZMatch>?;var count:Int32=0;var estimated:Int32=0;var error:UnsafeMutablePointer<CChar>?
        defer {az_matches_free(rows,count);az_free(error)}
        guard az_fulltext_page(handle,query,Int32(min(max(0,offset),Int(Int32.max))),Int32(min(500,max(1,limit))),&rows,&count,&estimated,&error) != 0 else {throw AtlasError.searchUnavailable}
        let results=rows.map {p in (0..<Int(count)).map {SearchResult(articleID:.init(packageID:packageID,path:String(cString:p[$0].path)),title:String(cString:p[$0].title),excerpt:"")}} ?? []
        return .init(results:results,estimated:Int(estimated))
    }
    public func articleBatch(offset:UInt64) async throws -> ArchiveArticleBatch {
        try access.validate();try Task.checkCancellation()
        var rows:UnsafeMutablePointer<AZMatch>?;var count:Int32=0;var next:UInt64=offset;var error:UnsafeMutablePointer<CChar>?
        defer {az_matches_free(rows,count);az_free(error)}
        guard az_articles(handle,offset,128,&rows,&count,&next,&error) != 0 else {throw AtlasError.articleUnavailable}
        let articles=rows.map {p in (0..<Int(count)).map {ArticleID(packageID:packageID,path:String(cString:p[$0].path))}} ?? []
        return .init(articles:articles,next:next,totalEntries:az_entry_count(handle))
    }
    public func validateArchive() throws {
        try access.validate()
        var error: UnsafeMutablePointer<CChar>?
        defer { az_free(error) }
        guard az_validate(handle,&error) != 0 else { throw AtlasError.checksumMismatch }
    }
}
