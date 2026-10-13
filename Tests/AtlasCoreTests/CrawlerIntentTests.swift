import XCTest
@testable import AtlasCore

final class CrawlerIntentTests:XCTestCase {
    func testNaturalGrammarVariantsHaveIdenticalIntent() {
        let variants=["find all verbs and highlight","find all verbs and highlight them","highlight all verbs","Please mark every verb"]
        for text in variants {XCTAssertEqual(CrawlerIntentPlan.local(text)?.words?.partOfSpeech,"verbs",text)}
        XCTAssertEqual(CrawlerIntentPlan.local("find all words that start with s")?.words?.prefix,"s")
        XCTAssertEqual(CrawlerIntentPlan.local("Find all verbs starting with S and highlight them.")?.words,.init(partOfSpeech:"verbs",prefix:"s"))
    }
    func testAmbiguousMissionAsksForGoal() {
        XCTAssertNotNil(CrawlerIntentPlan.local("find semantic hunt")?.clarification)
        XCTAssertEqual(CrawlerIntentPlan.local("semantic hunt for volcanic activity")?.actions,[.init("mission","volcanic activity")])
        XCTAssertNil(CrawlerIntentPlan.local("find verbs unless they refer to fictional events"))
    }
    func testCompoundGrammarDoesNotDropSectionConstraint() {
        let plan=CrawlerIntentPlan.local("Find all verbs starting with s and highlight them, and avoid the References section")
        XCTAssertEqual(plan?.words,.init(partOfSpeech:"verbs",prefix:"s"))
        XCTAssertEqual(plan?.avoidSections,["references"])
        XCTAssertTrue(plan?.valid ?? false)
    }
    func testIntersectionUsesRealWordRanges() {
        let text="Birds sing and soar while beautiful stars shine."
        let sample=CrawlerObservation(center:.zero,radius:140,viewport:.init(x:0,y:0,width:300,height:300),documentWidth:300,documentHeight:300,terrain:[.init(id:"p1",group:"p",order:0,kind:.text,rect:.init(x:0,y:0,width:100,height:20),text:text,section:"Life")])
        let words=CrawlerWordRule(partOfSpeech:"verbs",prefix:"s",excluding:["shine"]).candidates(in:sample).map(\.text)
        XCTAssertTrue(words.contains("soar"),words.description)
        XCTAssertFalse(words.contains("stars"));XCTAssertFalse(words.contains("beautiful"));XCTAssertFalse(words.contains("shine"))
        let tail=CrawlerWordRule(suffix:"ful",contains:"auti").candidates(in:sample).map(\.text)
        XCTAssertEqual(tail,["beautiful"])
    }
    func testPlanValidationRejectsContradictionsAndUnsupportedActions() throws {
        let good=try CrawlerIntentPlan.decode(#"{"actions":[{"action":"slower"}],"words":{"partOfSpeech":"verbs","prefix":"s"},"avoidSections":["References"],"explore":true}"#)
        XCTAssertTrue(good.valid)
        XCTAssertThrowsError(try CrawlerIntentPlan.decode(#"{"actions":[],"words":{"prefix":"s","unsupported":"secret"}}"#))
        XCTAssertFalse(CrawlerIntentPlan(actions:[.init("javascript","code")]).valid)
        XCTAssertFalse(CrawlerIntentPlan(actions:[.init("stay"),.init("allowLinks")]).valid)
        XCTAssertFalse(CrawlerIntentPlan(actions:[.init("mission","volcanoes")],words:.init(prefix:"s")).valid)
        XCTAssertFalse(CrawlerIntentPlan(clarification:"Why?",words:.init(prefix:"s")).valid)
        XCTAssertFalse(CrawlerIntentPlan(words:.init()).valid)
    }
}
