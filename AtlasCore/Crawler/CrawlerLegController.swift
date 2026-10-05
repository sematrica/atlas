import Foundation

public struct CrawlerLeg: Sendable {
    public var foot:DocumentPosition
    public var from:DocumentPosition
    public var to:DocumentPosition
    public var phase:Double=1
    public var anchorID:String?
    public var isStepping:Bool { phase<1 }
}
public struct CrawlerLegController: Sendable {
    public private(set) var legs:[CrawlerLeg]=[]
    public private(set) var heading:Double = .pi/2
    private var group=0
    private var cooldown=0.0
    public init() {}
    public mutating func reset(at position:DocumentPosition) {
        heading = .pi/2;group=0;cooldown=0
        legs=(0..<8).map { i in let foot=nominal(i,body:position);return CrawlerLeg(foot:foot,from:foot,to:foot) }
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
        return mid.moved(-sin(heading)*side*17,cos(heading)*side*17)
    }
    private func rotated(x:Double,y:Double,body:DocumentPosition)->DocumentPosition {
        body.moved(cos(heading)*x-sin(heading)*y,sin(heading)*x+cos(heading)*y)
    }
    private func nominal(_ i:Int,body:DocumentPosition)->DocumentPosition {
        let side=i<4 ? -1.0 : 1.0,row=Double(i%4)
        return rotated(x:(row-1.5)*25,y:side*(43-abs(row-1.5)*3),body:body)
    }
    public mutating func advance(body:DocumentPosition,velocity:DocumentPosition,anchors:[TerrainAnchor],dt:Double,reduceMotion:Bool) {
        if legs.count != 8 {reset(at:body)}
        if hypot(velocity.x,velocity.y)>2 {
            let target=atan2(velocity.y,velocity.x),delta=atan2(sin(target-heading),cos(target-heading))
            heading += delta*min(1,dt*7)
        }
        cooldown -= dt
        for i in legs.indices where legs[i].isStepping {
            legs[i].phase=min(1,legs[i].phase+dt/(reduceMotion ? 0.16 : 0.12))
            let t=legs[i].phase,s=t*t*(3-2*t)
            legs[i].foot = .init(x:legs[i].from.x+(legs[i].to.x-legs[i].from.x)*s,
                                 y:legs[i].from.y+(legs[i].to.y-legs[i].from.y)*s-(reduceMotion ? 0 : sin(t * .pi)*5))
        }
        guard cooldown<=0,!legs.contains(where:{$0.isStepping}) else {return}
        let needs=legs.indices.contains { legs[$0].foot.distance(to:nominal($0,body:body))>16 || legs[$0].foot.distance(to:body)>72 }
        guard needs else {return}
        for i in legs.indices where (i%2 == group) {
            let ideal=nominal(i,body:body).moved(velocity.x*0.10,velocity.y*0.10)
            let used=Set(legs.enumerated().filter {$0.offset != i}.compactMap {$0.element.anchorID})
            let anchor=anchors.filter {!used.contains($0.id) && $0.position.distance(to:body)<68 && $0.position.distance(to:body)>28 && $0.position.distance(to:ideal)<22}
                .min {$0.position.distance(to:ideal)<$1.position.distance(to:ideal)}
            legs[i].from=legs[i].foot;legs[i].to=anchor?.position ?? ideal;legs[i].phase=0;legs[i].anchorID=anchor?.id
        }
        group=1-group;cooldown=0.025
    }
}
