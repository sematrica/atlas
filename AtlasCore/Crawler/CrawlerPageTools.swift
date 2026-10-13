import Foundation

/// One rendered text block, link or image from the article's page map.
public struct CrawlerPageItem:Codable,Sendable {
    public let id:String
    public let text:String
    public let rect:TerrainRect
    public let href:String?
    public let section:String?
    /// The element's tag name in lowercase (p, li, h2, td…). Older maps omit it.
    public let tag:String?
    public init(id:String,text:String,rect:TerrainRect,href:String?=nil,section:String?=nil,tag:String?=nil) {
        self.id=id;self.text=text;self.rect=rect;self.href=href;self.section=section;self.tag=tag
    }
    public var isHeading:Bool {tag.map {$0.count == 2 && $0.hasPrefix("h") && $0.last?.isNumber == true} ?? false}
}
/// The complete rendered article: text blocks with source IDs, links and images.
public struct CrawlerPageMap:Codable,Sendable {
    public let document:String
    /// Layout revision. Changes when the article reflows (resize, image load).
    public let revision:Int
    /// Text revision. Changes only when the article's text nodes change, which
    /// is the only thing that invalidates the source offsets in this map.
    public let textRevision:Int?
    public let viewport:TerrainRect
    public let documentWidth:Double
    public let documentHeight:Double
    public let blocks:[CrawlerPageItem]
    public let links:[CrawlerPageItem]
    public let images:[CrawlerPageItem]
    public let truncated:Bool
    /// Text and media caps are separate so an unusually large link list does not
    /// make article text appear incomplete (or vice versa).
    public let textTruncated:Bool?
    public let mediaTruncated:Bool?
    public init(document:String,revision:Int,textRevision:Int?=nil,viewport:TerrainRect,documentWidth:Double,documentHeight:Double,blocks:[CrawlerPageItem],links:[CrawlerPageItem]=[],images:[CrawlerPageItem]=[],truncated:Bool=false,textTruncated:Bool?=nil,mediaTruncated:Bool?=nil) {
        self.document=document;self.revision=revision;self.textRevision=textRevision;self.viewport=viewport
        self.documentWidth=documentWidth;self.documentHeight=documentHeight;self.blocks=blocks;self.links=links;self.images=images
        self.truncated=truncated;self.textTruncated=textTruncated;self.mediaTruncated=mediaTruncated
    }
    public var isTextComplete:Bool {!(textTruncated ?? truncated)}
    public var isMediaComplete:Bool {!(mediaTruncated ?? truncated)}
    /// A stable identity for the article's text, independent of layout.
    public var fingerprint:String {
        KnowledgeHash.of(blocks.map {$0.id+"\n"+$0.text}.joined(separator:"\n")+links.map {$0.id+"\n"+($0.href ?? "")}.joined(separator:"\n"))
    }
}
/// A UTF-16 range inside one page-map text block.
public struct CrawlerPageRange:Codable,Sendable,Equatable,Hashable {
    public let id:String
    public let start:Int
    public let end:Int
    public let text:String
    public init(id:String,start:Int,end:Int,text:String) {self.id=id;self.start=start;self.end=end;self.text=text}
}
public struct CrawlerPageTarget:Codable,Sendable {
    public let range:CrawlerPageRange
    public let rect:TerrainRect
}

public enum CrawlerPageAnalysis {
    /// Conservative connected foothold route. Swinging feet may cross gaps; landings may not.
    public static func route(from start:DocumentPosition,to end:DocumentPosition,footholds:[DocumentPosition],reach:Double=55)->[DocumentPosition]? {
        let points=footholds
        guard !points.isEmpty else {return nil}
        var buckets:[String:[Int]]=[:]
        func key(_ x:Int,_ y:Int)->String {"\(x):\(y)"}
        for (i,p) in points.enumerated() {buckets[key(Int(floor(p.x/reach)),Int(floor(p.y/reach))),default:[]].append(i)}
        func neighbors(_ p:DocumentPosition)->[Int] {
            let x=Int(floor(p.x/reach)),y=Int(floor(p.y/reach))
            return ((x-1)...(x+1)).flatMap {a in ((y-1)...(y+1)).flatMap {b in buckets[key(a,b)] ?? []}}.filter {points[$0].distance(to:p)<=reach}
        }
        var queue=neighbors(start),parents:[Int:Int]=[:],cursor=0
        for i in queue {parents[i] = -1}
        while cursor<queue.count {
            let i=queue[cursor];cursor += 1
            if points[i].distance(to:end)<=reach {
                var path:[DocumentPosition]=[end];var current=i
                while current>=0 {path.append(points[current]);current=parents[current] ?? -1}
                return path.reversed()
            }
            for j in neighbors(points[i]) where parents[j] == nil {parents[j]=i;queue.append(j)}
        }
        return nil
    }
}
