import Foundation

public struct CrawlerLeg: Sendable {
    public var foot:DocumentPosition
    public var from:DocumentPosition
    public var to:DocumentPosition
    public var phase:Double=1
    public var duration:Double=0.14
    public var anchorID:String?
    public var isStepping:Bool { phase<1 }
}
public struct CrawlerLegController: Sendable {
    public private(set) var legs:[CrawlerLeg]=[]
    public private(set) var heading:Double = .pi/2
    /// The rendered body is only a few points wide. Beyond this reach a planted
    /// foot reads as a line across the page rather than as part of the crawler.
    public static let maximumReach=105.0
    private static let diagonalPairs:[[Int]]=[[0,6],[4,2],[1,7],[5,3]]
    private var pairCursor=0
    private var cooldown=0.0
    public init() {}
    public mutating func reset(at position:DocumentPosition) {
        heading = .pi/2;pairCursor=0;cooldown=0
        legs=(0..<8).map { i in let foot=nominal(i,body:position);return CrawlerLeg(foot:foot,from:foot,to:foot) }
    }
    public mutating func plant(body:DocumentPosition,anchors:[TerrainAnchor])->Bool {
        let nearby=anchors.filter {$0.position.distance(to:body)<=65}
        guard !nearby.isEmpty else {return false}
        if legs.count != 8 {reset(at:body)}
        for i in legs.indices {
            let anchor=nearby.min {$0.position.distance(to:nominal(i,body:body))<$1.position.distance(to:nominal(i,body:body))}!
            legs[i]=CrawlerLeg(foot:anchor.position,from:anchor.position,to:anchor.position,anchorID:anchor.id)
        }
        pairCursor=0;cooldown=0
        return true
    }
    public func attachment(_ i:Int,body:DocumentPosition)->DocumentPosition {
        let side=i<4 ? -1.0 : 1.0, row=Double(i%4)
        return rotated(x:(row-1.5)*4,y:side*4,body:body)
    }
    public func knee(_ i:Int,body:DocumentPosition)->DocumentPosition {
        guard legs.indices.contains(i) else {return body}
        let a=attachment(i,body:body),b=legs[i].foot
        let side=i<4 ? -1.0 : 1.0
        let mid=DocumentPosition(x:(a.x+b.x)/2,y:(a.y+b.y)/2)
        return mid.moved(-sin(heading)*side*15,cos(heading)*side*15)
    }
    private func rotated(x:Double,y:Double,body:DocumentPosition)->DocumentPosition {
        body.moved(cos(heading)*x-sin(heading)*y,sin(heading)*x+cos(heading)*y)
    }
    private func nominal(_ i:Int,body:DocumentPosition)->DocumentPosition {
        let side=i<4 ? -1.0 : 1.0,row=Double(i%4)
        return rotated(x:(row-1.5)*27,y:side*(48-abs(row-1.5)*5),body:body)
    }
    public mutating func advance(body:DocumentPosition,velocity:DocumentPosition,anchors:[TerrainAnchor],dt:Double,reduceMotion:Bool,strict:Bool=false) {
        if legs.count != 8 {reset(at:body)}
        let elapsed=max(0,dt),speed=hypot(velocity.x,velocity.y)
        if speed>2 {
            let target=atan2(velocity.y,velocity.x),delta=atan2(sin(target-heading),cos(target-heading))
            heading += delta*(1-exp(-elapsed*(reduceMotion ? 7 : 12)))
        }
        cooldown=max(0,cooldown-elapsed)
        for i in legs.indices where legs[i].isStepping {
            legs[i].phase=min(1,legs[i].phase+elapsed/legs[i].duration)
            let t=legs[i].phase
            if t>=1 {legs[i].foot=legs[i].to;continue}
            let smooth=t*t*t*(t*(t*6-15)+10)
            let lift=reduceMotion ? 0 : sin(.pi*smooth)*4
            let side=i<4 ? -1.0 : 1.0
            legs[i].foot = .init(x:legs[i].from.x+(legs[i].to.x-legs[i].from.x)*smooth-sin(heading)*side*lift,
                                 y:legs[i].from.y+(legs[i].to.y-legs[i].from.y)*smooth+cos(heading)*side*lift)
        }
        if !strict {
            // A tour may resume after a long frame or a page-layout shift. Keep
            // every limb attached to its chassis instead of drawing a stale foot
            // hundreds of points away. In normal travel the quicker gait below
            // reaches its next foothold before this recovery is needed.
            for i in legs.indices where legs[i].foot.distance(to:body)>Self.maximumReach {
                let foot=nominal(i,body:body)
                legs[i]=CrawlerLeg(foot:foot,from:foot,to:foot)
            }
        }
        let active=legs.filter(\.isStepping).count
        let freeSlots=(reduceMotion ? 2 : speed>=320 ? 6 : 4)-active
        guard cooldown<=0,freeSlots>0 else {return}
        let reachThreshold=max(12,min(24,speed*0.06))
        let pairOrder=(0..<Self.diagonalPairs.count).map {(pairCursor+$0)%Self.diagonalPairs.count}
        let rankedPairs=strict ? pairOrder : pairOrder.sorted { pairUrgency($0,body:body)>pairUrgency($1,body:body) }
        for pairIndex in rankedPairs {
            var launched=0
            let pair=strict ? Self.diagonalPairs[pairIndex] : Self.diagonalPairs[pairIndex].sorted {
                legUrgency($0,body:body)>legUrgency($1,body:body)
            }
            for i in pair where launched<freeSlots && !legs[i].isStepping {
                let ideal=nominal(i,body:body)
                if strict {
                    guard legs[i].foot.distance(to:body)>62 else {continue}
                    let currentDistance=legs[i].foot.distance(to:body)
                    let anchor=anchors.filter {
                        $0.position.distance(to:body)<65 &&
                        $0.position.distance(to:legs[i].foot)>1 &&
                        ($0.position.distance(to:body)+1<currentDistance ||
                         $0.position.distance(to:ideal)+1<legs[i].foot.distance(to:ideal))
                    }.min {$0.position.distance(to:ideal)<$1.position.distance(to:ideal)}
                    guard let anchor else {continue}
                    beginStep(i,to:anchor.position,anchorID:anchor.id,speed:speed,reduceMotion:reduceMotion)
                } else {
                    let lead=min(12,speed*0.025)/max(1,speed)
                    let target=ideal.moved(velocity.x*lead,velocity.y*lead)
                    guard legs[i].foot.distance(to:target)>reachThreshold || legs[i].foot.distance(to:body)>72 else {continue}
                    let used=Set(legs.enumerated().filter {$0.offset != i}.compactMap {$0.element.anchorID})
                    let anchor=anchors.filter {
                        !used.contains($0.id) && $0.position.distance(to:body)<70 &&
                        $0.position.distance(to:body)>28 && $0.position.distance(to:target)<20 &&
                        $0.position.distance(to:legs[i].foot)>1
                    }.min {$0.position.distance(to:target)<$1.position.distance(to:target)}
                    beginStep(i,to:anchor?.position ?? target,anchorID:anchor?.id,speed:speed,reduceMotion:reduceMotion)
                }
                launched += 1
            }
            if launched>0 {
                pairCursor=(pairIndex+1)%Self.diagonalPairs.count
                cooldown=reduceMotion ? 0.085 : max(0.012,0.030-speed*0.00004)
                return
            }
        }
    }
    private func legUrgency(_ i:Int,body:DocumentPosition)->Double {
        guard !legs[i].isStepping else {return -.infinity}
        return max(legs[i].foot.distance(to:body),legs[i].foot.distance(to:nominal(i,body:body)))
    }
    private func pairUrgency(_ pairIndex:Int,body:DocumentPosition)->Double {
        Self.diagonalPairs[pairIndex].map {legUrgency($0,body:body)}.max() ?? -.infinity
    }
    private mutating func beginStep(_ i:Int,to position:DocumentPosition,anchorID:String?,speed:Double,reduceMotion:Bool) {
        let from=legs[i].foot
        var destination=position
        if anchorID == nil {
            let distance=from.distance(to:position)
            let stride=max(60,min(105,speed*0.22))
            if distance>stride {
                let fraction=stride/distance
                destination = .init(x:from.x+(position.x-from.x)*fraction,
                                    y:from.y+(position.y-from.y)*fraction)
            }
        }
        let travel=from.distance(to:destination)
        legs[i].from=from
        legs[i].to=destination
        legs[i].phase=0
        let baseDuration=reduceMotion ? 0.19 : max(0.055,0.12-speed*0.00012)
        legs[i].duration=max(baseDuration,travel/max(1_000,speed*3.5))
        legs[i].anchorID=anchorID
    }
}
