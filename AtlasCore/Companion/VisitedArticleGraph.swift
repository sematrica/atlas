import Foundation

/// A local, package-scoped record of pages the reader actually opened.
public struct VisitedArticle: Codable, Sendable, Identifiable, Equatable {
    public var packageID: String
    public var packageName: String
    public var path: String
    public var title: String
    public var lastVisited: Date
    public var visitCount: Int
    public var outgoingPaths: [String]
    public var x: Double
    public var y: Double
    public var id: String { packageID + "|" + path }
}

public struct VisitConnection: Sendable, Identifiable, Equatable {
    public let fromID: String
    public let toID: String
    public let forward: Bool
    public let backward: Bool
    /// Links both pages point to, including pages that have not been visited.
    public let sharedPaths: [String]
    public var id: String { fromID + "→" + toID }
    public var isDirect: Bool { forward || backward }
}

public struct VisitedArticleGraph: Codable, Sendable {
    public private(set) var articles: [VisitedArticle] = []
    public init() {}

    public mutating func record(packageID: String, packageName: String, path: String,
                                title: String, outgoingPaths: [String], at time: Date = Date()) {
        guard !packageID.isEmpty, !path.isEmpty else { return }
        let links=Array(Set(outgoingPaths.filter { !$0.isEmpty && $0 != path })).sorted()
        if let index=articles.firstIndex(where: { $0.packageID == packageID && $0.path == path }) {
            articles[index].title=title
            articles[index].packageName=packageName
            articles[index].lastVisited=time
            articles[index].visitCount += 1
            articles[index].outgoingPaths=links
        } else {
            let n=Double(articles.count),angle=n * 2.399963229728653
            let radius=95 + 54 * sqrt(n)
            articles.append(.init(packageID:packageID,packageName:packageName,path:path,title:title,
                                  lastVisited:time,visitCount:1,outgoingPaths:links,
                                  x:900 + cos(angle)*radius,y:650 + sin(angle)*radius))
        }
    }

    public mutating func move(_ id:String,to x:Double,_ y:Double) {
        guard let index=articles.firstIndex(where:{$0.id == id}),x.isFinite,y.isFinite else {return}
        articles[index].x=max(90,min(1710,x));articles[index].y=max(90,min(1210,y))
    }

    private static func linkKey(_ path:String)->String {
        var value=(path.removingPercentEncoding ?? path)
        if value.hasPrefix("A/") {value=String(value.dropFirst(2))}
        return value.replacingOccurrences(of:"_",with:" ").folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
    }

    public func connections(packageID:String?=nil)->[VisitConnection] {
        let pages=articles.filter {packageID == nil || $0.packageID == packageID}
        var result:[VisitConnection]=[]
        for i in pages.indices {
            guard i+1<pages.count else {continue}
            let a=pages[i],outA=Set(a.outgoingPaths.map(Self.linkKey))
            for j in (i+1)..<pages.count {
                let b=pages[j]
                guard a.packageID == b.packageID else {continue}
                let outB=Set(b.outgoingPaths.map(Self.linkKey))
                let forward=outA.contains(Self.linkKey(b.path)),backward=outB.contains(Self.linkKey(a.path))
                let shared=Array(outA.intersection(outB)).sorted()
                if forward || backward || !shared.isEmpty {
                    result.append(.init(fromID:a.id,toID:b.id,forward:forward,backward:backward,
                                        sharedPaths:shared))
                }
            }
        }
        return result
    }
}
