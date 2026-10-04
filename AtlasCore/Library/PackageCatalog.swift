import Foundation

final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String]) { self.name=name; self.attributes=attributes }
    func value(_ name: String) -> String { children.first { $0.name == name }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}
final class CatalogXML: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []
    static func parse(_ data: Data) throws -> XMLNode {
        let delegate = CatalogXML(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let root=delegate.root else { throw AtlasError.catalogUnavailable }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node=XMLNode(name.split(separator: ":").last.map(String.init) ?? name, attributes)
        if let parent=stack.last { parent.children.append(node) } else { root=node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
}
public actor PackageCatalog {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    private func fetch(_ url: URL) async throws -> Data {
        let (data,response)=try await session.data(from: url)
        guard let http=response as? HTTPURLResponse, http.statusCode == 200, data.count < 32*1024*1024 else { throw AtlasError.catalogUnavailable }
        return data
    }
    public func wikipedia(language: String = "") async throws -> [WikipediaPackage] {
        var result: [WikipediaPackage] = []; var start=0
        while true {
            var url=URLComponents(string: "https://opds.library.kiwix.org/catalog/v2/entries")!
            url.queryItems=[.init(name:"category",value:"wikipedia"),.init(name:"count",value:"1000"),.init(name:"start",value:String(start))]
            if !language.isEmpty { url.queryItems?.append(.init(name:"lang",value:language)) }
            let data=try await fetch(url.url!)
            let page=try Self.parseOPDS(data, baseURL: url.url!)
            result += page.packages
            guard page.count > 0 else { break }
            start += page.count
            if start >= page.total { break }
            guard start < 20000 else { throw AtlasError.catalogUnavailable }
        }
        return result.sorted { $0.downloadBytes < $1.downloadBytes }
    }
    public static func parseOPDS(_ data: Data, baseURL: URL) throws -> (packages: [WikipediaPackage], count: Int, total: Int) {
        let root=try CatalogXML.parse(data)
        let entries=root.children.filter { $0.name == "entry" }
        let packages=entries.compactMap { entry -> WikipediaPackage? in
            guard let link=entry.children.first(where: { $0.name == "link" && $0.attributes["type"] == "application/x-zim" }),
                  let href=link.attributes["href"], let url=URL(string:href,relativeTo:baseURL)?.absoluteURL,
                  url.scheme == "https", let size=Int64(link.attributes["length"] ?? ""), size > 0 else { return nil }
            let flavour=entry.value("flavour"), tags=entry.value("tags")
            let kind: PackageKind = tags.contains("_pictures:no") || flavour == "nopic" || flavour == "mini" ? .textOnly : (flavour == "maxi" ? .full : .standard)
            let id=entry.value("id"), name=entry.value("name")
            guard !id.isEmpty else { return nil }
            let title=entry.value("title") + (flavour == "mini" ? " — abridged" : "")
            return WikipediaPackage(id:id, name:title, languageCode:entry.value("language"), kind:kind,
                                    summary:entry.value("summary"), version:String(entry.value("issued").isEmpty ? entry.value("updated").prefix(10) : entry.value("issued").prefix(10)),
                                    downloadURL:url, downloadBytes:size, format:.zim, source:"Kiwix / openZIM", family:name + ":" + flavour)
        }
        return (packages, entries.count, Int(root.value("totalResults")) ?? entries.count)
    }
    public func resolve(_ package: WikipediaPackage) async throws -> WikipediaPackage {
        guard package.downloadURL.pathExtension == "meta4" else { return package }
        return try Self.parseMetalink(try await fetch(package.downloadURL), package:package)
    }
    public static func parseMetalink(_ data: Data, package: WikipediaPackage) throws -> WikipediaPackage {
        let root=try CatalogXML.parse(data)
        guard let file=root.children.first(where: {$0.name == "file"}), let size=Int64(file.value("size")), size > 0 else { throw AtlasError.catalogUnavailable }
        let urls=file.children.filter {$0.name == "url"}.sorted { (Int($0.attributes["priority"] ?? "999") ?? 999) < (Int($1.attributes["priority"] ?? "999") ?? 999) }
        guard let url=urls.compactMap({URL(string:$0.text.trimmingCharacters(in:.whitespacesAndNewlines))}).first(where: {$0.scheme == "https"}) else { throw AtlasError.catalogUnavailable }
        var resolved=package; resolved.downloadURL=url; resolved.downloadBytes=size
        for (kind,algorithm,length) in [("sha-256",PackageChecksum.Algorithm.sha256,64),("sha-1",.sha1,40),("md5",.md5,32)] {
            if let node=file.children.first(where: {$0.name == "hash" && $0.attributes["type"] == kind}) {
                let value=node.text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                guard value.count == length, value.allSatisfy({$0.isHexDigit}) else { throw AtlasError.catalogUnavailable }
                resolved.checksum=PackageChecksum(algorithm:algorithm,value:value); break
            }
        }
        return resolved
    }
    public func wikimedia(project: String) async throws -> [WikipediaPackage] {
        guard project.hasSuffix("wiki"), project.count < 50,
              project.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")}) else { throw AtlasError.catalogUnavailable }
        let base=URL(string:"https://dumps.wikimedia.org/\(project)/")!
        let index=String(decoding:try await fetch(base),as:UTF8.self)
        let regex=try NSRegularExpression(pattern:"href=\"([0-9]{8})/\"")
        let dates=regex.matches(in:index,range:NSRange(index.startIndex...,in:index)).compactMap { Range($0.range(at:1),in:index).map {String(index[$0])} }.sorted(by:>)
        for date in dates.prefix(3) {
            do {
                let data=try await fetch(base.appendingPathComponent("\(date)/dumpstatus.json"))
                let rows=try Self.parseWikimedia(data,project:project,date:date)
                if !rows.isEmpty { return rows.sorted {$0.downloadBytes < $1.downloadBytes} }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        throw AtlasError.catalogUnavailable
    }
    public static func parseWikimedia(_ data: Data, project: String, date: String) throws -> [WikipediaPackage] {
        struct Manifest: Decodable { let jobs: [String: Job] }
        struct Job: Decodable { let status: String; let files: [String: File]? }
        struct File: Decodable { let size: Int64?; let url: String?; let sha1: String?; let md5: String? }
        let manifest=try JSONDecoder().decode(Manifest.self,from:data)
        return manifest.jobs.values.filter {$0.status == "done"}.flatMap { job in
            (job.files ?? [:]).compactMap { name,file -> WikipediaPackage? in
                guard let size=file.size,size > 0,let path=file.url,
                      let url=URL(string:path,relativeTo:URL(string:"https://dumps.wikimedia.org")!)?.absoluteURL,
                      url.scheme == "https",url.host == "dumps.wikimedia.org" else { return nil }
                let checksum=file.sha1.map {PackageChecksum(algorithm:.sha1,value:$0)} ?? file.md5.map {PackageChecksum(algorithm:.md5,value:$0)}
                return WikipediaPackage(id:"wikimedia:"+name,name:name,languageCode:String(project.dropLast(4)),
                                        kind:name.contains("history") ? .historicalArchive : .rawDump,
                                        summary:"Official Wikimedia dataset. Stored as an archive; not browsable.", version:date,
                                        downloadURL:url,downloadBytes:size,checksum:checksum,format:.archive,source:"Wikimedia",
                                        family:name.replacingOccurrences(of:date,with:"snapshot"))
            }
        }
    }
}
