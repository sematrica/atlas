import XCTest
@testable import AtlasCore

final class CrawlerCommandTests:XCTestCase {
    func testTravelRulesHandleEncodedLocalDestinations() {
        var rules=CrawlerTravelRules();rules.avoid("United States")
        XCTAssertFalse(rules.permits("atlas://local/A/United_States"))
        XCTAssertFalse(rules.permits("United%20States"))
        XCTAssertTrue(rules.permits("Ray Charles"))
        rules.avoid("  ");XCTAssertEqual(rules.blocked,["United States"])
        rules.allowLinks=false;XCTAssertFalse(rules.allowLinks)
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
