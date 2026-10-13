import XCTest
@testable import AtlasCore

final class CrawlerPageTests:XCTestCase {
    func page(_ text:String) throws -> CrawlerPageMap {
        let value:[String:Any] = ["document":"test","revision":1,"viewport":["x":0,"y":0,"width":800,"height":600],"documentWidth":800,"documentHeight":1200,"blocks":[["id":"a","text":text,"rect":["x":0,"y":0,"width":700,"height":100]]],"links":[],"images":[],"truncated":false]
        return try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testExactMeasurementsPreserveUTF16Offsets() throws {
        let p=try page("🕷️ Hi. The extraordinary creature walks confidently.")
        let word=try XCTUnwrap(CrawlerPageAnalysis.longest(p,sentence:false))
        XCTAssertEqual(word.text,"extraordinary")
        XCTAssertEqual((p.blocks[0].text as NSString).substring(with:NSRange(location:word.start,length:word.end-word.start)),word.text)
        let sentence=try XCTUnwrap(CrawlerPageAnalysis.longest(p,sentence:true))
        XCTAssertTrue(sentence.text.contains("extraordinary"))
        let words=CrawlerPageAnalysis.ranges(p,unit:.word,footholds:["noun","verb"])
        XCTAssertTrue(words.contains {$0.text == "creature"});XCTAssertFalse(words.contains {$0.text == "confidently"})
    }
    func testRankedWordUsesDistinctSpellingsAndStableTieOrder() throws {
        let p=try page("🕷️ astronomy astronomy butterfly mountains butterfly field")
        let first=try XCTUnwrap(CrawlerPageAnalysis.rankedWord(p,rank:1))
        let second=try XCTUnwrap(CrawlerPageAnalysis.rankedWord(p,rank:2))
        XCTAssertEqual(first.text,"astronomy")
        XCTAssertEqual(second.text,"butterfly")
        XCTAssertEqual((p.blocks[0].text as NSString).substring(with:NSRange(location:second.start,length:second.end-second.start)),second.text)
        XCTAssertEqual(CrawlerPageAnalysis.rankedWord(p,rank:2,distinct:false)?.text,"astronomy")
        XCTAssertNil(CrawlerPageAnalysis.rankedWord(p,rank:100))
    }
    func testGeneralSelectorUsesReadingOrderAndSectionWithoutChangingTarget() throws {
        let rect:[String:Int]=["x":0,"y":0,"width":700,"height":100]
        let object:[String:Any]=["document":"test","revision":1,"viewport":rect,"documentWidth":800,"documentHeight":1200,"truncated":false,"links":[],"images":[],"blocks":[
            ["id":"heading","text":"Atlas", "section":"introduction","rect":rect],
            ["id":"intro","text":"Bees inspect extraordinary flowers. They fly.","section":"introduction","rect":rect],
            ["id":"later","text":"Another tiny insect watches.","section":"Details","rect":rect]
        ]]
        let p=try JSONDecoder().decode(CrawlerPageMap.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(CrawlerPageAnalysis.select(p,unit:"word",order:"first")?.text,"Atlas")
        XCTAssertEqual(CrawlerPageAnalysis.select(p,unit:"word",order:"last")?.text,"watches")
        XCTAssertEqual(CrawlerPageAnalysis.select(p,unit:"word",order:"longest")?.text,"extraordinary")
        XCTAssertEqual(CrawlerPageAnalysis.select(p,unit:"word",order:"shortest")?.text,"fly")
        XCTAssertEqual(CrawlerPageAnalysis.select(p,unit:"word",order:"first",section:"Details")?.text,"Another")
        XCTAssertEqual(CrawlerPageAnalysis.select(p,unit:"word",order:"first",section:"Missing"),nil)
        XCTAssertTrue(CrawlerPageAnalysis.select(p,unit:"sentence",order:"first")?.text.contains("Atlas") == true)
        XCTAssertTrue(CrawlerPageAnalysis.select(p,unit:"sentence",order:"last")?.text.contains("watches") == true)
        XCTAssertNil(CrawlerPageAnalysis.select(p,unit:"sentence",order:"nthLongest",rank:2))
    }
    func testBasicRequestsAndRestrictions() {
        XCTAssertEqual(CrawlerPagePlan.local("Find the longest sentence in this page")?.operation,"longestSentence")
        XCTAssertEqual(CrawlerPagePlan.local("How many hyperlinks does this page have?")?.operation,"countLinks")
        XCTAssertEqual(CrawlerPagePlan.local("Go to the longest word in this article but do so only stepping on nouns or verbs")?.footholds,["noun","verb"])
        XCTAssertNil(CrawlerPagePlan.local("Find the longest word excluding names"))
        XCTAssertFalse(CrawlerPagePlan(operation:"longestSentence",footholds:["noun"]).valid)
    }
    func testConnectedRouteAndNoIllegalFallbackFeet() throws {
        let points=(0...8).map {DocumentPosition(x:Double($0)*40,y:100)}
        let route=try XCTUnwrap(CrawlerPageAnalysis.route(from:.init(x:0,y:100),to:.init(x:320,y:100),footholds:points))
        XCTAssertEqual(route.last,points.last)
        XCTAssertNil(CrawlerPageAnalysis.route(from:.zero,to:.init(x:1000,y:1000),footholds:points))
        let anchors=points.enumerated().map {TerrainAnchor(id:String($0.offset),position:$0.element,kind:.text)}
        var legs=CrawlerLegController();legs.reset(at:points[0]);XCTAssertTrue(legs.plant(body:points[0],anchors:anchors))
        for step in 0...320 {
            legs.advance(body:.init(x:Double(step),y:100),velocity:.init(x:50,y:0),anchors:anchors,dt:0.02,reduceMotion:false,strict:true)
            for leg in legs.legs {XCTAssertTrue(points.contains(leg.to));if !leg.isStepping {XCTAssertTrue(points.contains(leg.foot))}}
        }
    }
    func testModelToolPlan() async throws {
        guard ProcessInfo.processInfo.environment["ATLAS_RUN_BODY_LIVE"] == "1" else {throw XCTSkip("Opt-in local model embodiment plan")}
        let result=try await CrawlerPagePlan.interpret("Could you take me to the longest word in the article, but land your feet only on nouns or verbs?",provider:OllamaProvider(),model:"llama3.1:latest")
        XCTAssertEqual(result.operation,"longestWord");XCTAssertEqual(Set(result.footholds ?? []),Set(["noun","verb"]))
    }
}
