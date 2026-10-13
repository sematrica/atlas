import Foundation

public struct CrawlerMemory: Sendable {
    public private(set) var recentPositions:[DocumentPosition]=[]
    public private(set) var visited:Set<String>=[]
    public private(set) var discoveries:Set<String>=[]
    public private(set) var observationCount=0
    public mutating func record(_ observation:CrawlerObservation) {
        observationCount += 1
        recentPositions.append(observation.center)
        if recentPositions.count > 160 { recentPositions.removeFirst() }
        for item in observation.terrain { visited.insert(item.group) }
        if visited.count > 4096 { visited=Set(observation.terrain.map(\.group)) }
    }
    public mutating func found(_ key:String) { discoveries.insert(key) }
}

public enum LocalStringMatcher {
    /// Only contiguous locally returned fragments are eligible. Gaps in DOM order break a candidate.
    public static func find(_ target:String,in observation:CrawlerObservation,excluding:Set<String>) -> CrawlerMatch? {
        guard !target.isEmpty else { return nil }
        let groups=Dictionary(grouping:observation.terrain.filter {!$0.text.isEmpty},by:\.group)
        for group in groups.keys.sorted() {
            let items=groups[group]!.sorted {$0.order < $1.order}
            var run:[CrawlerTerrain]=[]
            func matches(_ run:[CrawlerTerrain])->CrawlerMatch? {
                let joined=run.map(\.text).joined()
                var search=joined.startIndex..<joined.endIndex
                while let range=joined.range(of:target,options:[],range:search) {
                    let ns=NSRange(range,in:joined),start=ns.location,end=ns.location+ns.length
                    var cursor=0,firstOffset=0,lastOffset=0; var used:[CrawlerTerrain]=[]
                    for item in run {
                        let next=cursor+item.text.utf16.count
                        if next > start && cursor < end {
                            if used.isEmpty {firstOffset=max(0,start-cursor)}
                            used.append(item);lastOffset=min(item.text.utf16.count,end-cursor)
                        }
                        cursor=next
                    }
                    let key=(used.first?.id ?? "")+":"+String(firstOffset)
                    if !excluding.contains(key), !used.isEmpty {
                        return CrawlerMatch(key:key,terrainIDs:used.map(\.id),rects:used.map(\.rect),text:target,firstOffset:firstOffset,lastOffset:lastOffset)
                    }
                    search=range.upperBound..<joined.endIndex
                }
                return nil
            }
            for item in items {
                if let last=run.last,item.order != last.order+last.text.utf16.count {
                    if let match=matches(run) { return match }; run=[]
                }
                run.append(item)
            }
            if let match=matches(run) { return match }
        }
        return nil
    }
}

/// A serpentine frontier provides eventual geometric coverage. Curiosity is bounded around that frontier.
public struct CrawlerNavigator: Sendable {
    public private(set) var frontier=DocumentPosition.zero
    public private(set) var laps=0
    private var right=true
    private var initialized=false
    private var seed:UInt64
    public init(seed:UInt64=42) { self.seed=seed }
    public mutating func random()->Double {
        seed=seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11)/Double(UInt64.max >> 11)
    }
    public mutating func reset() { initialized=false; laps=0;right=true }
    public mutating func goal(position:DocumentPosition,observation:CrawlerObservation)->DocumentPosition {
        let margin=20.0, width=max(40,observation.documentWidth),height=max(40,observation.documentHeight)
        let stride=max(35,min(130,observation.radius*0.85))
        if !initialized {
            frontier = .init(x:margin,y:margin); initialized=true
        }
        frontier.x=min(max(margin,frontier.x),width-margin)
        frontier.y=min(max(margin,frontier.y),height-margin)
        if position.distance(to:frontier)<16 {
            let nextX=frontier.x+(right ? stride : -stride)
            if nextX > width-margin || nextX < margin {
                if abs(frontier.x-(right ? width-margin : margin)) > 2 {
                    frontier.x=right ? width-margin : margin
                } else {
                    frontier.y += stride; right.toggle()
                    if frontier.y > height-margin { frontier = .init(x:margin,y:margin);right=true;laps += 1 }
                }
            } else { frontier.x=nextX }
        }
        return frontier
    }
}

/// Independent creature instance. Pure simulation is deterministic and testable without WebKit.
public struct ProceduralCrawlerAgent: Sendable {
    public private(set) var state:CrawlerState
    public private(set) var memory=CrawlerMemory()
    public private(set) var observation:CrawlerObservation?
    public private(set) var navigator:CrawlerNavigator
    private var decisionIn=0.0
    private var dwell=0.0
    private var burstRemaining=0.65
    private var lastRevision:Int?
    private var lastFrontier=DocumentPosition.zero
    private var detour:DocumentPosition?
    public private(set) var guidedGoal:DocumentPosition?
    private var suppressMission=false
    public init(id:UUID=UUID(),seed:UInt64=42) { state=CrawlerState(id:id);navigator=CrawlerNavigator(seed:seed) }
    public mutating func start(position:DocumentPosition,mission:CrawlerMission) {
        state=CrawlerState(id:state.id,position:position,mission:mission);state.behavior = .spawning
        state.desired=position; memory=CrawlerMemory(); navigator.reset(); observation=nil;dwell=0.65;decisionIn=0;lastRevision=nil;detour=nil;lastFrontier=position;burstRemaining=0.65;guidedGoal=nil;suppressMission=false
    }
    public mutating func suppressHunt(_ suppressed:Bool) {
        suppressMission=suppressed
        if suppressed {state.match=nil;if ![.idle,.paused].contains(state.behavior) {state.behavior = .exploring;dwell=0}}
    }
    public mutating func guide(to position:DocumentPosition) {
        guidedGoal=position;suppressHunt(true);state.desired=position;state.behavior = .walking
    }
    public mutating func endGuidance() {guidedGoal=nil;detour=nil;decisionIn=0}
    public mutating func steer(to position:DocumentPosition) {
        detour=position;lastFrontier=navigator.frontier;state.desired=position;state.behavior = .walking;decisionIn=0.45
    }
    public mutating func inspect(for seconds:Double) {state.behavior = .inspecting;dwell=seconds}
    public mutating func confirmDiscovery(_ quote:String)->Bool {
        guard let observation,let match=LocalStringMatcher.find(quote,in:observation,excluding:memory.discoveries) else {return false}
        state.match=match;state.behavior = .targetSuspected;dwell=0.3;return true
    }
    public mutating func pause() { guard state.behavior != .idle else {return};state.behavior = .paused;state.velocity = .zero }
    public mutating func resume() { guard state.behavior == .paused else {return};state.behavior = .exploring;decisionIn=0 }
    public mutating func stop() { state.behavior = .idle;state.velocity = .zero;state.match=nil;observation=nil }
    public mutating func findNext() {
        if let match=state.match { memory.found(match.key) }
        state.match=nil;state.behavior = .exploring;decisionIn=0
    }
    public mutating func resumeFreeCrawl() { state.mission = .freeCrawl;findNext() }
    public mutating func perceive(_ sample:CrawlerObservation) {
        guard state.behavior != .idle else {return}
        // Defense in depth: reject stale samples and any fragment outside the requested local disk.
        guard sample.center.distance(to:state.position) < sample.radius*0.65 else {return}
        let local=sample.terrain.filter { item in
            let r=item.rect
            return [DocumentPosition(x:r.x,y:r.y),.init(x:r.x+r.width,y:r.y),.init(x:r.x,y:r.y+r.height),.init(x:r.x+r.width,y:r.y+r.height)].allSatisfy {$0.distance(to:sample.center) <= sample.radius+1}
        }
        observation=CrawlerObservation(document:sample.document,revision:sample.revision,center:sample.center,radius:sample.radius,viewport:sample.viewport,documentWidth:sample.documentWidth,documentHeight:sample.documentHeight,terrain:local,truncated:sample.truncated)
        if let previous=lastRevision,previous != sample.revision {
            state.match=nil; if state.behavior != .paused {state.behavior = .recovering};navigator.reset();decisionIn=0
            state.position.x=min(state.position.x,max(20,sample.documentWidth-20))
            state.position.y=min(state.position.y,max(20,sample.documentHeight-20))
        }
        lastRevision=sample.revision
        memory.record(observation!)
        guard ![.found,.paused,.spawning].contains(state.behavior) else {return}
        if !suppressMission,case .stringHunt(let target)=state.mission,
           let match=LocalStringMatcher.find(target,in:observation!,excluding:memory.discoveries) {
            if state.match?.key != match.key { state.match=match;state.behavior = .targetSuspected;dwell=0.3 }
        }
    }
    public mutating func advance(dt raw:Double,speed:Double=270,reduceMotion:Bool=false) {
        let dt=min(max(raw,0),0.05)
        guard ![.idle,.paused,.found].contains(state.behavior) else {return}
        state.elapsed += dt;decisionIn -= dt;dwell -= dt
        if state.behavior == .spawning {
            if dwell<=0 { state.behavior = .exploring };return
        }
        guard let observation else { state.velocity = .zero;return }
        if state.behavior == .targetSuspected {
            settle(dt:dt)
            if dwell<=0 { state.behavior = .approachingTarget };return
        }
        if state.behavior == .inspecting && dwell>0 {settle(dt:dt);return}
        // Bounded bursts give the insect a quick scan-and-scuttle rhythm without changing coverage.
        if !reduceMotion,state.match == nil,guidedGoal == nil {
            burstRemaining -= dt
            if burstRemaining<=0 {
                burstRemaining=0.4+navigator.random()*0.5
                state.behavior = .inspecting;dwell=0.10+navigator.random()*0.13
                settle(dt:dt);return
            }
        }
        if let goal=guidedGoal {
            state.desired=goal
            if state.position.distance(to:goal)<8 && hypot(state.velocity.x,state.velocity.y)<55 {
                guidedGoal=nil;state.behavior = .paused;state.velocity = .zero;return
            }
        } else if let match=state.match {
            state.desired=match.position
            if state.position.distance(to:match.position)<12 {
                // Re-confirm using a current local observation, not a previously known global coordinate.
                if LocalStringMatcher.find(match.text,in:observation,excluding:memory.discoveries)?.key == match.key {
                    state.behavior = .found;state.velocity = .zero;return
                }
                state.match=nil;state.behavior = .exploring
            }
        } else if decisionIn<=0 {
            let frontier=navigator.goal(position:state.position,observation:observation)
            if detour?.distance(to:state.position) ?? 0 < 16 {detour=nil}
            if frontier != lastFrontier {
                lastFrontier=frontier
                if case .freeCrawl=state.mission,navigator.random()<0.35,
                   let interesting=observation.terrain.filter({$0.kind == .heading || $0.kind == .link}).min(by:{$0.rect.center.distance(to:frontier)<$1.rect.center.distance(to:frontier)}) {
                    detour=interesting.rect.center
                }
            }
            state.desired=detour ?? frontier
            decisionIn=0.10
            if case .freeCrawl=state.mission, navigator.random()<0.04 {
                state.behavior = .inspecting;dwell=0.16+navigator.random()*0.16
            } else { state.behavior = (state.desired.x-state.position.x)*state.velocity.x+(state.desired.y-state.position.y)*state.velocity.y < 0 ? .turning : .walking }
        }
        if state.behavior == .inspecting && dwell>0 {settle(dt:dt);return}
        let distance=state.position.distance(to:state.desired)
        guard distance>0.5 else {settle(dt:dt);return}
        // Don't outrun the last perception disk; waiting allows the slower senses loop to catch up.
        let perceptionRoom=max(0,observation.radius*0.5-state.position.distance(to:observation.center))
        if perceptionRoom<=0 {state.velocity = .zero;return}
        let organic=reduceMotion ? 1 : 0.93+0.07*sin(state.elapsed*9)
        let magnitude=min(max(0,reduceMotion ? min(speed,84) : speed)*organic,
                          distance*(reduceMotion ? 5 : 10),perceptionRoom*18)
        let vx=(state.desired.x-state.position.x)/distance*magnitude,vy=(state.desired.y-state.position.y)/distance*magnitude
        let previousSpeed=hypot(state.velocity.x,state.velocity.y)
        let alignment=(state.velocity.x*vx+state.velocity.y*vy)/max(1,previousSpeed*magnitude)
        let turning=previousSpeed>15 && alignment<0.7
        let response=reduceMotion ? 7.0 : (turning ? 12.0 : 20.0)
        let smooth=1-exp(-dt*response)
        state.velocity.x += (vx-state.velocity.x)*smooth;state.velocity.y += (vy-state.velocity.y)*smooth
        state.position=state.position.moved(state.velocity.x*dt,state.velocity.y*dt)
        let minX=min(20,observation.documentWidth/2),minY=min(20,observation.documentHeight/2)
        let clampedX=min(max(minX,state.position.x),observation.documentWidth-minX)
        let clampedY=min(max(minY,state.position.y),observation.documentHeight-minY)
        if clampedX != state.position.x {state.velocity.x=0;state.position.x=clampedX}
        if clampedY != state.position.y {state.velocity.y=0;state.position.y=clampedY}
    }

    private mutating func settle(dt:Double) {
        let decay=exp(-dt*28)
        state.velocity.x *= decay;state.velocity.y *= decay
        if hypot(state.velocity.x,state.velocity.y)<2 {state.velocity = .zero}
        state.position=state.position.moved(state.velocity.x*dt,state.velocity.y*dt)
    }
}
