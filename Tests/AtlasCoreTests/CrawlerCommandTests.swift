import XCTest
@testable import AtlasCore

final class CrawlerCommandTests:XCTestCase {
    func testImmediateCommandsDoNotRequireAModel() {
        XCTAssertEqual(CrawlerDirective.local("Please stop now!"),.init("stop"))
        XCTAssertEqual(CrawlerDirective.local("move slowly"),.init("slower"))
        XCTAssertEqual(CrawlerDirective.local("move faster"),.init("faster"))
        XCTAssertEqual(CrawlerDirective.local("go left"),.init("direction","left"))
        XCTAssertEqual(CrawlerDirective.local("find only adjectives and highlight them"),.init("words","adjectives"))
        XCTAssertEqual(CrawlerDirective.local("Please go to Early life!"),.init("go","Early life"))
        XCTAssertEqual(CrawlerDirective.local("don't go to United States"),.init("avoid","United States"))
    }
    func testRejectsUnboundedOrUnknownModelInstructions() {
        XCTAssertFalse(CrawlerDirective("javascript","alert(1)").isValid)
        XCTAssertFalse(CrawlerDirective("direction","northwest").isValid)
        XCTAssertFalse(CrawlerDirective("go",String(repeating:"x",count:301)).isValid)
        XCTAssertFalse(CrawlerDirective("words","everything").isValid)
    }
    func testModelHighlightWordingNormalizesOnlyKnownRules() throws {
        XCTAssertEqual(try CrawlerDirective.interpreted(json:#"{"action":"highlight","value":"words starting with A"}"#),.init("wordPrefix","A"))
        XCTAssertEqual(try CrawlerDirective.interpreted(json:#"{"action":"highlight","value":"verbs"}"#),.init("words","verbs"))
        XCTAssertThrowsError(try CrawlerDirective.interpreted(json:#"{"action":"highlight","value":"go to secret"}"#))
        XCTAssertThrowsError(try CrawlerDirective.interpreted(json:#"{"action":"javascript","value":"alert(1)"}"#))
    }
    func testTravelRulesHandleEncodedLocalDestinations() {
        var rules=CrawlerTravelRules();rules.avoid("United States")
        XCTAssertFalse(rules.permits("atlas://local/A/United_States"))
        XCTAssertFalse(rules.permits("United%20States"))
        XCTAssertTrue(rules.permits("Ray Charles"))
        rules.allowLinks=false;XCTAssertFalse(rules.allowLinks)
    }
    func testWordClassificationProducesOnlyLocalAdjectiveRanges() {
        let text="The beautiful red butterfly flew over the quiet garden."
        let terrain=CrawlerTerrain(id:"local",group:"p",order:0,kind:.text,rect:.init(x:20,y:20,width:100,height:20),text:text)
        let observation=CrawlerObservation(center:.init(x:50,y:50),radius:140,viewport:.init(x:0,y:0,width:300,height:300),documentWidth:300,documentHeight:300,terrain:[terrain])
        let marks=CrawlerWordClassifier.highlights(in:observation,kind:"adjectives")
        let words=marks.map {(text as NSString).substring(with:NSRange(location:$0.start,length:$0.end-$0.start)).lowercased()}
        XCTAssertTrue(words.contains("beautiful"),words.description)
        XCTAssertTrue(words.contains("quiet"),words.description)
        XCTAssertFalse(words.contains("butterfly"));XCTAssertFalse(words.contains("flew"))
        XCTAssertTrue(marks.allSatisfy {$0.id == "local" && $0.start>=0 && $0.end<=text.utf16.count})
    }
    func testPrefixRulesAndModelSelectionStayWithinObservedWords() throws {
        XCTAssertEqual(CrawlerDirective.local("highlight words starting with A"),.init("wordPrefix","A"))
        XCTAssertEqual(CrawlerDirective.local("highlight words of French origin"),.init("wordMeaning","words of French origin"))
        XCTAssertFalse(CrawlerDirective("wordPrefix","a b").isValid)
        let first=CrawlerTerrain(id:"a",group:"p",order:0,kind:.text,rect:.init(x:0,y:0,width:100,height:20),text:"Apple ap")
        let second=CrawlerTerrain(id:"b",group:"p",order:8,kind:.text,rect:.init(x:0,y:20,width:100,height:20),text:"ricot banana café")
        let observation=CrawlerObservation(center:.init(x:20,y:20),radius:140,viewport:.init(x:0,y:0,width:300,height:300),documentWidth:300,documentHeight:300,terrain:[first,second])
        let words=CrawlerWordSelection.candidates(in:observation)
        XCTAssertEqual(words.map(\.text),["Apple","apricot","banana","café"])
        let marks=CrawlerWordSelection.prefixMarks("A",in:observation)
        XCTAssertEqual(marks.count,3) // apricot spans two local fragments
        XCTAssertEqual(marks.last?.id,"b");XCTAssertEqual(marks.last?.end,5)
        let selected=try CrawlerWordSelection.modelMarks(json:#"{"matches":[3,3]}"#,candidates:words)
        XCTAssertEqual(selected.count,1);XCTAssertEqual(selected.first?.id,"b")
        XCTAssertThrowsError(try CrawlerWordSelection.modelMarks(json:#"{"matches":[64]}"#,candidates:words))
        XCTAssertThrowsError(try CrawlerWordSelection.modelMarks(json:#"{"matches":[-1]}"#,candidates:words))
        XCTAssertThrowsError(try CrawlerWordSelection.modelMarks(json:#"{"matches":["café"]}"#,candidates:words))
    }
    func testManualGuidanceKeepsHuntButWaitsAtDestination() {
        var agent=ProceduralCrawlerAgent()
        agent.start(position:.init(x:100,y:100),mission:.stringHunt("original"))
        agent.guide(to:.init(x:200,y:100))
        for _ in 0..<300 {
            agent.perceive(.init(center:agent.state.position,radius:140,viewport:.init(x:0,y:0,width:800,height:600),documentWidth:800,documentHeight:600,terrain:[]))
            agent.advance(dt:1.0/60)
        }
        XCTAssertEqual(agent.state.behavior,.paused)
        XCTAssertLessThan(agent.state.position.distance(to:.init(x:200,y:100)),10)
        XCTAssertEqual(agent.state.mission,.stringHunt("original"))
        let position=agent.state.position
        agent.advance(dt:0.05);XCTAssertEqual(agent.state.position,position)
        agent.endGuidance();agent.suppressHunt(false);agent.resume();XCTAssertEqual(agent.state.behavior,.exploring)
    }
}
