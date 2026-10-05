import XCTest
@testable import AtlasCore

final class CrawlerTests:XCTestCase {
    func testScuttlingHasFastBurstsAndBriefStationaryInspections() {
        var agent=ProceduralCrawlerAgent()
        agent.start(position:.init(x:100,y:100),mission:.freeCrawl)
        var peak=0.0,stops=0
        for _ in 0..<600 {
            agent.perceive(sample([],center:agent.state.position))
            agent.advance(dt:1.0/60)
            peak=max(peak,hypot(agent.state.velocity.x,agent.state.velocity.y))
            if agent.state.elapsed>1,agent.state.behavior == .inspecting,agent.state.velocity == .zero {stops += 1}
        }
        XCTAssertGreaterThan(peak,90)
        XCTAssertGreaterThan(stops,5)
        XCTAssertLessThan(stops,300,"Brief rests must not dominate exploration")
    }
    func terrain(_ text:String,x:Double=90,y:Double=90,id:String="a",order:Int=0)->CrawlerTerrain {
        .init(id:id,group:"paragraph",order:order,kind:.text,rect:.init(x:x,y:y,width:40,height:16),text:text)
    }
    func sample(_ terrain:[CrawlerTerrain],center:DocumentPosition = .init(x:100,y:100),revision:Int=0)->CrawlerObservation {
        .init(revision:revision,center:center,radius:140,viewport:.init(x:0,y:0,width:800,height:600),documentWidth:800,documentHeight:1200,terrain:terrain)
    }
    func testHuntHasNoTargetPositionBeforeLocalObservation() {
        var agent=ProceduralCrawlerAgent()
        agent.start(position:.init(x:100,y:100),mission:.stringHunt("Apollo 11"))
        for _ in 0..<20 {agent.advance(dt:0.05)}
        agent.perceive(sample([terrain("unrelated text")]))
        XCTAssertNil(agent.state.match)
        agent.perceive(sample([terrain("Apollo 11",x:500,y:500)]))
        XCTAssertNil(agent.state.match,"Reject out-of-radius injected target geometry")
        agent.perceive(sample([terrain("Apollo 11")]))
        XCTAssertEqual(agent.state.behavior,.targetSuspected)
        XCTAssertNotNil(agent.state.match)
    }
    func testExactMatchAcrossInlineFragmentsAndFindNext() {
        let observation=sample([terrain("Apollo ",id:"a",order:0),terrain("11 and Apollo 11",id:"b",order:7)])
        let first=LocalStringMatcher.find("Apollo 11",in:observation,excluding:[])!
        XCTAssertEqual(first.terrainIDs,["a","b"])
        let next=LocalStringMatcher.find("Apollo 11",in:observation,excluding:[first.key])!
        XCTAssertNotEqual(first.key,next.key)
        XCTAssertNil(LocalStringMatcher.find("apollo 11",in:observation,excluding:[]))
    }
    func testGapInPerceivedTextCannotFabricateMatch() {
        let observation=sample([terrain("Apollo ",id:"a",order:0),terrain("11",id:"b",order:4)])
        XCTAssertNil(LocalStringMatcher.find("Apollo 11",in:observation,excluding:[]))
    }
    func testUnicodeHighlightOffsetsUseUTF16() {
        let match=LocalStringMatcher.find("Apollo",in:sample([terrain("🕷 Apollo")]),excluding:[])!
        XCTAssertEqual(match.firstOffset,3);XCTAssertEqual(match.lastOffset,9)
    }
    func testPauseAndStopAreImmediate() {
        var agent=ProceduralCrawlerAgent();agent.start(position:.init(x:100,y:100),mission:.freeCrawl)
        agent.pause();let position=agent.state.position
        for _ in 0..<60 {agent.advance(dt:1.0/60)}
        XCTAssertEqual(agent.state.position,position);agent.resume();XCTAssertEqual(agent.state.behavior,.exploring)
        agent.stop();XCTAssertEqual(agent.state.behavior,.idle);XCTAssertNil(agent.observation)
    }
    func testCoverageVisitsEntireDocumentWithoutRandomLuck() {
        var navigator=CrawlerNavigator();var p=DocumentPosition(x:20,y:20);var visited:[DocumentPosition]=[]
        for _ in 0..<250 {let observation=sample([],center:p);p=navigator.goal(position:p,observation:observation);visited.append(p)}
        XCTAssertGreaterThan(navigator.laps,0)
        for y in stride(from:20.0,through:1180,by:100) {
            for x in stride(from:20.0,through:780,by:100) {XCTAssertTrue(visited.contains {$0.distance(to:.init(x:x,y:y))<140})}
        }
    }
    func testAlternatingGaitKeepsPlantedFeetStable() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        let before=gait.legs.map(\.foot)
        gait.advance(body:.init(x:118,y:100),velocity:.init(x:40,y:0),anchors:[],dt:0.016,reduceMotion:false)
        XCTAssertEqual(gait.legs.filter(\.isStepping).count,4)
        for i in 0..<8 where !gait.legs[i].isStepping {XCTAssertEqual(gait.legs[i].foot,before[i])}
    }
    func testIndependentInstancesDoNotShareMemoryOrMission() {
        var a=ProceduralCrawlerAgent(),b=ProceduralCrawlerAgent()
        a.start(position:.zero,mission:.freeCrawl);b.start(position:.zero,mission:.stringHunt("target"))
        a.perceive(sample([],center:.zero))
        XCTAssertNotEqual(a.state.id,b.state.id);XCTAssertEqual(b.memory.observationCount,0)
    }
    func testReduceMotionStillWalksAndPlantsFeet() {
        var agent=ProceduralCrawlerAgent();agent.start(position:.init(x:100,y:100),mission:.freeCrawl)
        var gait=CrawlerLegController();gait.reset(at:agent.state.position)
        for _ in 0..<100 {
            agent.perceive(sample([],center:agent.state.position))
            agent.advance(dt:0.05,reduceMotion:true)
            gait.advance(body:agent.state.position,velocity:agent.state.velocity,anchors:[],dt:0.05,reduceMotion:true)
        }
        XCTAssertGreaterThan(agent.state.position.distance(to:.init(x:100,y:100)),20)
        XCTAssertEqual(gait.legs.count,8)
        XCTAssertLessThanOrEqual(gait.legs.filter(\.isStepping).count,4)
    }
    func testLayoutRevisionInvalidatesSuspectedTarget() {
        var agent=ProceduralCrawlerAgent();agent.start(position:.init(x:100,y:100),mission:.stringHunt("Apollo"))
        for _ in 0..<20 {agent.advance(dt:0.05)}
        agent.perceive(sample([terrain("Apollo")]))
        XCTAssertNotNil(agent.state.match)
        agent.perceive(sample([],revision:1));XCTAssertNil(agent.state.match)
    }
}
