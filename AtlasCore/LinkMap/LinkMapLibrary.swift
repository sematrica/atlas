import Foundation

/// Where link maps live in the library, which Wikimedia table dumps make one, and which map
/// goes with an open package.
public enum LinkMapLibrary {
    /// The tables a link map is built from. linktarget is needed by dumps from 2024 on;
    /// categorylinks is optional.
    public static let tables=["page","redirect","pagelinks","linktarget","categorylinks"]
    public static let requiredTables=["page","redirect","pagelinks"]

    /// "enwiki-20261001-pagelinks.sql.gz" → ("enwiki", "20261001", "pagelinks").
    public static func dumpTable(_ fileName:String)->(project:String,date:String,table:String)? {
        guard fileName.hasSuffix(".sql.gz") else {return nil}
        let parts=fileName.dropLast(".sql.gz".count).split(separator:"-")
        guard parts.count == 3,parts[1].count == 8,parts[1].allSatisfy(\.isNumber),tables.contains(String(parts[2])),
              parts[0].allSatisfy({$0.isLetter || $0.isNumber || $0 == "_"}) else {return nil}
        return (String(parts[0]),String(parts[1]),String(parts[2]))
    }

    /// The Wikimedia project a Kiwix Wikipedia package comes from: "wikipedia_en_all_maxi" → "enwiki".
    public static func project(forPackageName raw:String)->String? {
        var name=raw
        if name.hasPrefix("imported:") {name=String(name.dropFirst("imported:".count))}
        if let colon=name.firstIndex(of:":") {name=String(name[..<colon])}
        let parts=name.lowercased().split(separator:"_").map(String.init)
        guard parts.count>=2,parts[0] == "wikipedia" else {return nil}
        if parts[1] == "simple" || (parts[1] == "en" && parts.count>2 && parts[2] == "simple") {return "simplewiki"}
        let language=parts[1].replacingOccurrences(of:"-",with:"_")
        guard !language.isEmpty,language.allSatisfy({$0.isLetter || $0 == "_"}) else {return nil}
        return language+"wiki"
    }

    /// The Wikimedia project of a ZIM package, if it is a Wikipedia.
    public static func project(for package:WikipediaPackage)->String? {
        project(forPackageName:package.family) ?? project(forPackageName:package.name)
    }

    public static func directoryName(project:String,date:String)->String {"linkmap-\(project)-\(date)"}

    /// What to say when a question needs a link map that isn't built.
    public static func missingMap(project:String?,for question:String)->String {
        guard let project else {return "\(question) come from Wikipedia's link map, so I can answer them only in a Wikipedia package."}
        return "\(question) come from Wikipedia's link map, which isn't built for this package yet. Under Packages, choose Archives, download the link map files for \(project), then press Build."
    }

    /// The finished link maps in a library's indexes folder, newest first. Unfinished builds are skipped.
    public static func installed(in indexes:URL)->[(manifest:LinkMapManifest,directory:URL)] {
        let fm=FileManager.default
        guard let entries=try? fm.contentsOfDirectory(at:indexes,includingPropertiesForKeys:nil) else {return []}
        var found:[(manifest:LinkMapManifest,directory:URL)]=[]
        for entry in entries where entry.lastPathComponent.hasPrefix("linkmap-") {
            if entry.lastPathComponent.hasSuffix(".building") {continue}
            guard let data=try? Data(contentsOf:entry.appendingPathComponent(LinkMap.manifestName)),
                  let manifest=try? JSONDecoder().decode(LinkMapManifest.self,from:data) else {continue}
            found.append((manifest,entry))
        }
        return found.sorted {$0.manifest.date>$1.manifest.date}
    }

    /// The newest link map for a project, if one has been built.
    public static func open(project:String,in indexes:URL)->LinkMap? {
        for entry in installed(in:indexes) where entry.manifest.project == project {
            if let map=try? LinkMap(directory:entry.directory) {return map}
        }
        return nil
    }

    /// A dump's tables found among the installed packages, grouped by project and date.
    public struct DumpSet:Identifiable,Sendable,Equatable {
        public var id:String {project+"-"+date}
        public let project:String
        public let date:String
        /// Table → package ID.
        public let records:[String:String]
        public var missing:[String] {LinkMapLibrary.requiredTables.filter {records[$0] == nil}}
        public var readableDate:String {LinkMapManifest(project:project,date:date,articles:0,links:0,categories:0,memberships:0).readableDate}
    }
    public static func dumpSets(_ records:[PackageRecord])->[DumpSet] {
        var grouped:[String:(project:String,date:String,records:[String:String])]=[:]
        for record in records where record.state == .installed && record.package.format == .archive {
            guard let table=dumpTable(record.package.name) else {continue}
            let key=table.project+"-"+table.date
            var entry=grouped[key] ?? (table.project,table.date,[:])
            entry.records[table.table]=record.id
            grouped[key]=entry
        }
        return grouped.values.map {DumpSet(project:$0.project,date:$0.date,records:$0.records)}.sorted {($0.project,$1.date)<($1.project,$0.date)}
    }

    /// The link map tables of the newest dump in a loaded archive catalog, to download together.
    public static func downloads(in catalog:[WikipediaPackage])->[WikipediaPackage] {
        let found=catalog.compactMap {package in dumpTable(package.name).map {(package,$0)}}
        guard let date=found.map(\.1.date).max() else {return []}
        return found.filter {$0.1.date == date}.sorted {order($0.1.table)<order($1.1.table)}.map(\.0)
    }
    static func order(_ table:String)->Int {tables.firstIndex(of:table) ?? tables.count}
}

// MARK: - Answers

extension LibraryRequest {
    /// The article a plain "which articles link to X" question across the whole library asks about.
    /// A link map answers it outright, from every article rather than only those that mention X.
    public var linksHereTarget:String? {
        guard scope == "library",measure != "total" else {return nil}
        let q=query.normalized()
        guard let target=q.linksTo else {return nil}
        var plain=PageQuery(unit:"link");plain.linksTo=target
        return plain.normalized() == q ? target : nil
    }
}

extension LinkMap {
    /// This package's articles for map nodes, after the package's redirects. Nodes it lacks are left out.
    /// New ZIM files name articles "Paris", older ones "A/Paris"; `prefix` is tried first.
    public func articles(_ nodes:[Int32],in source:any LibraryArticleSource,prefix:String="") async throws -> [Int32:SearchResult] {
        let other=prefix.isEmpty ? "A/" : ""
        let found=try await source.resolve(paths:nodes.flatMap {[prefix+title($0),other+title($0)]})
        var result:[Int32:SearchResult]=[:]
        for node in nodes {
            if let article=found[prefix+title(node)] ?? found[other+title(node)] {result[node]=article}
        }
        return result
    }

    /// The first `limit` of `nodes` that this package has, as library hits in the same order.
    /// Each hit's count is how many links point to it.
    public func hits(_ nodes:[Int32],in source:any LibraryArticleSource,prefix:String="",limit:Int=200) async throws -> [LibraryHit] {
        var hits:[LibraryHit]=[],seen=Set<String>(),offset=0
        while hits.count<limit,offset<nodes.count,offset<limit*4 {
            try Task.checkCancellation()
            let chunk=Array(nodes[offset..<min(nodes.count,offset+max(64,limit-hits.count))])
            offset += chunk.count
            let found=try await articles(chunk,in:source,prefix:prefix)
            for node in chunk where hits.count<limit {
                guard let article=found[node],seen.insert(article.articleID.path).inserted else {continue}
                hits.append(.init(path:article.articleID.path,title:article.title.isEmpty ? readableTitle(node) : article.title,count:inDegree(node),sample:nil))
            }
        }
        return hits
    }

    /// The article a name means: a title, an archive path, or failing those the package's best title match.
    public func node(named name:String,source:any LibraryArticleSource) async throws -> Int32? {
        if let node=node(name) {return node}
        guard let found=try await LibraryEngine.resolveTitle(name,source:source) else {return nil}
        return node(found.articleID.path) ?? node(found.title)
    }

    /// "Wikipedia's link map (2026-10-01)", dated by the dump.
    public var sourceName:String {"Wikipedia's link map (\(manifest.readableDate))"}
    /// A title as readers write it: spaces, not underscores.
    public func readableTitle(_ node:Int32)->String {title(node).replacingOccurrences(of:"_",with:" ")}

    /// The articles that link to `node`, most linked-to first.
    public func backlinksByPopularity(_ node:Int32)->[Int32] {
        links(to:node).map {($0,inDegree($0))}.sorted {$0.1 != $1.1 ? $0.1>$1.1 : $0.0<$1.0}.map(\.0)
    }
    /// The articles in a category, most linked-to first.
    public func membersByPopularity(_ category:Int32)->[Int32] {
        members(category).map {($0,inDegree($0))}.sorted {$0.1 != $1.1 ? $0.1>$1.1 : $0.0<$1.0}.map(\.0)
    }

    /// "1,234 articles link to “Paris”, according to Wikipedia's link map (2026-10-01). Most linked-to: …"
    /// - Parameter sources: `backlinksByPopularity(node)`, if already worked out.
    public func linksHereAnswer(_ node:Int32,sources known:[Int32]?=nil,list:Bool)->String {
        let sources=known ?? backlinksByPopularity(node),name=readableTitle(node)
        guard !sources.isEmpty else {return "No article links to “\(name)”, according to \(sourceName)."}
        var text="\(LibraryRun.format(sources.count)) article\(sources.count == 1 ? "" : "s") link\(sources.count == 1 ? "s" : "") to “\(name)”, according to \(sourceName)."
        if list {text += " Most linked-to first: "+sources.prefix(5).map(readableTitle).joined(separator:", ")+"."}
        return text
    }

    /// "There are 312 articles in Category:Jazz pianists (directly, not counting subcategories)…"
    /// - Parameter members: `membersByPopularity(category)`, if already worked out.
    public func categoryAnswer(_ category:Int32,members known:[Int32]?=nil,list:Bool)->String {
        let articles=known ?? membersByPopularity(category),name=categoryName(category).replacingOccurrences(of:"_",with:" ")
        var text="\(LibraryRun.format(articles.count)) article\(articles.count == 1 ? " is" : "s are") in Category:\(name), directly rather than through its subcategories, according to \(sourceName)."
        if list,!articles.isEmpty {text += " Most linked-to first: "+articles.prefix(5).map(readableTitle).joined(separator:", ")+"."}
        return text
    }

    /// "“Ray Charles” is in 23 categories: …" (maintenance categories counted, not listed).
    public func categoriesAnswer(of node:Int32)->String {
        let names=categories(of:node).map(categoryName)
        let shown=names.filter {!LinkMap.isMaintenance($0)}.map {$0.replacingOccurrences(of:"_",with:" ")}.sorted()
        let hidden=names.count-shown.count
        let title=readableTitle(node)
        guard !names.isEmpty else {return "“\(title)” isn't in any category in \(sourceName)."}
        var text="“\(title)” is in \(shown.count) categor\(shown.count == 1 ? "y" : "ies")"
        text += shown.isEmpty ? "" : ": "+shown.prefix(25).joined(separator:", ")+(shown.count>25 ? ", …" : "")
        if hidden>0 {text += " (plus \(hidden) maintenance categor\(hidden == 1 ? "y" : "ies") editors use)"}
        return text+". From \(sourceName)."
    }
}
