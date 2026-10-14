import XCTest
@testable import AtlasCore

final class ArticleConnectionTests:XCTestCase {
    /// An article whose text mentions `text` and links to each path.
    static func page(_ text:String,_ links:[String])->String {
        "<p>\(text) "+links.map {"<a href=\"./\($0)\">\($0.replacingOccurrences(of:"_",with:" "))</a>"}.joined(separator:" ")+"</p>"
    }
    static func library(_ pages:[String:(title:String,text:String,links:[String])],redirects:[String:String]=[:],fullText:Bool=true)->FakeLibrary {
        FakeLibrary(pages.mapValues {($0.title,page($0.text,$0.links))},redirects:redirects,fullText:fullText)
    }

    func connect(_ library:FakeLibrary,from:String?="Ray Charles",to:String,current:ArticleID?=nil,budget:Int=2_000) async throws -> ConnectionRun {
        let run=try await ConnectionEngine.start(from:from,to:to,current:current,packageID:"pkg",source:library,index:nil)
        return try await ConnectionEngine.advance(run,source:library,budget:budget,concurrency:2)
    }

    func testDirectLink() async throws {
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Atlantic_Records","Paris"]),
            "Atlantic_Records":("Atlantic Records","A label.",[]),
            "Paris":("Paris","A city.",[])
        ])
        let run=try await connect(library,to:"Paris")
        XCTAssertEqual(run.chain?.map(\.title),["Ray Charles","Paris"])
        XCTAssertTrue(run.proven)
        XCTAssertEqual(run.answer,"Ray Charles links straight to Paris.")
        XCTAssertEqual(run.read,1)
    }

    func testTwoLinksAreProvenShortest() async throws {
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Atlantic_Records","Georgia"]),
            "Atlantic_Records":("Atlantic Records","A label.",["New_York_City"]),
            "Georgia":("Georgia","A state.",[]),
            "New_York_City":("New York City","A city.",[])
        ])
        let run=try await connect(library,to:"New York City")
        XCTAssertEqual(run.chain?.map(\.title),["Ray Charles","Atlantic Records","New York City"])
        XCTAssertEqual(run.chain?.last?.via,"New_York_City")
        XCTAssertTrue(run.proven)
        XCTAssertTrue(run.answer.hasPrefix("Ray Charles → Atlantic Records → New York City: 2 links. That's the shortest chain"),run.answer)
    }

    /// Paris is three links away. An article that mentions Paris and links to it is the stepping stone.
    func testSteppingStoneFromSearchAndRedirects() async throws {
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Atlantic_Records","Georgia"]),
            "Atlantic_Records":("Atlantic Records","A label.",["New_York_City"]),
            "Georgia":("Georgia","A state.",["Atlanta"]),
            "Atlanta":("Atlanta","A city.",[]),
            "New_York_City":("New York City","Flights to Paris leave daily.",["French_capital"]),
            "Paris":("Paris","A city.",[]),
            "Louvre":("Louvre","A museum in Paris.",["Paris"])
        ],redirects:["French_capital":"Paris"])
        let run=try await connect(library,to:"Paris")
        XCTAssertEqual(run.chain?.map(\.title),["Ray Charles","Atlantic Records","New York City","Paris"])
        // The last link is the redirect the article actually writes, so the spider can find it.
        XCTAssertEqual(run.chain?.last?.via,"French_capital")
        XCTAssertTrue(run.proven)
        XCTAssertTrue(run.answer.contains("none of the 2 articles Ray Charles links to links to Paris directly"),run.answer)
    }

    func testPrefersTheShorterChain() async throws {
        // A three-link chain through a stepping stone exists, but so does a two-link one.
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Atlantic_Records","Soul_music"]),
            "Atlantic_Records":("Atlantic Records","A label.",["Jazz_club"]),
            "Jazz_club":("Jazz club","Jazz lives here.",["Jazz"]),
            "Soul_music":("Soul music","Born of gospel and jazz.",["Jazz"]),
            "Jazz":("Jazz","Music.",[])
        ])
        let run=try await connect(library,to:"Jazz")
        XCTAssertEqual(run.steps,2)
        XCTAssertEqual(run.chain?.map(\.title),["Ray Charles","Soul music","Jazz"])
        XCTAssertTrue(run.proven)
    }

    func testWithoutSearchItReadsOutward() async throws {
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Atlantic_Records","Georgia"]),
            "Atlantic_Records":("Atlantic Records","A label.",["New_York_City"]),
            "Georgia":("Georgia","A state.",["Atlanta"]),
            "Atlanta":("Atlanta","A city.",[]),
            "New_York_City":("New York City","A city.",["Paris"]),
            "Paris":("Paris","A city.",[])
        ],fullText:false)
        let run=try await connect(library,to:"Paris")
        XCTAssertFalse(run.hinted)
        XCTAssertEqual(run.chain?.map(\.title),["Ray Charles","Atlantic Records","New York City","Paris"])
        XCTAssertTrue(run.proven)
    }

    func testStopsAndResumes() async throws {
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Atlantic_Records","Georgia"]),
            "Atlantic_Records":("Atlantic Records","A label.",["New_York_City"]),
            "Georgia":("Georgia","A state.",[]),
            "New_York_City":("New York City","A city.",["Paris"]),
            "Paris":("Paris","A city.",[])
        ],fullText:false)
        var run=try await ConnectionEngine.start(from:"Ray Charles",to:"Paris",current:nil,packageID:"pkg",source:library,index:nil)
        run=try await ConnectionEngine.advance(run,source:library,budget:2,concurrency:1)
        XCTAssertNil(run.chain)
        XCTAssertFalse(run.isComplete)
        XCTAssertTrue(run.answer.contains("Say “keep looking”"),run.answer)
        XCTAssertTrue(run.answer.contains("no full-text search"),run.answer)
        run=try await ConnectionEngine.advance(run,source:library,budget:10,concurrency:1)
        XCTAssertEqual(run.steps,3)
        XCTAssertTrue(run.proven)
    }

    func testFoundButNotProvenWhenTheLevelIsUnfinished() async throws {
        // Ray Charles → Atlantic Records → Ahmet Ertegun → Louvre → Paris (4 links). Louvre mentions and
        // links to Paris; Ahmet Ertegun mentions Paris too, so it's read first and completes the chain.
        var pages:[String:(title:String,text:String,links:[String])]=[
            "Ray_Charles":("Ray Charles","A singer.",["Atlantic_Records"]),
            "Atlantic_Records":("Atlantic Records","A label.",["Ahmet_Ertegun"]+(1...6).map {"Artist_\($0)"}),
            "Ahmet_Ertegun":("Ahmet Ertegun","He loved Paris.",["Louvre"]),
            "Louvre":("Louvre","A museum in Paris.",["Paris"]),
            "Paris":("Paris","A city.",[])
        ]
        for n in 1...6 {pages["Artist_\(n)"]=("Artist \(n)","A musician.",[])}
        let library=Self.library(pages)
        let run=try await connect(library,to:"Paris",budget:5)
        XCTAssertEqual(run.chain?.map(\.title),["Ray Charles","Atlantic Records","Ahmet Ertegun","Louvre","Paris"])
        XCTAssertFalse(run.proven)
        XCTAssertFalse(run.isComplete)
        XCTAssertTrue(run.answer.contains("a shorter one might exist"),run.answer)
        // Reading the rest of that level rules out a three-link chain.
        let finished=try await ConnectionEngine.advance(run,source:library,budget:50,concurrency:2)
        XCTAssertTrue(finished.proven)
        XCTAssertEqual(finished.steps,4)
    }

    func testNoConnection() async throws {
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Georgia"]),
            "Georgia":("Georgia","A state.",[]),
            "Paris":("Paris","A city.",[])
        ])
        let run=try await connect(library,to:"Paris")
        XCTAssertNil(run.chain)
        XCTAssertTrue(run.exhausted)
        XCTAssertTrue(run.answer.hasPrefix("There's no chain of links from Ray Charles to Paris"),run.answer)
    }

    func testStartsFromTheOpenArticle() async throws {
        let library=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Paris"]),
            "Paris":("Paris","A city.",[])
        ])
        let open=ArticleID(packageID:"pkg",path:"Ray_Charles")
        for from in [nil,"this article","here"] as [String?] {
            let run=try await connect(library,from:from,to:"paris",current:open)
            XCTAssertEqual(run.chain?.map(\.title),["Ray Charles","Paris"])
        }
        let moon=Self.library([
            "Ray_Charles":("Ray Charles","A singer.",["Moon"]),
            "Moon":("Moon","Earth's satellite.",[]),
            "The_Moon_and_Sixpence":("The Moon and Sixpence","A novel.",[])
        ])
        let article=try await connect(moon,from:"this",to:"the Moon",current:open)
        XCTAssertEqual(article.target.title,"Moon","“the Moon” means the article Moon")
        let same=try await connect(library,from:nil,to:"Ray Charles",current:open)
        XCTAssertEqual(same.answer,"That's the same article.")
        do {
            _=try await connect(library,from:nil,to:"Paris",current:nil)
            XCTFail("Needs a start")
        } catch {XCTAssertTrue(error.localizedDescription.contains("Open an article first"))}
        do {
            _=try await connect(library,to:"Atlantis")
            XCTFail("Atlantis isn't in the package")
        } catch {XCTAssertTrue(error.localizedDescription.contains("couldn't find an article called “Atlantis”"))}
    }
}
