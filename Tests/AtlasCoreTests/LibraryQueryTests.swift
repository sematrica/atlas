import XCTest
@testable import AtlasCore

/// A small archive: articles by path, a fake full-text search and title search.
actor FakeLibrary:LibraryArticleSource {
    let articles:[String:(title:String,html:String)]
    let redirects:[String:String]
    let fullText:Bool
    var fullTextQueries:[String]=[]
    var reads=0
    init(_ articles:[String:(title:String,html:String)],redirects:[String:String]=[:],fullText:Bool=true) {
        self.articles=articles;self.redirects=redirects;self.fullText=fullText
    }
    func article(for id:ArticleID) async throws -> Article {
        reads += 1
        let path=redirects[id.path] ?? id.path
        guard let entry=articles[path] else {throw AtlasError.articleUnavailable}
        return Article(id:.init(packageID:"pkg",path:path),title:entry.title,html:entry.html)
    }
    func search(_ query:String,limit:Int) async throws -> [SearchResult] {
        // Title search is case-sensitive, like libzim's suggestions.
        articles.filter {$0.value.title.hasPrefix(query)}.sorted {$0.key<$1.key}.prefix(limit).map {.init(articleID:.init(packageID:"pkg",path:$0.key),title:$0.value.title,excerpt:"")}
    }
    func hasArchiveFullText() async throws -> Bool {fullText}
    func fullTextPage(_ query:String,offset:Int,limit:Int) async throws -> LibraryFullTextPage {
        fullTextQueries.append(query)
        let words=query.replacingOccurrences(of:"\"",with:"").lowercased().split(separator:" ").map(String.init)
        let matching=articles.filter {entry in words.allSatisfy {entry.value.html.lowercased().contains($0)}}.sorted {$0.key<$1.key}
        let page=matching.dropFirst(offset).prefix(limit).map {SearchResult(articleID:.init(packageID:"pkg",path:$0.key),title:$0.value.title,excerpt:"")}
        return .init(results:Array(page),estimated:matching.count)
    }
    func resolve(paths:[String]) async throws -> [String:SearchResult] {
        var found:[String:SearchResult]=[:]
        for path in paths {
            let target=redirects[path] ?? path
            if let entry=articles[target] {found[path] = .init(articleID:.init(packageID:"pkg",path:target),title:entry.title,excerpt:"")}
        }
        return found
    }
    func articleBatch(offset:UInt64) async throws -> ArchiveArticleBatch {
        let paths=articles.keys.sorted()
        let end=min(paths.count,Int(offset)+2)
        return .init(articles:paths[Int(offset)..<end].map {.init(packageID:"pkg",path:$0)},next:UInt64(end),totalEntries:UInt64(paths.count))
    }
}

struct FakeIndex:LibraryTextIndex {
    let paths:[String:[String]]
    let coverageValue:LibraryIndexCoverage
    func articlePaths(matching phrase:String,limit:Int) async throws -> [String] {Array((paths[phrase.lowercased()] ?? []).prefix(limit))}
    func coverage() async throws -> LibraryIndexCoverage {coverageValue}
}

final class LibraryQueryTests:XCTestCase {
    static let articles:[String:(title:String,html:String)]=[
        "Ray_Charles":("Ray Charles","<p>He signed with <a href=\"./Atlantic_Records\">Atlantic Records</a>. Atlantic Records made him a star. Jazz and soul.</p><h2>Albums</h2><ul><li><a href=\"./Genius\">The Genius</a></li><li><a href=\"./Modern_Sounds\">Modern Sounds</a></li></ul>"),
        "Atlantic_Records":("Atlantic Records","<p>Atlantic Records is a label in New York. It signed Ray Charles.</p>"),
        "Genius":("The Genius","<p>A jazz album. Jazz, jazz and more jazz.</p><p>Recorded for <a href=\"./Atlantic_Records\">the label</a>.</p>"),
        "Modern_Sounds":("Modern Sounds","<p>A country album with no jazz at all? Well, one jazz.</p>"),
        "Paris":("Paris","<p>Paris is a city. Visit <a href=\"./Paris\">Paris</a>.</p>"),
        "Lyon":("Lyon","<p>Lyon is near <a href=\"./Paris\">the capital</a>.</p>"),
        "Broken":("Broken","<p>atlantic records</p>")
    ]
    func phrase(_ text:String)->PageQuery {var q=PageQuery(unit:"phrase");q.equals=text;return q}

    func testMentionsUseBuiltInSearchAndCountExactly() async throws {
        let library=FakeLibrary(Self.articles)
        let request=LibraryRequest(scope:"library",measure:"articles",query:phrase("Atlantic Records"))
        var run=try await LibraryEngine.start(request,packageID:"pkg",source:library,index:nil,current:nil)
        run=try await LibraryEngine.advance(run,source:library)
        XCTAssertEqual(Set(run.hits.map(\.path)),["Ray_Charles","Atlantic_Records","Broken"])
        XCTAssertEqual(run.hits.first {$0.path == "Ray_Charles"}?.count,2)
        XCTAssertTrue(run.coversLibrary)
        XCTAssertEqual(run.answer.components(separatedBy:". ").first,"“Atlantic Records” appears in 3 articles")
        let queries=await library.fullTextQueries
        XCTAssertEqual(queries.first,"\"Atlantic Records\"","a phrase is searched as a phrase")
    }

    func testTotalsAndListsAcrossLinkedArticles() async throws {
        let library=FakeLibrary(Self.articles)
        let current=(id:ArticleID(packageID:"pkg",path:"Ray_Charles"),page:ArticlePageMap.make(html:Self.articles["Ray_Charles"]!.html,document:"Ray_Charles"))
        var jazz=PageQuery(unit:"word");jazz.equals="jazz"
        let request=LibraryRequest(scope:"linked",measure:"total",query:jazz,section:"Albums")
        var run=try await LibraryEngine.start(request,packageID:"pkg",source:library,index:nil,current:current)
        XCTAssertEqual(run.pending.map(\.path),["Genius","Modern_Sounds"],"only links in the Albums section")
        run=try await LibraryEngine.advance(run,source:library)
        XCTAssertEqual(run.totalMatches,6)
        XCTAssertEqual(run.ranked.map(\.title),["The Genius","Modern Sounds"])
        XCTAssertTrue(run.answer.hasPrefix("“jazz” appears 6 times across 2 articles."),run.answer)
        XCTAssertTrue(run.answer.contains("linked from this article (Albums)"))
    }

    func testLinksToMatchTheDestinationNotTheWording() async throws {
        let library=FakeLibrary(Self.articles)
        var links=PageQuery();links.linksTo="Paris"
        let request=LibraryRequest(scope:"library",measure:"list",query:links)
        var run=try await LibraryEngine.start(request,packageID:"pkg",source:library,index:nil,current:nil)
        run=try await LibraryEngine.advance(run,source:library)
        XCTAssertEqual(Set(run.hits.map(\.title)),["Paris","Lyon"],"Lyon's link says “the capital” but points to Paris")
        XCTAssertTrue(run.answer.hasPrefix("2 articles link to “Paris”"),run.answer)
        XCTAssertTrue(run.answer.contains("worded differently"))
    }

    func testTextIndexCandidatesAndHonestCoverage() async throws {
        let library=FakeLibrary(Self.articles,fullText:false)
        let index=FakeIndex(paths:["atlantic records":["Atlantic_Records","Ray_Charles"]],coverageValue:.init(indexed:5,complete:false))
        let request=LibraryRequest(scope:"library",measure:"articles",query:phrase("atlantic records"))
        var run=try await LibraryEngine.start(request,packageID:"pkg",source:library,index:index,current:nil)
        run=try await LibraryEngine.advance(run,source:library)
        XCTAssertEqual(run.hits.count,2)
        XCTAssertFalse(run.coversLibrary,"the index isn't finished")
        XCTAssertTrue(run.answer.contains("covers only 5 articles so far"),run.answer)
    }

    func testScanWithoutSearchContinuesWhereItStopped() async throws {
        let library=FakeLibrary(Self.articles,fullText:false)
        var capitals=PageQuery(unit:"letter");capitals.letterCase="uppercase"
        let request=LibraryRequest(scope:"library",measure:"total",query:capitals)
        var run=try await LibraryEngine.start(request,packageID:"pkg",source:library,index:nil,current:nil)
        run=try await LibraryEngine.advance(run,source:library,budget:3)
        XCTAssertEqual(run.checked,3)
        XCTAssertFalse(run.isComplete)
        XCTAssertTrue(run.answer.contains("check more articles"),run.answer)
        run=try await LibraryEngine.advance(run,source:library,budget:100)
        XCTAssertEqual(run.checked,Self.articles.count)
        XCTAssertTrue(run.coversLibrary)
        XCTAssertTrue(run.answer.contains("I read all 7 articles"),run.answer)
    }

    func testTitlesRedirectsAndFailures() async throws {
        let library=FakeLibrary(Self.articles,redirects:["Genius_album":"Genius"])
        var jazz=PageQuery(unit:"word");jazz.equals="jazz"
        let request=LibraryRequest(scope:"titles",measure:"total",query:jazz,titles:["the genius","Modern Sounds","Nowhere"])
        var run=try await LibraryEngine.start(request,packageID:"pkg",source:library,index:nil,current:nil)
        XCTAssertEqual(run.pending.map(\.path),["Genius","Modern_Sounds"],"titles resolve case-insensitively")
        run.pending.append(.init(packageID:"pkg",path:"Genius_album"))
        run.pending.append(.init(packageID:"pkg",path:"Missing"))
        run=try await LibraryEngine.advance(run,source:library)
        XCTAssertEqual(run.checked,2,"a redirect to an article already read is counted once")
        XCTAssertEqual(run.failed,1)
        XCTAssertTrue(run.answer.contains("couldn't find “Nowhere”"),run.answer)
        XCTAssertTrue(run.answer.contains("1 article couldn't be read"),run.answer)
    }

    func testRequestValidation() {
        var meaning=PageQuery(unit:"word");meaning.meaning="about music"
        XCTAssertFalse(LibraryRequest(query:meaning).problems.isEmpty)
        XCTAssertFalse(LibraryRequest(scope:"titles",query:phrase("x")).problems.isEmpty)
        XCTAssertFalse(LibraryRequest(scope:"everywhere",query:phrase("x")).problems.isEmpty)
        XCTAssertTrue(LibraryRequest(query:phrase("x")).problems.isEmpty)
        XCTAssertEqual(LibraryRequest(query:phrase("a|b")).searchTexts,["a","b"])
    }
}
