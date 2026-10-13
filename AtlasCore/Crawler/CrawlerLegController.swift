import Foundation

public struct CrawlerLeg: Sendable {
    public var foot:DocumentPosition
    public var from:DocumentPosition
    public var to:DocumentPosition
    public var phase:Double=1
    public var duration:Double=0.14
    public var anchorID:String?
    /// Knee raise while scuttling at dash speed, when feet are not planted.
    public var raise=0.0
    public var isStepping:Bool { phase<1 }
    /// 0…1 height of the swing, for drawing the lifted leg.
    public var lift:Double {isStepping ? sin(.pi*phase) : raise}
}

/// Eight legs on an alternating-tetrapod gait: L1 R2 L3 R4 swing together while
/// R1 L2 R3 L4 hold the ground, then they swap, as real spiders walk.
/// Knees come from two-segment inverse kinematics, so legs bend instead of stretching.
public struct CrawlerLegController: Sendable {
    public private(set) var legs:[CrawlerLeg]=[]
    public private(set) var heading:Double = .pi/2
    /// The rendered body is only a few points wide. Beyond this reach a planted
    /// foot reads as a line across the page rather than as part of the crawler.
    public static let maximumReach=105.0
    /// Upper and lower leg lengths. A foot at rest (~48 pt out) leaves the knee clearly bent.
    public static let segment=30.0
    /// Legs 0–3 are left (front to back), 4–7 right.
    static let groups:[[Int]]=[[0,5,2,7],[4,1,6,3]]
    private var nextGroup=0
    private var cooldown=0.0
    private var scuttle=0.0
    /// Above this pace planted steps can't keep up; legs scuttle around the body instead.
    public static let dashSpeed=600.0
    public init() {}

    public mutating func reset(at position:DocumentPosition) {
        heading = .pi/2;nextGroup=0;cooldown=0
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
        nextGroup=0;cooldown=0
        return true
    }
    public func attachment(_ i:Int,body:DocumentPosition)->DocumentPosition {
        let side=i<4 ? -1.0 : 1.0, row=Double(i%4)
        return rotated(x:(1.5-row)*3.6,y:side*4,body:body)
    }
    /// The knee from two-segment inverse kinematics, bent away from the body.
    /// A swinging leg raises its knee a little further.
    public func knee(_ i:Int,body:DocumentPosition)->DocumentPosition {
        guard legs.indices.contains(i) else {return body}
        let a=attachment(i,body:body),f=drawnFoot(i,body:body)
        let dx=f.x-a.x,dy=f.y-a.y,distance=max(0.001,hypot(dx,dy))
        let length=max(Self.segment,distance/2+0.5)
        let rise=sqrt(max(0,length*length-(distance/2)*(distance/2)))*(1+0.35*legs[i].lift)
        let side=i<4 ? -1.0 : 1.0
        // Perpendicular to the leg, on the outside of the body.
        var nx = -dy/distance,ny=dx/distance
        let outwardX = -sin(heading)*side,outwardY=cos(heading)*side
        if nx*outwardX+ny*outwardY<0 {nx = -nx;ny = -ny}
        return .init(x:(a.x+f.x)/2+nx*rise,y:(a.y+f.y)/2+ny*rise)
    }
    /// Where to draw the foot: never farther than the reach, so a leg can't span the page.
    public func drawnFoot(_ i:Int,body:DocumentPosition)->DocumentPosition {
        let foot=legs[i].foot,distance=foot.distance(to:body)
        guard distance>Self.maximumReach else {return foot}
        let scale=Self.maximumReach/distance
        return .init(x:body.x+(foot.x-body.x)*scale,y:body.y+(foot.y-body.y)*scale)
    }
    private func rotated(x:Double,y:Double,body:DocumentPosition)->DocumentPosition {
        body.moved(cos(heading)*x-sin(heading)*y,sin(heading)*x+cos(heading)*y)
    }
    /// Resting foot positions fan forward for the front legs and back for the rear legs.
    private func nominal(_ i:Int,body:DocumentPosition)->DocumentPosition {
        let side=i<4 ? -1.0 : 1.0,row=Double(i%4)
        return rotated(x:(1.5-row)*27,y:side*(48-abs(row-1.5)*5),body:body)
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
        if strict {advanceStrict(body:body,velocity:velocity,anchors:anchors,speed:speed,reduceMotion:reduceMotion);return}
        if speed>Self.dashSpeed && !reduceMotion {
            // Dash: the two groups sweep back and forth along the direction of travel.
            scuttle += elapsed*speed/40
            let ux=cos(heading),uy=sin(heading)
            for i in legs.indices {
                let swing=sin(scuttle+(Self.groups[0].contains(i) ? 0 : Double.pi))
                let base=nominal(i,body:body)
                let foot=DocumentPosition(x:base.x+ux*swing*14,y:base.y+uy*swing*14)
                legs[i]=CrawlerLeg(foot:foot,from:foot,to:foot,duration:legs[i].duration,raise:max(0,swing)*0.8)
            }
            return
        }
        // After a jump (layout shift, resumed tour) a foot can be far away. Bring it
        // back to the body at once rather than drawing a limb across the article.
        for i in legs.indices where legs[i].foot.distance(to:body)>Self.maximumReach {
            let foot=nominal(i,body:body)
            legs[i]=CrawlerLeg(foot:foot,from:foot,to:foot)
        }
        let active=legs.filter(\.isStepping).count
        let capacity=reduceMotion ? 2 : speed>=320 ? 6 : 4
        guard cooldown<=0,active<capacity else {return}
        // Feet land a little ahead so they stay under the body longer.
        let lead=min(22,speed*0.06)/max(1,speed)
        func target(_ i:Int)->DocumentPosition {nominal(i,body:body).moved(velocity.x*lead,velocity.y*lead)}
        let threshold=max(10,min(24,speed*0.06))
        func strain(_ i:Int)->Double {legs[i].isStepping ? 0 : legs[i].foot.distance(to:target(i))}
        func urgent(_ i:Int)->Bool {!legs[i].isStepping && (strain(i)>threshold || legs[i].foot.distance(to:body)>72)}

        // Alternate the two groups. A group lifts together once its partner group is down.
        let order=[nextGroup,1-nextGroup]
        for groupIndex in order {
            let group=Self.groups[groupIndex]
            let other=Self.groups[1-groupIndex]
            let waiting=group.filter(urgent)
            guard !waiting.isEmpty else {continue}
            let partnerDown = !other.contains {legs[$0].isStepping}
            let room=capacity-legs.filter(\.isStepping).count
            if reduceMotion {
                // Two at a time, gently, the group's most strained legs first.
                for i in waiting.sorted(by:{strain($0)>strain($1)}).prefix(min(2,room)) {beginStep(i,to:landing(i,target:target(i),body:body,anchors:anchors),anchors:anchors,speed:speed,reduceMotion:true)}
                cooldown=0.085;nextGroup=1-groupIndex;return
            }
            // A fast body may need the next group before the last one lands; never exceed capacity.
            let desperate=waiting.contains {legs[$0].foot.distance(to:body)>Self.maximumReach*0.7}
            // The partner group may still be finishing its swing; overlap the last moment of it.
            let partnerLanding=other.allSatisfy {!legs[$0].isStepping || legs[$0].phase>0.7}
            guard partnerDown || partnerLanding || desperate || speed>=320 else {continue}
            let launch=(partnerDown ? group.filter {!legs[$0].isStepping} : waiting).sorted {strain($0)>strain($1)}.prefix(room)
            for i in launch {beginStep(i,to:landing(i,target:target(i),body:body,anchors:anchors),anchors:anchors,speed:speed,reduceMotion:false)}
            if !launch.isEmpty {
                nextGroup=1-groupIndex
                cooldown=max(0.012,0.030-speed*0.00004)
                return
            }
        }
    }

    /// A target foothold, gripping a nearby edge of text or an image when one is close.
    private func landing(_ i:Int,target:DocumentPosition,body:DocumentPosition,anchors:[TerrainAnchor])->(DocumentPosition,String?) {
        let used=Set(legs.enumerated().filter {$0.offset != i}.compactMap {$0.element.anchorID})
        let anchor=anchors.filter {
            !used.contains($0.id) && $0.position.distance(to:body)<70 && $0.position.distance(to:body)>28 &&
            $0.position.distance(to:target)<18 && $0.position.distance(to:legs[i].foot)>1
        }.min {$0.position.distance(to:target)<$1.position.distance(to:target)}
        return (anchor?.position ?? target,anchor?.id)
    }

    /// Restricted walks (only nouns, for example): every landing is a permitted anchor.
    private mutating func advanceStrict(body:DocumentPosition,velocity:DocumentPosition,anchors:[TerrainAnchor],speed:Double,reduceMotion:Bool) {
        let active=legs.filter(\.isStepping).count
        let capacity=reduceMotion ? 2 : 4
        guard cooldown<=0,active<capacity else {return}
        for groupIndex in [nextGroup,1-nextGroup] {
            var launched=0
            for i in Self.groups[groupIndex] where launched<2 && legs.filter(\.isStepping).count<capacity && !legs[i].isStepping {
                let ideal=nominal(i,body:body)
                guard legs[i].foot.distance(to:body)>62 else {continue}
                let currentDistance=legs[i].foot.distance(to:body)
                let anchor=anchors.filter {
                    $0.position.distance(to:body)<65 &&
                    $0.position.distance(to:legs[i].foot)>1 &&
                    ($0.position.distance(to:body)+1<currentDistance ||
                     $0.position.distance(to:ideal)+1<legs[i].foot.distance(to:ideal))
                }.min {$0.position.distance(to:ideal)<$1.position.distance(to:ideal)}
                guard let anchor else {continue}
                beginStep(i,to:(anchor.position,anchor.id),anchors:anchors,speed:speed,reduceMotion:reduceMotion)
                launched += 1
            }
            if launched>0 {
                nextGroup=1-groupIndex
                cooldown=reduceMotion ? 0.085 : max(0.012,0.030-speed*0.00004)
                return
            }
        }
    }

    private mutating func beginStep(_ i:Int,to landing:(DocumentPosition,String?),anchors:[TerrainAnchor],speed:Double,reduceMotion:Bool) {
        let from=legs[i].foot
        var destination=landing.0
        if landing.1 == nil {
            let distance=from.distance(to:destination)
            let stride=max(70,min(105,speed*0.32))
            if distance>stride {
                let fraction=stride/distance
                destination = .init(x:from.x+(destination.x-from.x)*fraction,y:from.y+(destination.y-from.y)*fraction)
            }
        }
        let travel=from.distance(to:destination)
        legs[i].from=from
        legs[i].to=destination
        legs[i].phase=0
        let baseDuration=reduceMotion ? 0.19 : max(0.05,0.12-speed*0.00015)
        // A cap on swing speed keeps each frame's foot movement small enough to read as a step.
        legs[i].duration=max(baseDuration,travel/1_250)
        legs[i].anchorID=landing.1
    }
}
