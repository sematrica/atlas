import Foundation

public struct DocumentPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x=x; self.y=y }
    public static let zero=Self(x:0,y:0)
    public func distance(to other:Self)->Double { hypot(x-other.x,y-other.y) }
    public func moved(_ dx:Double,_ dy:Double)->Self { Self(x:x+dx,y:y+dy) }
}
public struct TerrainRect: Codable, Equatable, Sendable {
    public var x:Double; public var y:Double; public var width:Double; public var height:Double
    public init(x:Double,y:Double,width:Double,height:Double) { self.x=x;self.y=y;self.width=width;self.height=height }
    public var center:DocumentPosition { .init(x:x+width/2,y:y+height/2) }
    public func contains(_ point:DocumentPosition)->Bool { point.x >= x && point.x <= x+width && point.y >= y && point.y <= y+height }
}
public enum TerrainKind:String,Codable,Sendable { case text, heading, link, citation, image, boundary }
public struct CrawlerTerrain: Codable, Identifiable, Sendable {
    public let id:String
    public let group:String
    public let order:Int
    public let kind:TerrainKind
    public let rect:TerrainRect
    public let text:String
    public let href:String?
    public let section:String?
    public init(id:String,group:String,order:Int,kind:TerrainKind,rect:TerrainRect,text:String,href:String?=nil,section:String?=nil) {
        self.id=id;self.group=group;self.order=order;self.kind=kind;self.rect=rect;self.text=text;self.href=href;self.section=section
    }
}
public struct TerrainAnchor: Sendable, Identifiable {
    public let id:String
    public let position:DocumentPosition
    public let kind:TerrainKind
    public init(id:String,position:DocumentPosition,kind:TerrainKind) {self.id=id;self.position=position;self.kind=kind}
}
public struct CrawlerObservation: Codable, Sendable {
    public let document:String
    public let revision:Int
    public let center:DocumentPosition
    public let radius:Double
    public let viewport:TerrainRect
    public let documentWidth:Double
    public let documentHeight:Double
    public let terrain:[CrawlerTerrain]
    public let truncated:Bool
    public var anchors:[TerrainAnchor] {
        terrain.flatMap { item in
            [TerrainAnchor(id:item.id+"l",position:.init(x:item.rect.x,y:item.rect.y+item.rect.height),kind:item.kind),
             TerrainAnchor(id:item.id+"r",position:.init(x:item.rect.x+item.rect.width,y:item.rect.y+item.rect.height),kind:item.kind)]
        }
    }
    public init(document:String="test",revision:Int=0,center:DocumentPosition,radius:Double,viewport:TerrainRect,documentWidth:Double,documentHeight:Double,terrain:[CrawlerTerrain],truncated:Bool=false) {
        self.document=document;self.revision=revision;self.center=center;self.radius=radius;self.viewport=viewport
        self.documentWidth=documentWidth;self.documentHeight=documentHeight;self.terrain=terrain;self.truncated=truncated
    }
}
public enum CrawlerMission: Equatable, Sendable { case freeCrawl, stringHunt(String), semanticHunt(String) }
public enum CrawlerBehavior:String,Sendable {
    case idle, spawning, exploring, walking, inspecting, turning, paused, targetSuspected, approachingTarget, found, stuck, recovering, stopping
}
public struct CrawlerMatch: Sendable {
    public let key:String
    public let terrainIDs:[String]
    public let rects:[TerrainRect]
    public let text:String
    public let firstOffset:Int
    public let lastOffset:Int
    public var position:DocumentPosition {
        guard let first=rects.first else {return .zero}
        // Keep the whole observed phrase in view while approaching, not just its first word.
        let left=rects.map(\.x).min() ?? first.x
        let top=rects.map(\.y).min() ?? first.y
        let right=rects.map {$0.x+$0.width}.max() ?? first.x+first.width
        let bottom=rects.map {$0.y+$0.height}.max() ?? first.y+first.height
        return .init(x:(left+right)/2,y:(top+bottom)/2)
    }
}
public struct CrawlerState: Identifiable, Sendable {
    public let id:UUID
    public var position:DocumentPosition
    public var velocity=DocumentPosition.zero
    public var desired=DocumentPosition.zero
    public var mission:CrawlerMission
    public var behavior:CrawlerBehavior = .idle
    public var match:CrawlerMatch?
    public var elapsed:Double=0
    public init(id:UUID=UUID(),position:DocumentPosition = .zero,mission:CrawlerMission = .freeCrawl) {
        self.id=id;self.position=position;self.mission=mission
    }
}
/// The perception boundary deliberately has no target string, archive provider or global search API.
@MainActor public protocol CrawlerPerception: AnyObject {
    func observe(around position:DocumentPosition,radius:Double) async throws -> CrawlerObservation
}
