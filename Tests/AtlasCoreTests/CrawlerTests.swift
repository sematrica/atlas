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
        XCTAssertGreaterThan(peak,200)
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
    func testApproachCentersTheEntireObservedPhrase() {
        let observation=sample([terrain("Apollo ",x:20,id:"a",order:0),terrain("11",x:180,id:"b",order:7)],center:.init(x:120,y:100))
        let match=LocalStringMatcher.find("Apollo 11",in:observation,excluding:[])!
        XCTAssertEqual(match.position.x,120)
        XCTAssertTrue(match.rects.allSatisfy {$0.center.distance(to:match.position)<observation.radius})
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
        XCTAssertGreaterThan(gait.legs.filter(\.isStepping).count,0)
        XCTAssertLessThanOrEqual(gait.legs.filter(\.isStepping).count,2)
        for i in 0..<8 where !gait.legs[i].isStepping {XCTAssertEqual(gait.legs[i].foot,before[i])}
    }
    func testFastGaitOverlapsDiagonalStepsWithoutSlidingSupportFeet() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        var sawOverlappingPairs=false
        for frame in 0..<50 {
            let oldFeet=gait.legs.map(\.foot),oldStepping=gait.legs.map(\.isStepping)
            let body=DocumentPosition(x:118+Double(frame)*4,y:100)
            gait.advance(body:body,velocity:.init(x:240,y:0),anchors:[],dt:1.0/60,reduceMotion:false)
            let active=gait.legs.filter(\.isStepping).count
            XCTAssertLessThanOrEqual(active,4)
            if active==4 {sawOverlappingPairs=true}
            for i in 0..<8 {
                if !oldStepping[i] && !gait.legs[i].isStepping {
                    XCTAssertEqual(gait.legs[i].foot,oldFeet[i],"A planted foot must not slide")
                }
                XCTAssertLessThan(gait.legs[i].foot.distance(to:oldFeet[i]),35,"A foot should swing smoothly between frames")
            }
        }
        XCTAssertTrue(sawOverlappingPairs)
    }
    func testFastTourGaitDoesNotLeaveFeetFarBehind() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        for frame in 0..<90 {
            let body=DocumentPosition(x:100+Double(frame)*850/60,y:100)
            gait.advance(body:body,velocity:.init(x:850,y:0),anchors:[],dt:1.0/60,reduceMotion:false)
            XCTAssertLessThanOrEqual(gait.legs.filter(\.isStepping).count,6)
            XCTAssertLessThanOrEqual(gait.legs.map {$0.foot.distance(to:body)}.max() ?? 0,CrawlerLegController.maximumReach)
        }
    }
    func testTourSpeedGaitStaysWithinReachThroughAChangeOfDirection() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        let step=420.0/60
        for frame in 0..<150 {
            let previousFeet=gait.legs.map(\.foot)
            let body:DocumentPosition
            let velocity:DocumentPosition
            if frame<75 {
                body = .init(x:100+Double(frame)*step,y:100)
                velocity = .init(x:420,y:0)
            } else {
                body = .init(x:100+74*step,y:100+Double(frame-74)*step)
                velocity = .init(x:0,y:420)
            }
            gait.advance(body:body,velocity:velocity,anchors:[],dt:1.0/60,reduceMotion:false)
            XCTAssertLessThanOrEqual(gait.legs.map {$0.foot.distance(to:body)}.max() ?? 0,CrawlerLegController.maximumReach)
            XCTAssertLessThanOrEqual(gait.legs.filter(\.isStepping).count,6)
            for i in gait.legs.indices {
                XCTAssertLessThan(gait.legs[i].foot.distance(to:previousFeet[i]),42,"A normal tour must not need a visual foot reset")
            }
        }
    }
    func testGaitRecoversFromAJumpWithoutPageSpanningLegs() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        let body=DocumentPosition(x:1_000,y:1_000)
        gait.advance(body:body,velocity:.init(x:420,y:0),anchors:[],dt:1.0/60,reduceMotion:false)
        XCTAssertTrue(gait.legs.allSatisfy {$0.foot.distance(to:body)<=CrawlerLegController.maximumReach})
    }
    func testGaitFoldsBackAroundBodyWhenTourStops() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        let step=420.0/60
        for frame in 0..<60 {
            gait.advance(body:.init(x:100+Double(frame)*step,y:100),velocity:.init(x:420,y:0),anchors:[],dt:1.0/60,reduceMotion:false)
        }
        let stopped=DocumentPosition(x:100+59*step,y:100)
        for _ in 0..<60 {
            gait.advance(body:stopped,velocity:.zero,anchors:[],dt:1.0/60,reduceMotion:false)
        }
        XCTAssertTrue(gait.legs.allSatisfy {!$0.isStepping})
        XCTAssertLessThan(gait.legs.map {$0.foot.distance(to:stopped)}.max() ?? 0,70)
    }
    func testRestrictedGaitLandsOnlyOnPermittedAnchors() {
        let anchors=(0...4).map {TerrainAnchor(id:String($0),position:.init(x:Double($0)*40,y:100),kind:.text)}
        let allowed=anchors.map(\.position)
        var gait=CrawlerLegController();gait.reset(at:allowed[0])
        XCTAssertTrue(gait.plant(body:allowed[0],anchors:anchors))
        for frame in 0..<30 {
            gait.advance(body:.init(x:80,y:100),velocity:.init(x:50,y:0),anchors:anchors,dt:1.0/60,reduceMotion:false,strict:true)
            XCTAssertLessThanOrEqual(gait.legs.filter(\.isStepping).count,4)
            for leg in gait.legs {
                XCTAssertTrue(allowed.contains(leg.to))
                if !leg.isStepping {XCTAssertTrue(allowed.contains(leg.foot))}
            }
            if frame==0 {XCTAssertLessThanOrEqual(gait.legs.filter(\.isStepping).count,2)}
        }
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
