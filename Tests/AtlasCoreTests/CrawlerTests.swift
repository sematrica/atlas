import XCTest
@testable import AtlasCore

final class CrawlerTests:XCTestCase {
    func testWanderingGlidesWithOccasionalUnhurriedPauses() {
        var agent=ProceduralCrawlerAgent()
        agent.start(position:.init(x:100,y:100),mission:.freeCrawl)
        var peak=0.0,pauses=0,still=0,wasMoving=false,sharpestChange=0.0
        for _ in 0..<1200 {
            agent.perceive(sample([],center:agent.state.position))
            let before=agent.state.velocity
            agent.advance(dt:1.0/60)
            let speed=hypot(agent.state.velocity.x,agent.state.velocity.y)
            peak=max(peak,speed)
            if agent.state.elapsed>1 {
                sharpestChange=max(sharpestChange,hypot(agent.state.velocity.x-before.x,agent.state.velocity.y-before.y))
                if speed<20 {still += 1;if wasMoving {pauses += 1}}
                wasMoving=speed>=20
            }
        }
        XCTAssertGreaterThan(peak,200)
        XCTAssertGreaterThan(pauses,0,"It stops now and then to look around")
        XCTAssertLessThan(pauses,10,"No stop-start bursts: about one pause every few seconds")
        XCTAssertLessThan(still,400,"Pauses must not dominate exploration")
        XCTAssertLessThan(sharpestChange,40,"Speed and direction change gradually from frame to frame")
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
        var navigator=CrawlerNavigator();var p=DocumentPosition(x:20,y:20);var visited:[DocumentPosition]=[p]
        for _ in 0..<300 {let observation=sample([],center:p);p=navigator.goal(position:p,observation:observation);visited.append(p)}
        for y in stride(from:20.0,through:1180,by:100) {
            for x in stride(from:20.0,through:780,by:100) {XCTAssertTrue(visited.contains {$0.distance(to:.init(x:x,y:y))<160},"(\(x), \(y)) was never approached")}
        }
        XCTAssertGreaterThan(navigator.laps+Int(navigator.coverage*10),0)
    }
    func testWanderingIsNotARowByRowSweep() {
        var navigator=CrawlerNavigator(seed:7);var p=DocumentPosition(x:400,y:600);var directions=Set<Int>()
        for _ in 0..<40 {
            let next=navigator.goal(position:p,observation:sample([],center:p))
            directions.insert(Int((atan2(next.y-p.y,next.x-p.x)+Double.pi)/(Double.pi/4)))
            p=next
        }
        XCTAssertGreaterThan(directions.count,4,"Wandering should head in many directions, not only left, right and down")
    }
    func testAlternatingGaitKeepsPlantedFeetStable() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        let before=gait.legs.map(\.foot)
        gait.advance(body:.init(x:118,y:100),velocity:.init(x:40,y:0),anchors:[],dt:0.016,reduceMotion:false)
        XCTAssertGreaterThan(gait.legs.filter(\.isStepping).count,0)
        XCTAssertLessThanOrEqual(gait.legs.filter(\.isStepping).count,4,"One tetrapod group swings at a time")
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
            // The gait starts turned 90° from the direction of travel; while it swings round,
            // a foot at the edge of its reach may take one extra catch-up step instead of snapping.
            XCTAssertLessThanOrEqual(active,frame<15 ? 6 : 4)
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
    func testDashSpeedsNeverSnapAFootAcrossThePage() {
        for speed in [270.0,540,700,850,1100] {
            var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
            for frame in 0..<240 {
                let old=gait.legs.map(\.foot)
                let t=Double(frame)/60
                let turning=frame>=120
                let body=turning ? DocumentPosition(x:100+2*speed,y:100+(t-2)*speed) : DocumentPosition(x:100+t*speed,y:100)
                gait.advance(body:body,velocity:turning ? .init(x:0,y:speed) : .init(x:speed,y:0),anchors:[],dt:1.0/60,reduceMotion:false)
                for i in 0..<8 {XCTAssertLessThan(gait.legs[i].foot.distance(to:old[i]),45,"speed \(speed): foot \(i) jumped")}
                for i in 0..<8 {XCTAssertLessThan(gait.knee(i,body:body).distance(to:body),CrawlerLegController.maximumReach)}
            }
        }
    }
    func testWalkingStepsAreLongAndUnhurried() {
        XCTAssertGreaterThanOrEqual(CrawlerLegController.swingDuration(speed:200,reduceMotion:false),0.19,"A wandering step takes about a fifth of a second")
        XCTAssertLessThanOrEqual(CrawlerLegController.swingDuration(speed:600,reduceMotion:false),0.1,"Hurrying shortens the swing")
        var gait=CrawlerLegController();gait.reset(at:.init(x:100,y:100))
        var launches=0,wasStepping=Array(repeating:false,count:8)
        for frame in 0..<180 {
            gait.advance(body:.init(x:100+Double(frame)*200/60,y:100),velocity:.init(x:200,y:0),anchors:[],dt:1.0/60,reduceMotion:false)
            for i in 0..<8 {if gait.legs[i].isStepping && !wasStepping[i] {launches += 1};wasStepping[i]=gait.legs[i].isStepping}
        }
        // 600 pt in 3 s: long strides need only a few steps per leg.
        XCTAssertLessThan(launches,8*9,"Strides should be long, not a flurry of short steps")
    }
    func testKneesBendOutwardWithFixedSegments() {
        var gait=CrawlerLegController();gait.reset(at:.init(x:200,y:200))
        let body=DocumentPosition(x:200,y:200)
        for i in 0..<8 {
            let attachment=gait.attachment(i,body:body),knee=gait.knee(i,body:body),foot=gait.drawnFoot(i,body:body)
            XCTAssertEqual(attachment.distance(to:knee),CrawlerLegController.segment,accuracy:0.5)
            XCTAssertEqual(knee.distance(to:foot),CrawlerLegController.segment,accuracy:0.5)
            XCTAssertGreaterThan(knee.distance(to:body),attachment.distance(to:body),"The knee sits outside the body")
        }
        // Heading is +y at rest: on each side the knees run front to back, so the legs fan out without crossing.
        for side in [0,4] {
            let forward=(side..<side+4).map {gait.knee($0,body:body).y}
            XCTAssertEqual(forward,forward.sorted(by:>),"Knees on one side must not cross")
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
        XCTAssertLessThan(gait.legs.map {$0.foot.distance(to:stopped)}.max() ?? 0,85,"Feet settle back near their resting stance (~66–77 pt out)")
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
