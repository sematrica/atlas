import Foundation

/// "How is Ray Charles connected to Paris?": the shortest chain of links from one
/// article to another, found offline.
///
/// Every step of a chain is a link read on the article's page, so the spider can walk
/// the route. The search reads outward from the start a level at a time (every article
/// the start links to, then theirs), most promising first. Meanwhile the archive's search
/// proposes articles that mention the target; those that really link to it become
/// stepping stones. Once every article within a distance of the start has been read,
/// every shorter chain has been ruled out, so the answer can say the chain is the shortest.
///
/// With a link map built from Wikipedia's table dumps, the chain comes from the whole
/// graph of links at once. Each of its links is then checked on this package's pages,
/// and links the pages don't have are routed around, so the spider can still walk it.
public struct ConnectionStop:Codable,Sendable,Equatable,Identifiable {
    public var id:String {path}
    public let path:String
    public let title:String
    /// The path of the link in the previous article that leads here, as that article writes it.
    /// It can be a redirect ("French_capital" for Paris). Nil for the start.
    public let via:String?
    public init(path:String,title:String,via:String?) {self.path=path;self.title=title;self.via=via}
}

public struct ConnectionProgress:Sendable {
    public let read:Int
    /// Checking the articles that mention the target, before reading outward.
    public let checkingMentions:Bool
    /// How many links from the start the articles being read are.
    public let level:Int
    /// Links in the best chain so far.
    public let steps:Int?
    public let current:String
    /// Taking the chain from the link map and checking its links on the pages.
    public var usingMap=false
}

struct ConnectionLink:Sendable {
    /// The path as the article's link writes it.
    let raw:String
    /// The article it leads to.
    let path:String
}

/// A connection being searched for. It can be continued where it stopped.
public struct ConnectionRun:Sendable {
    public let packageID:String
    public let start:ConnectionStop
    public let target:ConnectionStop
    /// The shortest chain found so far, from the start to the target.
    public internal(set) var chain:[ConnectionStop]?
    /// No shorter chain exists: every shorter one was ruled out.
    public internal(set) var proven=false
    /// Reading on can't find a shorter chain (or there's nothing left to read).
    public internal(set) var settled=false
    /// Every article reachable from the start was read and none leads to the target.
    public internal(set) var exhausted=false
    public internal(set) var read=0
    public internal(set) var failed=0
    /// Articles that mention the target could be looked up (full-text search or the text index).
    public internal(set) var hinted=false
    /// The link map the chain was found in: "Wikipedia's link map (2026-10-01)".
    public internal(set) var mapSource:String?
    /// Links in the map that these pages don't have, which the chain goes around.
    public internal(set) var mapDetours=0
    /// The link map has no chain between the two articles.
    public internal(set) var mapUnconnected=false

    /// The link map to search first, if one was built for this package's wiki.
    var linkMap:LinkMap?
    var mapTried=false
    /// The text index, for looking up articles that mention the target.
    var index:(any LibraryTextIndex)?
    var hintsGathered=false

    // Breadth-first search outward from the start.
    var level=0
    var frontier:[String]=[]
    var nextOrder:[String]=[]
    var nextCounts:[String:Int]=[:]
    var depth:[String:Int]=[:]
    var parent:[String:String]=[:]
    var via:[String:String]=[:]
    var expanded:Set<String>=[]
    /// Articles read at each level.
    var levelSizes:[Int:Int]=[:]
    /// Every article at this level and nearer has been read.
    var completeLevel = -1
    var failedLevels:Set<Int>=[]
    // Articles that mention the target, and those found to link to it (with the link's path).
    var hints:Set<String>=[]
    var toVerify:[String]=[]
    var intoTarget:[String:String]=[:]
    /// Links of articles read before the search reached them.
    var cachedLinks:[String:[ConnectionLink]]=[:]
    var titles:[String:String]=[:]
    /// Link path → the article it leads to; "" when it isn't an article.
    var resolved:[String:String]=[:]

    init(packageID:String,start:ConnectionStop,target:ConnectionStop) {self.packageID=packageID;self.start=start;self.target=target}

    /// Nothing more to do: the chain is the shortest, or reading on can't improve it.
    public var isComplete:Bool {proven || settled || exhausted}
    /// Links in the chain.
    public var steps:Int? {chain.map {$0.count-1}}
}

public enum ConnectionEngine {
    /// Articles read per request before the companion reports back and offers to keep looking.
    public static let defaultBudget=2_000
    /// Articles that mention the target, checked for a link to it.
    static let hintLimit=300
    /// Chains taken from the link map before giving up on it and reading outward instead.
    static let mapAttempts=8

    /// Finds both articles and the articles that mention the target.
    /// - Parameters:
    ///   - from: where to start; nil (or "this article") starts from `current`.
    ///   - current: the open article.
    ///   - linkMap: Wikipedia's link map for this package, searched before reading outward.
    public static func start(from:String?,to:String,current:ArticleID?,packageID:String,source:any LibraryArticleSource,
                             index:(any LibraryTextIndex)?,linkMap:LinkMap?=nil) async throws -> ConnectionRun {
        let targetName=to.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !targetName.isEmpty else {throw AIError.message("Which article should I connect to?")}
        guard let found=try await findArticle(targetName,source:source) else {
            throw AIError.message("I couldn't find an article called “\(PageQuery.stripQuotes(targetName))” in this package.")
        }
        let startID:ArticleID
        if let from=from?.trimmingCharacters(in:.whitespacesAndNewlines),!from.isEmpty,!isOpenArticle(from) {
            guard let start=try await findArticle(from,source:source) else {
                throw AIError.message("I couldn't find an article called “\(PageQuery.stripQuotes(from))” in this package.")
            }
            startID=start.articleID
        } else {
            guard let current else {throw AIError.message("Open an article first, or tell me where to start: “how is Paris connected to jazz?”")}
            startID=current
        }
        // Search results and the open article can be redirects: use the articles they lead to.
        let ends=try await source.resolve(paths:[startID.path,found.articleID.path])
        guard let first=ends[startID.path] else {throw AIError.message("I couldn't read the article to start from.")}
        guard let last=ends[found.articleID.path] else {throw AIError.message("I couldn't read “\(found.title)”.")}
        let start=ConnectionStop(path:first.articleID.path,title:first.title.isEmpty ? ArticleLinks.destinationTitle(first.articleID.path) : first.title,via:nil)
        let target=ConnectionStop(path:last.articleID.path,title:last.title.isEmpty ? found.title : last.title,via:nil)
        var run=ConnectionRun(packageID:packageID,start:start,target:target)
        run.titles[start.path]=start.title;run.titles[target.path]=target.title
        if start.path == target.path {run.chain=[start];run.proven=true;return run}
        run.frontier=[start.path];run.depth[start.path]=0
        run.linkMap=linkMap;run.index=index
        // With a link map, mentions are looked up only if the map can't give the chain.
        if linkMap == nil {try await gatherHints(&run,source:source)}
        return run
    }

    /// Articles that mention the target are the likeliest to link to it: they're checked first.
    static func gatherHints(_ run:inout ConnectionRun,source:any LibraryArticleSource) async throws {
        run.hintsGathered=true
        let packageID=run.packageID,target=run.target,start=run.start
        var mentions:[SearchResult]=[]
        if try await source.hasArchiveFullText() {
            let title=target.title
            let phrase=title.contains(where:\.isWhitespace) ? "\""+title.replacingOccurrences(of:"\"",with:"")+"\"" : title
            for text in phrase == title ? [title] : [phrase,title] where mentions.isEmpty {
                var offset=0
                while mentions.count<hintLimit {
                    let page=try await source.fullTextPage(text,offset:offset,limit:min(100,hintLimit-mentions.count))
                    mentions += page.results;offset += page.results.count
                    if page.results.isEmpty {break}
                }
            }
            run.hinted=true
        } else if let index=run.index,let coverage=try? await index.coverage(),coverage.indexed>0 {
            mentions=try await index.articlePaths(matching:target.title,limit:hintLimit).map {.init(articleID:.init(packageID:packageID,path:$0),title:"",excerpt:"")}
            run.hinted=true
        }
        for result in mentions where result.articleID.path != target.path && result.articleID.path != start.path && run.hints.insert(result.articleID.path).inserted {
            run.toVerify.append(result.articleID.path)
            if !result.title.isEmpty,run.titles[result.articleID.path] == nil {run.titles[result.articleID.path]=result.title}
        }
    }

    /// The article a name means. "the Moon" finds "Moon" when no article is called "the Moon".
    static func findArticle(_ raw:String,source:any LibraryArticleSource) async throws -> SearchResult? {
        let name=PageQuery.stripQuotes(raw.trimmingCharacters(in:.whitespacesAndNewlines))
        var names=[name]
        for article in ["the ","a ","an "] where name.lowercased().hasPrefix(article) && name.count>article.count+1 {names.append(String(name.dropFirst(article.count)))}
        var first:SearchResult?
        for candidate in names {
            guard let found=try await LibraryEngine.resolveTitle(candidate,source:source) else {continue}
            if found.title.caseInsensitiveCompare(candidate) == .orderedSame {return found}
            if first == nil {first=found}
        }
        return first
    }

    /// "this", "here", "this article", "this page": the open article.
    public static func isOpenArticle(_ text:String)->Bool {
        let folded=PageQuery.fold(text).trimmingCharacters(in:.punctuationCharacters)
        return ["this","here","this article","this page","the article","the page","current article","the current article","this one","it"].contains(folded)
    }

    /// Reads up to `budget` more articles.
    public static func advance(_ initial:ConnectionRun,source:any LibraryArticleSource,budget:Int=defaultBudget,concurrency:Int=4,
                               progress:(@Sendable (ConnectionProgress) async -> Void)?=nil) async throws -> ConnectionRun {
        var run=initial
        var reads=0,lastReport=Date.distantPast
        if let map=run.linkMap,!run.mapTried {
            run.mapTried=true
            if let progress {await progress(.init(read:run.read,checkingMentions:false,level:1,steps:nil,current:map.sourceName,usingMap:true))}
            reads += try await searchMap(&run,map:map,source:source)
        }
        if !run.isComplete,!run.hintsGathered {try await gatherHints(&run,source:source)}
        while !run.isComplete,reads<budget {
            try Task.checkCancellation()
            // The start first, then the articles that mention the target, then outward level by level.
            var batch:[String]=[]
            if !run.expanded.contains(run.start.path) {
                let first=run.start.path
                batch=[first];run.frontier.removeAll {$0 == first}
            } else if !run.toVerify.isEmpty {
                while batch.count<max(1,concurrency),!run.toVerify.isEmpty {
                    let path=run.toVerify.removeFirst()
                    if run.cachedLinks[path] == nil,!run.expanded.contains(path) {batch.append(path)}
                }
            } else {
                while let next=run.frontier.first,let links=run.cachedLinks[next] {
                    run.frontier.removeFirst()
                    expand(&run,next,links:links)
                }
                if run.isComplete {break}
                if run.frontier.isEmpty {
                    finishLevel(&run)
                    continue
                }
                while batch.count<max(1,concurrency),let next=run.frontier.first,run.cachedLinks[next] == nil {
                    run.frontier.removeFirst()
                    if !run.expanded.contains(next) {batch.append(next)}
                }
            }
            if batch.isEmpty {continue}
            let pages=try await read(batch,&run,source:source)
            for page in pages {
                reads += 1;run.read += 1
                let reached=run.depth[page.path] != nil && !run.expanded.contains(page.path) && run.depth[page.path] == run.level
                guard page.title != nil else {
                    run.failed += 1
                    if reached {
                        run.expanded.insert(page.path)
                        run.failedLevels.insert(run.level)
                    }
                    continue
                }
                if reached {
                    expand(&run,page.path,links:page.links)
                } else {
                    run.cachedLinks[page.path]=page.links
                    // A stepping stone the search already reached: the chain runs through it.
                    if let raw=run.intoTarget[page.path],run.depth[page.path] != nil {offer(&run,through:page.path,finalVia:raw)}
                }
            }
            if batch == [run.start.path] {
                // Stepping stones the start already links to are checked first.
                let reached=run.depth
                run.toVerify=run.toVerify.filter {reached[$0] != nil}+run.toVerify.filter {reached[$0] == nil}
            }
            // The frontier holds only unread articles at this level, so an empty one means the level is read.
            if run.frontier.isEmpty {run.completeLevel=max(run.completeLevel,run.level)}
            settle(&run)
            if let progress,Date().timeIntervalSince(lastReport)>0.25 {
                lastReport=Date()
                await progress(.init(read:run.read,checkingMentions:!run.toVerify.isEmpty,level:max(1,run.level),steps:run.steps,current:pages.last.flatMap {run.titles[$0.path]} ?? ""))
            }
        }
        settle(&run)
        return run
    }

    /// An article read for the search, with the articles its links lead to. No title means it couldn't be read.
    struct ReadPage:Sendable {let path:String;let title:String?;let links:[ConnectionLink]}

    /// Reads articles at once and resolves where their links lead (the run remembers every link resolved).
    static func read(_ batch:[String],_ run:inout ConnectionRun,source:any LibraryArticleSource) async throws -> [ReadPage] {
        struct Outcome:Sendable {let path:String;let title:String?;let raws:[String]}
        let packageID=run.packageID
        let outcomes=try await withThrowingTaskGroup(of:Outcome.self) {group in
            for path in batch {
                let id=ArticleID(packageID:packageID,path:path)
                group.addTask {
                    do {
                        let article=try await source.article(for:id)
                        try Task.checkCancellation()
                        let page=ArticlePageMap.make(article)
                        var seen=Set<String>(),raws:[String]=[]
                        for link in page.links {
                            if let href=link.href,let raw=ArticleLinks.path(href,from:article.id.path),seen.insert(raw).inserted {raws.append(raw)}
                        }
                        return Outcome(path:path,title:article.title,raws:raws)
                    } catch is CancellationError {throw CancellationError()}
                    catch {return Outcome(path:path,title:nil,raws:[])}
                }
            }
            var all:[Outcome]=[]
            for try await outcome in group {all.append(outcome)}
            // Keep the batch's own order, so results don't depend on timing.
            return batch.compactMap {path in all.first {$0.path == path}}
        }
        let unknown=Array(Set(outcomes.flatMap(\.raws)).filter {run.resolved[$0] == nil})
        if !unknown.isEmpty {
            let found=try await source.resolve(paths:unknown)
            for raw in unknown {run.resolved[raw]=found[raw]?.articleID.path ?? ""}
        }
        return outcomes.map {outcome in
            guard let title=outcome.title else {return ReadPage(path:outcome.path,title:nil,links:[])}
            if run.titles[outcome.path] == nil || run.titles[outcome.path]?.isEmpty == true {run.titles[outcome.path]=title}
            var links:[ConnectionLink]=[]
            for raw in outcome.raws {
                guard let path=run.resolved[raw],!path.isEmpty,path != outcome.path else {continue}
                links.append(.init(raw:raw,path:path))
            }
            if let link=links.first(where:{$0.path == run.target.path}) {run.intoTarget[outcome.path]=link.raw}
            return ReadPage(path:outcome.path,title:title,links:links)
        }
    }

    /// Takes the shortest chain from the link map and checks each of its links on this package's
    /// pages. A link the pages don't have (the dump and the package were made at different times,
    /// or the link sits in a template the package left out) is avoided and the map asked again.
    /// When the map can't give a chain the pages share, the search reads outward instead.
    /// Returns how many articles were read.
    static func searchMap(_ run:inout ConnectionRun,map:LinkMap,source:any LibraryArticleSource) async throws -> Int {
        guard let from=map.node(run.start.path) ?? map.node(run.start.title),
              let to=map.node(run.target.path) ?? map.node(run.target.title),from != to else {return 0}
        var avoidEdges=Set<UInt64>(),avoidNodes=Set<Int32>()
        // The map's articles as this package's paths; "" when the package doesn't have one.
        var paths:[Int32:String]=[from:run.start.path,to:run.target.path]
        var pages:[String:ReadPage]=[:]
        var reads=0,detours=0
        let prefix=run.start.path.hasPrefix("A/") ? "A/" : ""
        for _ in 0..<mapAttempts {
            try Task.checkCancellation()
            guard let nodes=map.shortestPath(from:from,to:to,avoidingEdges:avoidEdges,avoidingNodes:avoidNodes) else {
                if avoidEdges.isEmpty,avoidNodes.isEmpty {
                    run.mapUnconnected=true;run.exhausted=true;run.mapSource=map.sourceName
                }
                return reads
            }
            let unknown=nodes.filter {paths[$0] == nil}
            if !unknown.isEmpty {
                let found=try await map.articles(unknown,in:source,prefix:prefix)
                for node in unknown {paths[node]=found[node]?.articleID.path ?? ""}
            }
            let missing=nodes.filter {paths[$0]?.isEmpty != false}
            if !missing.isEmpty {avoidNodes.formUnion(missing);detours += missing.count;continue}
            var toRead:[String]=[]
            for node in nodes.dropLast() where pages[paths[node]!] == nil && !toRead.contains(paths[node]!) {toRead.append(paths[node]!)}
            if !toRead.isEmpty {
                for page in try await read(toRead,&run,source:source) {
                    pages[page.path]=page
                    // Kept for the outward search, should the map not work out.
                    if page.title != nil,page.path != run.start.path {run.cachedLinks[page.path]=page.links}
                }
                reads += toRead.count;run.read += toRead.count
            }
            var chain=[run.start],broken=false
            for index in 1..<nodes.count {
                let before=nodes[index-1],node=nodes[index]
                guard let page=pages[paths[before]!],page.title != nil else {
                    if index == 1 {return reads}  // the start can't be read
                    avoidNodes.insert(before);broken=true;detours += 1;continue
                }
                guard let link=page.links.first(where:{$0.path == paths[node]!}) else {
                    avoidEdges.insert(UInt64(UInt32(bitPattern:before))<<32|UInt64(UInt32(bitPattern:node)));broken=true;detours += 1;continue
                }
                let path=paths[node]!
                let title=index == nodes.count-1 ? run.target.title : pages[path]?.title ?? map.readableTitle(node)
                chain.append(.init(path:path,title:title,via:link.raw))
            }
            if broken {continue}
            run.chain=chain;run.settled=true
            run.mapSource=map.sourceName;run.mapDetours=detours
            return reads
        }
        return reads
    }

    /// Records an article's links: the next level, and any chain they complete.
    static func expand(_ run:inout ConnectionRun,_ path:String,links:[ConnectionLink]) {
        guard let d=run.depth[path],run.expanded.insert(path).inserted else {return}
        run.cachedLinks[path]=nil
        run.levelSizes[d,default:0] += 1
        if let raw=run.intoTarget[path] ?? links.first(where:{$0.path == run.target.path})?.raw {
            run.intoTarget[path]=raw
            offer(&run,through:path,finalVia:raw)
        }
        for link in links where link.path != run.target.path {
            if run.depth[link.path] == nil {
                run.depth[link.path]=d+1;run.parent[link.path]=path;run.via[link.path]=link.raw
                run.nextCounts[link.path]=1;run.nextOrder.append(link.path)
                if let raw=run.intoTarget[link.path] {offer(&run,through:link.path,finalVia:raw)}
            } else if run.depth[link.path] == d+1 {
                run.nextCounts[link.path,default:0] += 1
            }
        }
        settle(&run)
    }

    /// The level has been read: stop if a chain was found, otherwise read the next level.
    static func finishLevel(_ run:inout ConnectionRun) {
        run.completeLevel=run.level
        settle(&run)
        // Any chain found so far is at most two links past this level, so the next level can't beat it.
        if run.chain != nil {run.settled=true;return}
        guard !run.nextOrder.isEmpty else {run.exhausted=true;return}
        // Articles that mention the target first, then those many articles at this level link to.
        let ranked=run.nextOrder.enumerated().map {(path:$0.element,hint:run.hints.contains($0.element),count:run.nextCounts[$0.element] ?? 0,order:$0.offset)}
        run.frontier=ranked.sorted {
            if $0.hint != $1.hint {return $0.hint}
            if $0.count != $1.count {return $0.count>$1.count}
            return $0.order<$1.order
        }.map(\.path)
        run.nextOrder=[];run.nextCounts=[:]
        run.level += 1
    }

    /// Keeps the chain through `last` (already reached by the search) and on to the target, if it's shorter.
    static func offer(_ run:inout ConnectionRun,through last:String,finalVia:String) {
        var nodes=[last]
        while let up=run.parent[nodes[0]] {nodes.insert(up,at:0)}
        guard nodes.first == run.start.path else {return}
        guard run.chain == nil || nodes.count+1<run.chain!.count else {return}
        var chain=nodes.map {ConnectionStop(path:$0,title:run.titles[$0] ?? ArticleLinks.destinationTitle($0),via:run.via[$0])}
        chain.append(.init(path:run.target.path,title:run.target.title,via:finalVia))
        run.chain=chain
        settle(&run)
    }

    /// A chain is the shortest when every article that could have started a shorter one was read.
    static func settle(_ run:inout ConnectionRun) {
        guard let steps=run.steps else {return}
        if steps-2<=run.completeLevel,!run.failedLevels.contains(where:{$0<=steps-2}) {run.proven=true}
    }
}

// MARK: - Plain-language answer

extension ConnectionRun {
    /// "Ray Charles → Atlantic Records → New York City → Paris: 3 links. No shorter chain exists: …"
    public var answer:String {
        let from=start.title,to=target.title
        guard let chain else {
            if mapUnconnected,let mapSource {return "There's no chain of 10 links or fewer from \(from) to \(to) in \(mapSource)."}
            if exhausted {return "There's no chain of links from \(from) to \(to): I read every article \(from) leads to (\(LibraryRun.format(read)))."}
            var text="I haven't connected \(from) to \(to) yet after reading \(LibraryRun.format(read)) articles. Say “keep looking” to search further."
            if !hinted {text += " This package has no full-text search, so I can only search outward from \(from); building the text index under Research helps me find faraway articles."}
            return text
        }
        if chain.count == 1 {return "That's the same article."}
        let steps=chain.count-1
        if steps == 1 {return "\(from) links straight to \(to)."}
        var text=chain.map(\.title).joined(separator:" → ")+": \(steps) links."
        if let mapSource {
            text += " That's the shortest chain in \(mapSource)"
            text += mapDetours == 0 ? ", and every link in it is on these pages."
                                    : ", going around \(LibraryRun.format(mapDetours)) link\(mapDetours == 1 ? "" : "s") the map has that these pages don't."
        } else if proven {
            if steps == 2 {text += " That's the shortest chain: \(from) doesn't link to \(to) itself."}
            else if steps == 3 {
                let n=levelSizes[1] ?? 0
                text += " That's the shortest chain: none of the \(LibraryRun.format(n)) articles \(from) links to links to \(to) directly."
            } else {
                let n=(0...(steps-2)).reduce(0) {$0+(levelSizes[$1] ?? 0)}
                text += " That's the shortest chain: I read every article within \(steps-2) links of \(from) (\(LibraryRun.format(n))) and none links to \(to)."
            }
        } else if settled {
            text += " It's the shortest I found, but \(LibraryRun.format(failed)) article\(failed == 1 ? "" : "s") on the way couldn't be read, so a shorter one might exist."
        } else {
            text += " It's the shortest I've found after reading \(LibraryRun.format(read)) articles; a shorter one might exist. Say “keep looking” to make sure."
        }
        return text
    }
}
