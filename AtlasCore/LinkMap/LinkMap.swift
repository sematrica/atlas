import Foundation

/// Wikipedia's map of links (who links to whom) and categories, built from Wikimedia's table
/// dumps and stored next to the library as compact memory-mapped files. ZIM packages carry
/// each article's own links but not what links *to* an article; the link map has both, so a
/// connection can be searched from both ends and "what links here" needs no reading.
///
/// Articles are numbered 0..<articles. Links and category memberships are stored as
/// adjacency lists: an offsets file (UInt64, one more than the rows) and a targets file (UInt32).
public final class LinkMap:Sendable {
    public let manifest:LinkMapManifest
    public let directory:URL
    let titles:MappedStrings
    let lookup:MappedStrings
    let lookupNodes:MappedNumbers<UInt32>
    let forward:MappedAdjacency
    let backward:MappedAdjacency
    let categoryNames:MappedStrings?
    let categoryLookup:MappedStrings?
    let categoryLookupIDs:MappedNumbers<UInt32>?
    let members:MappedAdjacency?
    let articleCategories:MappedAdjacency?

    public static let manifestName="manifest.json"

    public init(directory:URL) throws {
        self.directory=directory
        let data=try Data(contentsOf:directory.appendingPathComponent(Self.manifestName))
        manifest=try JSONDecoder().decode(LinkMapManifest.self,from:data)
        guard manifest.version == LinkMapManifest.currentVersion else {throw LinkMapError.outdated}
        func file(_ name:String)->URL {directory.appendingPathComponent(name)}
        titles=try MappedStrings(file("titles.strings"))
        lookup=try MappedStrings(file("lookup.strings"))
        lookupNodes=try MappedNumbers(file("lookup.nodes"))
        forward=try MappedAdjacency(offsets:file("links.offsets"),targets:file("links.targets"))
        backward=try MappedAdjacency(offsets:file("backlinks.offsets"),targets:file("backlinks.targets"))
        if manifest.categories>0 {
            categoryNames=try MappedStrings(file("categories.strings"))
            categoryLookup=try MappedStrings(file("categorylookup.strings"))
            categoryLookupIDs=try MappedNumbers(file("categorylookup.ids"))
            members=try MappedAdjacency(offsets:file("members.offsets"),targets:file("members.targets"))
            articleCategories=try MappedAdjacency(offsets:file("articlecategories.offsets"),targets:file("articlecategories.targets"))
        } else {
            categoryNames=nil;categoryLookup=nil;categoryLookupIDs=nil;members=nil;articleCategories=nil
        }
        guard titles.count == manifest.articles,forward.rows == manifest.articles,backward.rows == manifest.articles else {throw LinkMapError.damaged}
    }

    public var articleCount:Int {manifest.articles}

    // MARK: Titles

    /// MediaWiki's form of a title: underscores for spaces, no surrounding space, first letter capitalized.
    public static func normalize(_ raw:String)->String {
        var title=raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:" ",with:"_")
        while title.contains("__") {title=title.replacingOccurrences(of:"__",with:"_")}
        title=title.trimmingCharacters(in:CharacterSet(charactersIn:"_"))
        guard let first=title.first else {return title}
        return first.uppercased()+title.dropFirst()
    }

    /// The article a title names, following redirects. ZIM paths work too ("A/Ray_Charles").
    public func node(_ title:String)->Int32? {
        var name=title.removingPercentEncoding ?? title
        if name.hasPrefix("A/") {name=String(name.dropFirst(2))}
        for candidate in [Self.normalize(name),name.replacingOccurrences(of:" ",with:"_")] {
            if let index=lookup.find(Array(candidate.utf8)) {return Int32(lookupNodes[index])}
        }
        return nil
    }
    /// The article's title as MediaWiki writes it (underscores).
    public func title(_ node:Int32)->String {titles.string(Int(node))}

    // MARK: Links

    public func links(from node:Int32)->[Int32] {forward.row(Int(node))}
    /// The articles that link to this one, each once.
    public func links(to node:Int32)->[Int32] {Array(Set(backward.row(Int(node)))).sorted()}
    /// How many links point here (an article linking twice counts twice); a cheap popularity measure.
    public func inDegree(_ node:Int32)->Int {backward.count(Int(node))}

    /// The shortest chain of links from one article to another, searched from both ends at once.
    /// Edges are `from << 32 | to`. Returns nil when no chain of at most `maxLinks` links exists.
    public func shortestPath(from start:Int32,to target:Int32,avoidingEdges:Set<UInt64>=[],avoidingNodes:Set<Int32>=[],maxLinks:Int=10)->[Int32]? {
        if start == target {return [start]}
        let n=articleCount
        guard Int(start)<n,Int(target)<n,start>=0,target>=0 else {return nil}
        var parentF=[Int32](repeating:-1,count:n),parentB=[Int32](repeating:-1,count:n)
        var depthF=[UInt8](repeating:255,count:n),depthB=[UInt8](repeating:255,count:n)
        depthF[Int(start)]=0;depthB[Int(target)]=0
        var frontF=[start],frontB=[target]
        var levelF=0,levelB=0
        var best=Int.max,meet:Int32 = -1
        let checkEdges = !avoidingEdges.isEmpty,checkNodes = !avoidingNodes.isEmpty
        while !frontF.isEmpty,!frontB.isEmpty,levelF+levelB<maxLinks {
            if best<=levelF+levelB+1 {break}
            // Grow the side with less to read.
            let costF=frontF.reduce(0) {$0+forward.count(Int($1))},costB=frontB.reduce(0) {$0+backward.count(Int($1))}
            var next:[Int32]=[]
            if costF<=costB {
                for u in frontF {
                    forward.forEach(Int(u)) {v in
                        let vi=Int(v)
                        if depthF[vi] != 255 {return}
                        if checkNodes,avoidingNodes.contains(Int32(v)) {return}
                        if checkEdges,avoidingEdges.contains(UInt64(UInt32(u))<<32|UInt64(v)) {return}
                        depthF[vi]=UInt8(levelF+1);parentF[vi]=u;next.append(Int32(v))
                        if depthB[vi] != 255 {
                            let length=levelF+1+Int(depthB[vi])
                            if length<best {best=length;meet=Int32(v)}
                        }
                    }
                }
                levelF += 1;frontF=next
            } else {
                for u in frontB {
                    backward.forEach(Int(u)) {v in
                        let vi=Int(v)
                        if depthB[vi] != 255 {return}
                        if checkNodes,avoidingNodes.contains(Int32(v)) {return}
                        if checkEdges,avoidingEdges.contains(UInt64(v)<<32|UInt64(UInt32(u))) {return}
                        depthB[vi]=UInt8(levelB+1);parentB[vi]=u;next.append(Int32(v))
                        if depthF[vi] != 255 {
                            let length=levelB+1+Int(depthF[vi])
                            if length<best {best=length;meet=Int32(v)}
                        }
                    }
                }
                levelB += 1;frontB=next
            }
        }
        guard meet>=0,best<=maxLinks else {return nil}
        var path=[meet]
        while let last=path.first,parentF[Int(last)]>=0 {path.insert(parentF[Int(last)],at:0)}
        while let last=path.last,parentB[Int(last)]>=0 {path.append(parentB[Int(last)])}
        return path.first == start && path.last == target ? path : nil
    }

    // MARK: Categories

    public var hasCategories:Bool {members != nil}
    /// Categories with at least one article directly in them.
    public var categoryCount:Int {manifest.categories}

    /// A category by name, with or without "Category:".
    public func category(_ raw:String)->Int32? {
        guard let categoryLookup,let categoryLookupIDs else {return nil}
        var name=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        for prefix in ["Category:","category:","Category_","category "] where name.hasPrefix(prefix) {name=String(name.dropFirst(prefix.count))}
        for candidate in [Self.normalize(name),name.replacingOccurrences(of:" ",with:"_")] {
            if let index=categoryLookup.find(Array(candidate.utf8)) {return Int32(categoryLookupIDs[index])}
        }
        return nil
    }
    public func categoryName(_ id:Int32)->String {categoryNames?.string(Int(id)) ?? ""}
    /// The articles directly in a category (not in its subcategories), each once.
    public func members(_ category:Int32)->[Int32] {Array(Set(members?.row(Int(category)) ?? [])).sorted()}
    public func memberCount(_ category:Int32)->Int {members(category).count}
    public func categories(of node:Int32)->[Int32] {Array(Set(articleCategories?.row(Int(node)) ?? [])).sorted()}

    /// Maintenance categories ("Articles with short description", "CS1 maint: …") that readers
    /// rarely mean. The dumps mark hidden categories only in another table, so this goes by name.
    public static func isMaintenance(_ name:String)->Bool {
        let lowered=name.lowercased()
        let prefixes=["articles_","all_articles","all_pages","pages_","cs1","webarchive","wikipedia_","use_dmy","use_mdy","use_american","use_british",
                      "short_description","official_website","commons_category","wikidata","coordinates_","good_articles","featured_articles",
                      "harv_and_sfn","accuracy_disputes","npov","engvarb","vague_or_ambiguous","dead_link","biography_with_signature","template_"]
        return prefixes.contains {lowered.hasPrefix($0)} || lowered.contains("_maint") || lowered.contains("_errors") || lowered.hasSuffix("_stubs")
    }
}

public struct LinkMapManifest:Codable,Sendable,Equatable {
    public static let currentVersion=1
    public var version=currentVersion
    /// The Wikimedia project ("enwiki") and dump date ("20261001").
    public var project:String
    public var date:String
    public var articles:Int
    public var links:Int
    public var categories:Int
    public var memberships:Int
    public var built:Date
    public init(project:String,date:String,articles:Int,links:Int,categories:Int,memberships:Int,built:Date=Date()) {
        self.project=project;self.date=date;self.articles=articles;self.links=links;self.categories=categories;self.memberships=memberships;self.built=built
    }
    /// "2026-10-01".
    public var readableDate:String {
        guard date.count == 8 else {return date}
        let d=Array(date)
        return String(d[0..<4])+"-"+String(d[4..<6])+"-"+String(d[6..<8])
    }
}

public enum LinkMapError:LocalizedError,Equatable {
    case outdated, damaged, missingTables([String]), needsLinkTargets, insufficientSpace
    public var errorDescription:String? {
        switch self {
        case .outdated: "This link map was built by an older version of Sematrica. Delete it and build it again."
        case .damaged: "This link map's files don't match. Delete it and build it again."
        case .missingTables(let tables): "Download these tables of the same dump first: "+tables.joined(separator:", ")+"."
        case .needsLinkTargets: "This dump's links refer to a separate link-target table. Download the linktarget table of the same dump, then build again."
        case .insufficientSpace: "There isn't enough free space on the library drive to build this link map."
        }
    }
}

// MARK: - Memory-mapped files

/// Byte strings in one file: [count:UInt64][offsets:UInt64 × (count+1)][bytes].
struct MappedStrings:Sendable {
    let data:Data
    let count:Int
    init(_ url:URL) throws {
        data=try Data(contentsOf:url,options:.alwaysMapped)
        guard data.count>=16 else {throw LinkMapError.damaged}
        count=Int(data.withUnsafeBytes {$0.loadUnaligned(as:UInt64.self)})
        guard data.count>=8*(count+2) else {throw LinkMapError.damaged}
    }
    private func range(_ index:Int,_ raw:UnsafeRawBufferPointer)->Range<Int> {
        let start=Int(raw.loadUnaligned(fromByteOffset:8+8*index,as:UInt64.self))
        let end=Int(raw.loadUnaligned(fromByteOffset:16+8*index,as:UInt64.self))
        let base=8*(count+2)
        return (base+start)..<(base+end)
    }
    func bytes(_ index:Int)->[UInt8] {data.withUnsafeBytes {raw in Array(raw[range(index,raw)])}}
    func string(_ index:Int)->String {String(decoding:bytes(index),as:UTF8.self)}
    /// Binary search of strings sorted by their bytes.
    func find(_ key:[UInt8])->Int? {
        data.withUnsafeBytes {raw -> Int? in
            var low=0,high=count-1
            while low<=high {
                let middle=(low+high)/2
                let r=range(middle,raw)
                let order=key.withUnsafeBytes {k -> Int in
                    let common=min(k.count,r.count)
                    let c=common == 0 ? 0 : memcmp(raw.baseAddress!+r.lowerBound,k.baseAddress!,common)
                    if c != 0 {return Int(c)}
                    return r.count-k.count
                }
                if order == 0 {return middle}
                if order<0 {low=middle+1} else {high=middle-1}
            }
            return nil
        }
    }
}

/// Numbers in one file: [count:UInt64][values].
struct MappedNumbers<Number:FixedWidthInteger>:Sendable {
    let data:Data
    let count:Int
    init(_ url:URL) throws {
        data=try Data(contentsOf:url,options:.alwaysMapped)
        guard data.count>=8 else {throw LinkMapError.damaged}
        count=Int(data.withUnsafeBytes {$0.loadUnaligned(as:UInt64.self)})
        guard data.count>=8+count*MemoryLayout<Number>.size else {throw LinkMapError.damaged}
    }
    subscript(index:Int)->Number {data.withUnsafeBytes {$0.loadUnaligned(fromByteOffset:8+index*MemoryLayout<Number>.size,as:Number.self)}}
}

/// Adjacency lists: row i's values are targets[offsets[i]..<offsets[i+1]].
struct MappedAdjacency:Sendable {
    let offsets:MappedNumbers<UInt64>
    let targets:MappedNumbers<UInt32>
    var rows:Int {offsets.count-1}
    init(offsets:URL,targets:URL) throws {
        self.offsets=try MappedNumbers(offsets)
        self.targets=try MappedNumbers(targets)
        guard self.offsets.count>=1,Int(self.offsets[self.offsets.count-1]) == self.targets.count else {throw LinkMapError.damaged}
    }
    func count(_ row:Int)->Int {Int(offsets[row+1]-offsets[row])}
    func row(_ row:Int)->[Int32] {
        let start=Int(offsets[row]),end=Int(offsets[row+1])
        return targets.data.withUnsafeBytes {raw in (start..<end).map {Int32(raw.loadUnaligned(fromByteOffset:8+$0*4,as:UInt32.self))}}
    }
    func forEach(_ row:Int,_ body:(UInt32) -> Void) {
        let start=Int(offsets[row]),end=Int(offsets[row+1])
        targets.data.withUnsafeBytes {raw in for index in start..<end {body(raw.loadUnaligned(fromByteOffset:8+index*4,as:UInt32.self))}}
    }
}
