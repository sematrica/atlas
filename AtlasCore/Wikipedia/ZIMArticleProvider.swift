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
    /// The article each path leads to after redirects, from the archive's directory alone.
    public func resolve(paths:[String]) async throws -> [String:SearchResult] {
        guard !paths.isEmpty else {return [:]}
        try access.validate();try Task.checkCancellation()
        var resolved:[String:SearchResult]=[:]
        for start in stride(from:0,to:paths.count,by:512) {
            let chunk=Array(paths[start..<min(paths.count,start+512)])
            let pointers:[UnsafePointer<CChar>?]=chunk.map {UnsafePointer(strdup($0))}
            var rows:UnsafeMutablePointer<AZMatch>?;var count:Int32=0;var error:UnsafeMutablePointer<CChar>?
            defer {az_matches_free(rows,count);az_free(error);pointers.forEach {free(UnsafeMutableRawPointer(mutating:$0))}}
            let ok=pointers.withUnsafeBufferPointer {az_resolve_paths(handle,$0.baseAddress,Int32(chunk.count),&rows,&count,&error)}
            guard ok != 0 else {throw AtlasError.articleUnavailable}
            guard let rows else {continue}
            for i in 0..<min(Int(count),chunk.count) {
                let path=String(cString:rows[i].path)
                if !path.isEmpty {resolved[chunk[i]]=SearchResult(articleID:.init(packageID:packageID,path:path),title:String(cString:rows[i].title),excerpt:"")}
            }
        }
        return resolved
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

extension ZIMArticleProvider {
    /// Opens a ZIM file outside the library just long enough to read what it says about itself.
    /// Throws when libzim can't open it, so a damaged or non-ZIM file is refused before anything is copied.
    public static func fileInfo(at url: URL) throws -> ZIMFileInfo {
        var error: UnsafeMutablePointer<CChar>?
        let opened=az_open(url.path,&error)
        az_free(error)
        guard let archive=opened else { throw AtlasError.notZIM }
        defer { az_close(archive) }
        func value(_ key: String) -> String {
            var text: UnsafeMutablePointer<CChar>?; var failure: UnsafeMutablePointer<CChar>?
            defer { az_free(text); az_free(failure) }
            guard az_metadata(archive,key,&text,&failure) != 0, let text else { return "" }
            return String(cString: text)
        }
        var uuid: UnsafeMutablePointer<CChar>?
        defer { az_free(uuid) }
        let identity=az_uuid(archive,&uuid) != 0 ? uuid.map { String(cString: $0) } ?? "" : ""
        return ZIMFileInfo(uuid: identity, title: value("Title"), name: value("Name"), language: value("Language"), description: value("Description"),
                           date: value("Date"), flavour: value("Flavour"), tags: value("Tags"))
    }
}
