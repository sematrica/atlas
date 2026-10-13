import Foundation

/// Where the spider may travel between articles.
public struct CrawlerTravelRules:Sendable {
    public var allowLinks=true
    public var blocked:[String]=[]
    public init() {}
    public mutating func avoid(_ text:String) {
        let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty else {return}
        if !blocked.contains(where:{$0.caseInsensitiveCompare(clean) == .orderedSame}),blocked.count<20 {blocked.append(clean)}
    }
    public func permits(_ text:String)->Bool {
        let normalized=text.removingPercentEncoding?.replacingOccurrences(of:"_",with:" ") ?? text
        return !blocked.contains {normalized.range(of:$0,options:[.caseInsensitive,.diacriticInsensitive]) != nil}
    }
    public var summary:String {"Article travel: \(allowLinks ? "allowed" : "stay in current article"). Avoid destinations: \(blocked.isEmpty ? "none" : blocked.joined(separator:", "))."}
}
