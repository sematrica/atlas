import Foundation

/// A question about many articles: "how many articles mention Atlantic Records",
/// "which articles link to Paris", "count jazz in the articles linked from Discography".
///
/// Search only proposes candidate articles. Every candidate is then read in
/// full and counted exactly by `PageQueryEngine`, so a count never comes from a
/// search engine's estimate or a model's arithmetic. The answer says which
/// articles were checked and whether that covers the whole library.
public struct LibraryRequest:Codable,Sendable,Equatable {
    /// library (the whole package), linked (articles linked from the open article),
    /// titles (named articles), search (the best search results for `search`)
    public var scope:String
    /// articles (how many contain a match), total (all matches added up), list (which articles)
    public var measure:String
    /// What to count in each article.
    public var query:PageQuery
    /// linked: only links in this section of the open article.
    public var section:String?
    /// titles: the articles to check.
    public var titles:[String]?
    /// search: what to search for.
    public var search:String?
    /// At most this many articles from a linked, titles or search scope.
    public var articleLimit:Int?

    public init(scope:String="library",measure:String="articles",query:PageQuery,section:String?=nil,titles:[String]?=nil,search:String?=nil,articleLimit:Int?=nil) {
        self.scope=scope;self.measure=measure;self.query=query;self.section=section;self.titles=titles;self.search=search;self.articleLimit=articleLimit
    }

    public static let scopes=["library","linked","titles","search"]
    public static let measures=["articles","total","list"]

    /// The per-article query: every match is counted, so ordering and limits don't apply.
    public var countingQuery:PageQuery {
        var q=query.normalized()
        q.order=nil;q.rank=nil;q.limit=nil
        return q
    }

    public var problems:[String] {
        var issues:[String]=[]
        if !Self.scopes.contains(scope) {issues.append("scope must be one of \(Self.scopes.joined(separator:", "))")}
        if !Self.measures.contains(measure) {issues.append("measure must be one of \(Self.measures.joined(separator:", "))")}
        issues += query.normalized().problems
        if query.meaning != nil {issues.append("meaning can't be judged across many articles; count something on the page instead")}
        if scope == "titles",(titles ?? []).isEmpty {issues.append("the titles scope needs the article titles")}
        if scope == "search",(search ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {issues.append("the search scope needs something to search for")}
        if (titles ?? []).count>200 {issues.append("at most 200 titles")}
        if let articleLimit,articleLimit<1 || articleLimit>10_000 {issues.append("articleLimit must be 1–10000")}
        return issues
    }

    /// The text a search can look for: the phrase or word, or the title a link points to.
    public var searchTexts:[String] {
        let q=query.normalized()
        let raw:String?
        if let title=q.linksTo {raw=title}
        else if q.unit == "phrase" || q.isWordLike {raw=q.equals}
        else {raw=nil}
        guard let raw else {return []}
        return raw.split(separator:"|").map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {$0.contains(where:{$0.isLetter || $0.isNumber})}
    }
}

/// One article with at least one match.
public struct LibraryHit:Codable,Sendable,Identifiable,Equatable {
    public var id:String {path}
    public let path:String
    public let title:String
    public let count:Int
    /// The first match, for context.
    public let sample:String?
    public init(path:String,title:String,count:Int,sample:String?) {self.path=path;self.title=title;self.count=count;self.sample=sample}
}

/// Where the candidate articles came from.
public enum LibraryCandidates:Codable,Sendable,Equatable {
    /// The archive's built-in full-text index (covers every article).
    case builtInSearch(estimated:Int)
    /// The local text index built in Research.
    case textIndex(indexed:Int,complete:Bool)
    /// Every article in the archive, in order.
    case scan
    /// Articles linked from the open article.
    case linked(section:String?)
    /// Named articles.
    case titles
    /// The best search results.
    case search
}

public struct LibraryIndexCoverage:Sendable,Equatable {
    public let indexed:Int
    public let complete:Bool
    public init(indexed:Int,complete:Bool) {self.indexed=indexed;self.complete=complete}
}

/// A page of results from the archive's built-in full-text search.
public struct LibraryFullTextPage:Sendable {
    public let results:[SearchResult]
    public let estimated:Int
    public init(results:[SearchResult],estimated:Int) {self.results=results;self.estimated=estimated}
}

/// The archive, as the library engine reads it.
public protocol LibraryArticleSource:Sendable {
    func article(for id:ArticleID) async throws -> Article
    /// Title search.
    func search(_ query:String,limit:Int) async throws -> [SearchResult]
    func hasArchiveFullText() async throws -> Bool
    /// The built-in full-text search, page by page.
    func fullTextPage(_ query:String,offset:Int,limit:Int) async throws -> LibraryFullTextPage
    func articleBatch(offset:UInt64) async throws -> ArchiveArticleBatch
    /// The article each path leads to after redirects, keyed by the path asked for.
    /// Paths that aren't articles are left out. Reads only the directory, never article text.
    func resolve(paths:[String]) async throws -> [String:SearchResult]
}

/// The local text index (Research → Build Text Index).
public protocol LibraryTextIndex:Sendable {
    /// Every indexed article whose text contains the phrase, up to `limit` paths.
    func articlePaths(matching phrase:String,limit:Int) async throws -> [String]
    func coverage() async throws -> LibraryIndexCoverage
}

/// Progress while articles are being read.
public struct LibraryProgress:Sendable {
    public let checked:Int
    public let remaining:Int?
    public let hits:Int
    public let current:String
}

/// A library question being answered. It can be continued where it stopped.
public struct LibraryRun:Sendable {
    public let request:LibraryRequest
    public let packageID:String
    public var candidates:LibraryCandidates
    /// Articles with at least one match, in the order they were found.
    public var hits:[LibraryHit]=[]
    public var checked=0
    public var failed=0
    public var totalMatches=0
    /// Candidates found but not read yet.
    public var pending:[ArticleID]=[]
    /// Built-in search texts still to page through, and the next page offset.
    public var searchQueue:[String]=[]
    public var searchOffset=0
    public var estimatedCandidates:Int?
    /// The next archive entry when scanning, and the archive's size.
    public var scanOffset:UInt64?
    public var scanTotal:UInt64=0
    public var missingTitles:[String]=[]
    /// Canonical paths already read, so redirects and repeats are counted once.
    public var seen:Set<String>=[]

    public init(request:LibraryRequest,packageID:String,candidates:LibraryCandidates) {
        self.request=request;self.packageID=packageID;self.candidates=candidates
    }

    /// Everything in scope has been read.
    public var isComplete:Bool {pending.isEmpty && searchQueue.isEmpty && scanOffset == nil}
    /// The whole library is covered: complete, and the candidates could not have missed an article.
    public var coversLibrary:Bool {
        guard isComplete else {return false}
        switch candidates {
        case .builtInSearch,.scan: return true
        case .textIndex(_,let complete): return complete
        default: return false
        }
    }
    /// Matching articles, most matches first.
    public var ranked:[LibraryHit] {hits.enumerated().sorted {$0.element.count != $1.element.count ? $0.element.count>$1.element.count : $0.offset<$1.offset}.map(\.element)}
}

public enum LibraryEngine {
    /// Articles read per request before the companion reports back and offers to continue.
    public static let defaultBudget=2_000
    static let searchPage=100

    /// Resolves the scope and prepares the first candidates.
    /// - Parameter current: the open article and its live page map (needed for the linked scope).
    public static func start(_ request:LibraryRequest,packageID:String,source:any LibraryArticleSource,index:(any LibraryTextIndex)?,
                             current:(id:ArticleID,page:CrawlerPageMap)?) async throws -> LibraryRun {
        switch request.scope {
        case "linked":
            guard let current else {throw AIError.message("Open an article first: I count in the articles it links to.")}
            var run=LibraryRun(request:request,packageID:packageID,candidates:.linked(section:request.section))
            var seen=Set<String>()
            for link in current.page.links {
                if let section=request.section,!PageQueryEngine.matchesSection(link.section,section) {continue}
                guard let href=link.href,let path=ArticleLinks.path(href,from:current.id.path),seen.insert(path).inserted else {continue}
                run.pending.append(.init(packageID:packageID,path:path))
            }
            run.pending=Array(run.pending.prefix(request.articleLimit ?? 500))
            return run
        case "titles":
            var run=LibraryRun(request:request,packageID:packageID,candidates:.titles)
            for title in request.titles ?? [] {
                try Task.checkCancellation()
                if let found=try await resolveTitle(title,source:source) {run.pending.append(found.articleID)}
                else {run.missingTitles.append(title)}
            }
            if let limit=request.articleLimit {run.pending=Array(run.pending.prefix(limit))}
            return run
        case "search":
            let text=(request.search ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            let limit=min(500,request.articleLimit ?? 20)
            var run=LibraryRun(request:request,packageID:packageID,candidates:.search)
            var results:[SearchResult]=[]
            if try await source.hasArchiveFullText() {
                var offset=0
                while results.count<limit {
                    let page=try await source.fullTextPage(text,offset:offset,limit:min(searchPage,limit-results.count))
                    results += page.results;offset += page.results.count
                    if page.results.isEmpty {break}
                }
            }
            if results.isEmpty {results=try await source.search(text,limit:min(100,limit))}
            run.pending=results.prefix(limit).map(\.articleID)
            return run
        default:
            let texts=request.searchTexts
            if !texts.isEmpty,try await source.hasArchiveFullText() {
                var run=LibraryRun(request:request,packageID:packageID,candidates:.builtInSearch(estimated:0))
                run.searchQueue=texts
                return run
            }
            if !texts.isEmpty,let index,let coverage=try? await index.coverage(),coverage.indexed>0 {
                var run=LibraryRun(request:request,packageID:packageID,candidates:.textIndex(indexed:coverage.indexed,complete:coverage.complete))
                var seen=Set<String>()
                for text in texts {
                    for path in try await index.articlePaths(matching:text,limit:200_000) where seen.insert(path).inserted {
                        run.pending.append(.init(packageID:packageID,path:path))
                    }
                }
                run.estimatedCandidates=run.pending.count
                return run
            }
            var run=LibraryRun(request:request,packageID:packageID,candidates:.scan)
            run.scanOffset=0
            return run
        }
    }

    /// Reads up to `budget` more articles and counts exactly in each.
    public static func advance(_ initial:LibraryRun,source:any LibraryArticleSource,budget:Int=defaultBudget,concurrency:Int=4,
                               progress:(@Sendable (LibraryProgress) async -> Void)?=nil) async throws -> LibraryRun {
        var run=initial
        let query=run.request.countingQuery
        var read=0,lastReport=Date.distantPast
        struct Outcome:Sendable {let id:ArticleID;let path:String?;let title:String;let count:Int;let sample:String?}
        try await withThrowingTaskGroup(of:Outcome.self) {group in
            var inFlight=0
            func report(_ current:String) async {
                guard let progress,Date().timeIntervalSince(lastReport)>0.25 else {return}
                lastReport=Date()
                let remaining:Int?
                switch run.candidates {
                case .scan: remaining=run.scanTotal>0 ? Int(run.scanTotal-min(run.scanTotal,run.scanOffset ?? run.scanTotal))+run.pending.count : nil
                case .builtInSearch: remaining=run.estimatedCandidates.map {max(run.pending.count,$0-run.checked)}
                default: remaining=run.pending.count
                }
                await progress(.init(checked:run.checked,remaining:remaining,hits:run.hits.count,current:current))
            }
            func absorb(_ outcome:Outcome) {
                guard let path=outcome.path else {run.failed += 1;return}
                guard run.seen.insert(path).inserted else {return}
                run.checked += 1
                guard outcome.count>0 else {return}
                run.totalMatches += outcome.count
                run.hits.append(.init(path:path,title:outcome.title,count:outcome.count,sample:outcome.sample))
            }
            while read<budget {
                try Task.checkCancellation()
                if run.pending.isEmpty {try await refill(&run,source:source)}
                guard !run.pending.isEmpty else {break}
                let id=run.pending.removeFirst()
                if run.seen.contains(id.path) {continue}
                read += 1;inFlight += 1
                group.addTask {
                    do {
                        let article=try await source.article(for:id)
                        try Task.checkCancellation()
                        let page=ArticlePageMap.make(article)
                        let result=PageQueryEngine.run(query,on:page)
                        return Outcome(id:id,path:article.id.path,title:article.title,count:result.total,sample:result.matches.first.map {String($0.text.prefix(160))})
                    } catch is CancellationError {throw CancellationError()}
                    catch {return Outcome(id:id,path:nil,title:id.path,count:0,sample:nil)}
                }
                if inFlight>=max(1,concurrency),let outcome=try await group.next() {
                    inFlight -= 1;absorb(outcome);await report(outcome.title)
                }
            }
            while let outcome=try await group.next() {absorb(outcome);await report(outcome.title)}
        }
        if run.pending.isEmpty {try await refill(&run,source:source)}
        return run
    }

    /// Fetches more candidates from built-in search or the archive scan.
    static func refill(_ run:inout LibraryRun,source:any LibraryArticleSource) async throws {
        while run.pending.isEmpty,let text=run.searchQueue.first {
            let phrase=text.contains(where:\.isWhitespace) ? "\""+text.replacingOccurrences(of:"\"",with:"")+"\"" : text
            var page=try await source.fullTextPage(phrase,offset:run.searchOffset,limit:searchPage)
            // Some archives can't match phrases; fall back to all of its words, then filter exactly.
            if page.results.isEmpty,run.searchOffset == 0,phrase != text {page=try await source.fullTextPage(text,offset:0,limit:searchPage)}
            if run.searchOffset == 0 {
                run.estimatedCandidates=(run.estimatedCandidates ?? 0)+page.estimated
                run.candidates = .builtInSearch(estimated:run.estimatedCandidates ?? page.estimated)
            }
            run.pending=page.results.map(\.articleID).filter {!run.seen.contains($0.path)}
            if page.results.count<searchPage {run.searchQueue.removeFirst();run.searchOffset=0}
            else {run.searchOffset += page.results.count}
        }
        while run.pending.isEmpty,let offset=run.scanOffset {
            try Task.checkCancellation()
            let batch=try await source.articleBatch(offset:offset)
            run.scanTotal=batch.totalEntries
            guard batch.next>offset else {run.scanOffset=nil;break}
            run.pending=batch.articles.filter {!run.seen.contains($0.path)}
            run.scanOffset=batch.next>=batch.totalEntries ? nil : batch.next
        }
    }

    /// The article a title names, preferring an exact title match.
    public static func resolveTitle(_ raw:String,source:any LibraryArticleSource) async throws -> SearchResult? {
        let title=PageQuery.stripQuotes(raw.trimmingCharacters(in:.whitespacesAndNewlines))
        guard !title.isEmpty else {return nil}
        var found=try await source.search(title,limit:8)
        // The title index can be case-sensitive: try "Paris", "Ray Charles".
        let titled=title.split(separator:" ").map {$0.prefix(1).uppercased()+$0.dropFirst()}.joined(separator:" ")
        if !found.contains(where:{$0.title.caseInsensitiveCompare(title) == .orderedSame}),titled != title {
            found += try await source.search(titled,limit:8)
        }
        return found.first(where:{$0.title.caseInsensitiveCompare(title) == .orderedSame}) ?? found.first
    }
}

// MARK: - Plain-language answer

extension LibraryRun {
    /// "“Atlantic Records” appears in 28 articles. I read every article the archive's
    /// full-text search found for it (31) and counted exactly in each."
    public var answer:String {
        var parts=[result,coverage]
        if failed>0 {parts.append("\(LibraryRun.format(failed)) article\(failed == 1 ? "" : "s") couldn't be read.")}
        if !missingTitles.isEmpty {parts.append("I couldn't find "+missingTitles.map {"“\($0)”"}.joined(separator:", ")+" in this package.")}
        return parts.filter {!$0.isEmpty}.joined(separator:" ")
    }

    /// What the user called the thing they're counting.
    var subject:String {
        let q=request.query.normalized()
        if let title=q.linksTo {return "links to “\(title)”"}
        if q.unit == "phrase" || (q.isWordLike && q.equals != nil && q.startsWith == nil && q.endsWith == nil && q.partOfSpeech == nil) {
            return (q.equals ?? "").split(separator:"|").map {"“\($0)”"}.joined(separator:" or ")
        }
        return q.summary
    }
    var isMention:Bool {let q=request.query.normalized();return q.linksTo == nil && (q.unit == "phrase" || (q.isWordLike && q.equals != nil && q.startsWith == nil && q.endsWith == nil && q.partOfSpeech == nil))}
    var isLinkQuestion:Bool {request.query.normalized().linksTo != nil}

    var result:String {
        let n=hits.count,articles="\(Self.format(n)) article\(n == 1 ? "" : "s")"
        let within=isComplete ? "" : " so far"
        switch request.measure {
        case "total":
            let total=totalMatches
            if isMention {return total == 0 ? "\(subject) doesn't appear in the articles I read." : "\(subject) appears \(Self.format(total)) time\(total == 1 ? "" : "s") across \(articles)\(within)."}
            return total == 0 ? "I found no \(subject) in the articles I read." : "I found \(Self.format(total)) \(subject) across \(articles)\(within)."
        case "list":
            guard n>0 else {return isLinkQuestion ? "No article I read links to “\(request.query.normalized().linksTo ?? "")”." : "No article I read has \(subject)."}
            let top=ranked.prefix(5).map {"\($0.title) (\(Self.format($0.count)))"}.joined(separator:", ")
            let verb=isLinkQuestion ? "link to “\(request.query.normalized().linksTo ?? "")”" : isMention ? "mention \(subject)" : "have \(subject)"
            return "\(Self.capitalized(articles)) \(verb)\(within)"+(n>1 ? ". Most: \(top)." : ": \(top).")
        default:
            if isLinkQuestion {
                let title=request.query.normalized().linksTo ?? ""
                return n == 0 ? "No article I read links to “\(title)”." : "\(Self.capitalized(articles)) link to “\(title)”\(within)."
            }
            if isMention {return n == 0 ? "\(subject) doesn't appear in the articles I read." : "\(subject) appears in \(articles)\(within)."}
            return n == 0 ? "No article I read has \(subject)." : "\(Self.capitalized(articles)) have \(subject)\(within)."
        }
    }

    var coverage:String {
        let read="\(Self.format(checked)) article\(checked == 1 ? "" : "s")"
        let more="Say “check more articles” to keep going."
        var text:String
        switch candidates {
        case .builtInSearch(let estimated):
            text=isComplete ? "I read every article the archive's full-text search found (\(read)) and counted exactly in each."
                            : "I've read \(read) of about \(Self.format(max(estimated,checked))) that the archive's full-text search found. \(more)"
            if isLinkQuestion {text += " Links are found through articles that mention the title, so a link worded differently in an article that never names it could be missed."}
        case .textIndex(let indexed,let complete):
            if !isComplete {text="I've read \(read) of the \(Self.format(estimatedCandidates ?? checked)) the text index lists. \(more)"}
            else {text="I read every article the text index lists (\(read)) and counted exactly in each."}
            if !complete {text += " The text index covers only \(Self.format(indexed)) articles so far, so there may be more: finish building it under Research."}
            text += " Text in very short fragments, like a table cell, is only found if the article also mentions it in a paragraph."
            if isLinkQuestion {text += " Links are found through articles that mention the title."}
        case .scan:
            let entries=Self.format(Int(max(scanTotal,UInt64(checked))))
            text=isComplete ? "I read all \(read) in the package."
                            : "I've read \(read) of about \(entries) entries in the package. \(more)"
        case .linked(let section):
            text="I read the \(read) linked from this article"+(section.map {" (\($0))"} ?? "")+"."
            if !isComplete {text += " \(more)"}
        case .titles:
            text="I read the \(read) you named."
        case .search:
            text="I read the \(read) the search found."
            if !isComplete {text += " \(more)"}
        }
        return text
    }

    static func format(_ n:Int)->String {
        let formatter=NumberFormatter();formatter.numberStyle = .decimal
        return formatter.string(from:NSNumber(value:n)) ?? String(n)
    }
    static func capitalized(_ text:String)->String {text.prefix(1).uppercased()+text.dropFirst()}
}
