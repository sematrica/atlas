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

/// Curious, coverage-aware wandering. The page is divided into cells; the next
/// goal favours unvisited cells, nearby headings, links and images, and the
/// current direction of travel, so the creature roams naturally instead of
/// sweeping rows, yet still reaches every part of the page eventually.
public struct CrawlerNavigator: Sendable {
    /// The current wandering goal.
    public private(set) var frontier=DocumentPosition.zero
    /// How many times the whole page has been covered.
    public private(set) var laps=0
    private var visits:[Int:Int]=[:]
    private var columns=0,rows=0,cell=140.0
    private var width=0.0,height=0.0
    private var direction=0.0
    private var initialized=false
    private var seed:UInt64
    public init(seed:UInt64=42) { self.seed=seed }
    /// Share of page cells visited in this lap.
    public var coverage:Double {columns*rows == 0 ? 0 : Double(visits.count)/Double(columns*rows)}
    public mutating func random()->Double {
        seed=seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11)/Double(UInt64.max >> 11)
    }
    public mutating func reset() {initialized=false;laps=0;visits=[:]}

    private mutating func configure(_ observation:CrawlerObservation) {
        let w=max(40,observation.documentWidth),h=max(40,observation.documentHeight)
        guard !initialized || abs(w-width)>1 || abs(h-height)>1 else {return}
        width=w;height=h
        // Keep the grid small for very long articles.
        cell=max(140,sqrt(w*h/3000))
        columns=max(1,Int(ceil(w/cell)));rows=max(1,Int(ceil(h/cell)))
        if !initialized {visits=[:];direction = .pi/2}
        else {visits=visits.filter {$0.key<columns*rows}}
        initialized=true
    }
    private func index(_ p:DocumentPosition)->Int {
        let c=min(columns-1,max(0,Int(p.x/cell))),r=min(rows-1,max(0,Int(p.y/cell)))
        return r*columns+c
    }
    private func center(_ index:Int)->DocumentPosition {
        .init(x:min(width-20,(Double(index%columns)+0.5)*cell),y:min(height-20,(Double(index/columns)+0.5)*cell))
    }
    private func clamp(_ p:DocumentPosition)->DocumentPosition {
        let margin=20.0
        return .init(x:min(max(margin,p.x),max(margin,width-margin)),y:min(max(margin,p.y),max(margin,height-margin)))
    }
    /// Marks the cells around a position as seen.
    public mutating func record(_ position:DocumentPosition,radius:Double) {
        guard initialized else {return}
        let reach=max(0,Int(radius/cell))
        let c=min(columns-1,max(0,Int(position.x/cell))),r=min(rows-1,max(0,Int(position.y/cell)))
        for row in max(0,r-reach)...min(rows-1,r+reach) {
            for column in max(0,c-reach)...min(columns-1,c+reach) {
                let i=row*columns+column
                if center(i).distance(to:position)<=radius+cell*0.5 {visits[i,default:0] += 1}
            }
        }
        if visits.count>=columns*rows {visits=[:];laps += 1}
    }

    public mutating func goal(position:DocumentPosition,observation:CrawlerObservation)->DocumentPosition {
        configure(observation)
        record(position,radius:min(observation.radius,cell*0.75))
        let current=index(frontier)
        let keep=frontier != .zero && position.distance(to:frontier)>24 && visits[current] == nil
        if keep {return frontier}

        var candidates:[(point:DocumentPosition,interest:Double)]=[]
        // Points scattered around the creature, biased forward.
        for _ in 0..<10 {
            let angle=direction+(random()-0.5)*2.6
            let distance=120+random()*260
            candidates.append((clamp(.init(x:position.x+cos(angle)*distance,y:position.y+sin(angle)*distance)),0))
        }
        // The nearest unvisited cells, so coverage never depends on luck.
        let here=index(position),hc=here%columns,hr=here/columns
        var unvisited:[Int]=[]
        var ring=1
        while unvisited.count<6 && ring<=max(columns,rows) {
            for row in max(0,hr-ring)...min(rows-1,hr+ring) {
                for column in max(0,hc-ring)...min(columns-1,hc+ring) where max(abs(row-hr),abs(column-hc)) == ring {
                    let i=row*columns+column
                    if visits[i] == nil {unvisited.append(i)}
                }
            }
            ring += 1
        }
        for i in unvisited.prefix(6) {candidates.append((center(i),0.15))}
        // Landmarks the creature can actually see.
        for item in observation.terrain where [.heading,.link,.image].contains(item.kind) {
            let weight=item.kind == .heading ? 0.5 : item.kind == .image ? 0.35 : 0.25
            candidates.append((clamp(item.rect.center),weight))
        }
        var best:DocumentPosition?,bestScore = -Double.infinity
        for candidate in candidates {
            let distance=candidate.point.distance(to:position)
            guard distance>30 else {continue}
            let seen=visits[index(candidate.point)] ?? 0
            let novelty=seen == 0 ? 1.0 : seen == 1 ? 0.35 : 0.1
            let angle=atan2(candidate.point.y-position.y,candidate.point.x-position.x)
            let persistence=0.3*cos(atan2(sin(angle-direction),cos(angle-direction)))
            let score=novelty+candidate.interest+persistence-distance/900+random()*0.15
            if score>bestScore {bestScore=score;best=candidate.point}
        }
        let chosen=best ?? clamp(.init(x:position.x+cos(direction)*150,y:position.y+sin(direction)*150))
        direction=atan2(chosen.y-position.y,chosen.x-position.x)
        frontier=chosen
        return chosen
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
    private var detour:DocumentPosition?
    public private(set) var guidedGoal:DocumentPosition?
    private var suppressMission=false
    public init(id:UUID=UUID(),seed:UInt64=42) { state=CrawlerState(id:id);navigator=CrawlerNavigator(seed:seed) }
    /// - Parameter seed: a new seed gives each spawn its own wandering; omit it for repeatable tests.
    public mutating func start(position:DocumentPosition,mission:CrawlerMission,seed:UInt64?=nil) {
        state=CrawlerState(id:state.id,position:position,mission:mission);state.behavior = .spawning
        if let seed {navigator=CrawlerNavigator(seed:seed)} else {navigator.reset()}
        state.desired=position; memory=CrawlerMemory(); observation=nil;dwell=0.65;decisionIn=0;lastRevision=nil;detour=nil;burstRemaining=0.65;guidedGoal=nil;suppressMission=false
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
        detour=position;state.desired=position;state.behavior = .walking;decisionIn=0.45
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
            // A reflow moves text but the wandering memory stays; the grid adapts to the new size.
            state.match=nil; if state.behavior != .paused {state.behavior = .recovering};decisionIn=0
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
